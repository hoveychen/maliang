import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import {
  generateCharacterAnimation,
  triggerCharacterAnimation,
  backfillCharacterAnimations,
  repackFromStoredClips,
  SPRITE_ANIM_VERSION,
  type ToSpriteSheet,
} from '../src/idle_animation.ts';
import { CLIP_NAMES, type SpriteSheetMeta } from '../src/sprite_sheet.ts';
import type { Character } from '../src/types.ts';

/** 图集 meta（idle 4 帧 + talking 3 帧 = 7 帧；moving 不生成，走路是客户端程序化的）。 */
const META: SpriteSheetMeta = {
  cols: 4, rows: 2, frameCount: 7, fps: 8, cellW: 20, cellH: 30, width: 80, height: 60,
  clips: { idle: { start: 0, count: 4 }, talking: { start: 4, count: 3 } },
};
/** 老的单段 meta（v1 记录用，没有 clips）。 */
const META_V1: SpriteSheetMeta = {
  cols: 2, rows: 2, frameCount: 3, fps: 8, cellW: 20, cellH: 30, width: 40, height: 60,
};
// 假的视频→图集转换：不碰 ffmpeg/网络，回一张占位图集。
const fakeSheet: ToSpriteSheet = async () => ({
  atlas: { bytes: Uint8Array.from([1, 2, 3, 4]), mime: 'image/png' },
  meta: META,
});

function putSprite(store: WorldStore): string {
  return store.putAsset({ bytes: Uint8Array.from([9, 9, 9]), mime: 'image/png' });
}

/** 置一条「当前版本」的 ready 记录（去重逻辑要看 version，不能只看 status）。 */
function setReadyV2(store: WorldStore, sprite: string, animAsset: string): void {
  store.setSpriteAnimReady(sprite, animAsset, META, {
    version: SPRITE_ANIM_VERSION,
    clipVideos: { idle: 'vi', talking: 'vt' },
  });
}

test('generateCharacterAnimation: 各段并发生成 → 一张图集入库，记录带 version + 每段原片 hash', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);

  // 拦住转换缝，看清楚交给它的到底是哪几段（moving 刻意不生成，见 CLIP_NAMES）。
  let handed: string[] = [];
  const spy: ToSpriteSheet = async (clips) => {
    handed = clips.map((c) => c.name);
    return { atlas: { bytes: Uint8Array.from([1, 2, 3, 4]), mime: 'image/png' }, meta: META };
  };
  await generateCharacterAnimation(createMockAdapters(), store, sprite, spy);

  assert.deepEqual(handed, ['idle', 'talking'], '应把各段一起交给打包器（段序即图集段序）；不含 moving');

  const rec = store.getSpriteAnim(sprite);
  assert.equal(rec?.status, 'ready');
  assert.equal(rec?.version, SPRITE_ANIM_VERSION, '应标当前图集版本');
  assert.ok(rec?.animAsset, '应有 animAsset hash');
  assert.deepEqual(rec?.meta, META);
  assert.ok(store.getAsset(rec!.animAsset!), '图集资产应可取回');

  // 原片必须留下来：视频是花钱买的，日后重打图集（换帧率/换打包）要靠它零成本重来。
  const vids = rec?.clipVideos;
  assert.ok(vids, '应记下各段原片的资产 hash');
  for (const name of CLIP_NAMES) {
    assert.ok(vids![name], `缺 ${name} 段原片 hash`);
    const blob = store.getAsset(vids![name]!);
    assert.ok(blob, `${name} 段原片应能从资产库取回`);
    assert.equal(blob!.mime, 'video/mp4', '原片 mime 应为 video/mp4');
  }
  assert.equal(
    new Set(Object.values(vids!)).size, CLIP_NAMES.length,
    '每段原片应是各自独立的资产（内容不同 → hash 不同）',
  );
  assert.equal(vids!.moving, undefined, 'moving 不生成，不该有原片');
});

test('generateCharacterAnimation: 转换抛错 → failed（不崩，客户端保留静态）', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  const boom: ToSpriteSheet = async () => {
    throw new Error('ffmpeg boom');
  };
  await generateCharacterAnimation(createMockAdapters(), store, sprite, boom);
  assert.equal(store.getSpriteAnim(sprite)?.status, 'failed');
});

test('generateCharacterAnimation: 立绘不在库 → 不留记录', async () => {
  const store = new WorldStore();
  await generateCharacterAnimation(createMockAdapters(), store, 'nope', fakeSheet);
  assert.equal(store.getSpriteAnim('nope'), undefined);
});

test('repackFromStoredClips: 拿已存原片重打图集，全程不碰视频生成（零成本）', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  await generateCharacterAnimation(createMockAdapters(), store, sprite, fakeSheet);
  const before = store.getSpriteAnim(sprite)!;

  // 视频适配器换成「一调就炸」——证明重打图集这条路一次都没去买视频。
  const noVideo = createMockAdapters();
  noVideo.video = {
    async generateClip() {
      throw new Error('重打图集不该再去生成视频（那是花钱的）');
    },
  };

  const NEW_META: SpriteSheetMeta = { ...META, fps: 24 }; // 假装换了抽帧帧率
  const repacked: ToSpriteSheet = async (clips) => {
    assert.deepEqual(clips.map((c) => c.name), [...CLIP_NAMES], '应从库里取回各段原片');
    for (const c of clips) assert.equal(c.mp4.mime, 'video/mp4');
    return { atlas: { bytes: Uint8Array.from([7, 7, 7, 7]), mime: 'image/png' }, meta: NEW_META };
  };
  const ok = await repackFromStoredClips(store, sprite, repacked);
  assert.equal(ok, true);

  const after = store.getSpriteAnim(sprite)!;
  assert.equal(after.meta?.fps, 24, '图集应换成新参数');
  assert.notEqual(after.animAsset, before.animAsset, '应产出新图集资产');
  assert.deepEqual(after.clipVideos, before.clipVideos, '原片 hash 不变（原片没重新买）');
});

test('repackFromStoredClips: 老的 v1 记录没有原片 → 返回 false（调用方该走完整重生成）', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  store.setSpriteAnimReady(sprite, 'oldAtlas', META_V1); // v1：无 clipVideos
  assert.equal(await repackFromStoredClips(store, sprite, fakeSheet), false);
  assert.equal(store.getSpriteAnim(sprite)?.animAsset, 'oldAtlas', '失败时不该动原记录');
});

test('triggerCharacterAnimation: 已是当前版本的 ready → 去重不再生成', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  setReadyV2(store, sprite, 'existing');
  let called = false;
  const spy: ToSpriteSheet = async () => {
    called = true;
    return { atlas: { bytes: Uint8Array.from([0]), mime: 'image/png' }, meta: META };
  };
  triggerCharacterAnimation(createMockAdapters(), store, sprite, spy);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(called, false, '已是当前版本不应再触发生成');
  assert.equal(store.getSpriteAnim(sprite)?.animAsset, 'existing', '记录不被覆盖');
});

test('triggerCharacterAnimation: 老的单段 v1 ready → 升级重生成（否则老角色永远只有 idle）', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  store.setSpriteAnimReady(sprite, 'oldAtlas', META_V1); // 没有 version 字段 = v1
  let called = false;
  const spy: ToSpriteSheet = async (clips) => {
    called = true;
    assert.equal(clips.length, CLIP_NAMES.length, '升级应重新生成全部段');
    return { atlas: { bytes: Uint8Array.from([5, 5]), mime: 'image/png' }, meta: META };
  };
  triggerCharacterAnimation(createMockAdapters(), store, sprite, spy);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(called, true, 'v1 记录应被升级重生成');
  const rec = store.getSpriteAnim(sprite);
  assert.equal(rec?.version, SPRITE_ANIM_VERSION);
  assert.notEqual(rec?.animAsset, 'oldAtlas', '应换上新的三段图集');
});

test('backfillCharacterAnimations: 回填「无记录」与「v1 老图集」，跳过 v2 与 failed，同 hash 去重', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  // 不同字节 → 不同 hash（资产内容寻址；同字节会撞成同一个）。
  const h1 = store.putAsset({ bytes: Uint8Array.from([1, 1, 1]), mime: 'image/png' }); // 已是 v2 → 跳过
  const h2 = store.putAsset({ bytes: Uint8Array.from([2, 2, 2]), mime: 'image/png' }); // 无记录 → 触发
  const h3 = store.putAsset({ bytes: Uint8Array.from([3, 3, 3]), mime: 'image/png' }); // failed → 跳过（不重试烧钱）
  const h4 = store.putAsset({ bytes: Uint8Array.from([4, 4, 4]), mime: 'image/png' }); // v1 老图集 → 触发升级
  setReadyV2(store, h1, 'a1');
  store.setSpriteAnimFailed(h3);
  store.setSpriteAnimReady(h4, 'a4old', META_V1);
  // backfill 只读 appearance.spriteAsset；但 appearance 现落在共享定义层（世界模板架构 v2），
  // 而定义要求有 name/id，故最小对象也得带个名字（拆写时抽定义会校验）。
  const mk = (id: string, hash: string): Character =>
    ({ id, worldId: 'w1', name: id, appearance: { spriteAsset: hash } } as unknown as Character);
  store.addCharacter(mk('c1', h1));
  store.addCharacter(mk('c2', h2));
  store.addCharacter(mk('c3', h3));
  store.addCharacter(mk('c4', h2)); // 同 hash 共用 → 只触发一次
  store.addCharacter(mk('c5', h4));

  const n = backfillCharacterAnimations(createMockAdapters(), store, fakeSheet);
  assert.equal(n, 2, 'h2(无记录) + h4(v1 老图集) → 触发 2 个（去重后）');
  await new Promise((r) => setTimeout(r, 20)); // 等 fakeSheet 收敛
  assert.equal(store.getSpriteAnim(h2)?.status, 'ready', 'h2 生成完成 → ready');
  assert.equal(store.getSpriteAnim(h2)?.version, SPRITE_ANIM_VERSION);
  assert.equal(store.getSpriteAnim(h4)?.version, SPRITE_ANIM_VERSION, 'h4 应升到 v2');
  assert.notEqual(store.getSpriteAnim(h4)?.animAsset, 'a4old', 'h4 应换上新图集');
  assert.equal(store.getSpriteAnim(h1)?.animAsset, 'a1', 'h1 已是 v2 → 不动');
  assert.equal(store.getSpriteAnim(h3)?.status, 'failed', 'h3 failed 未被重试');
});

test('GET /sprite-anim/:hash: ready 返回记录（含 clips meta）；未知返回 none', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  store.setSpriteAnimReady(sprite, 'atlas123', META, { version: SPRITE_ANIM_VERSION });
  const app = await buildServer({ adapters: createMockAdapters(), store });

  const ok = await app.inject({ method: 'GET', url: `/sprite-anim/${sprite}` });
  assert.equal(ok.statusCode, 200);
  const body = ok.json() as { status: string; animAsset: string; meta: SpriteSheetMeta };
  assert.equal(body.status, 'ready');
  assert.equal(body.animAsset, 'atlas123');
  assert.deepEqual(body.meta.clips, META.clips, '客户端要靠 meta.clips 切段，必须下发');

  const none = await app.inject({ method: 'GET', url: '/sprite-anim/unknownhash' });
  assert.deepEqual(none.json(), { status: 'none' });
  await app.close();
});

test('sprite-anim 持久化：重启后 ready 保留（含 version/原片 hash）、pending 转 failed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'mlanim-persist-'));

  const s1 = new WorldStore(dir);
  s1.setSpriteAnimReady('ready1', 'atlasA', META, {
    version: SPRITE_ANIM_VERSION,
    clipVideos: { idle: 'v1', talking: 'v3' },
  });
  s1.setSpriteAnimPending('pending1');

  const s2 = new WorldStore(dir); // 模拟重启：重新从磁盘加载
  const rec = s2.getSpriteAnim('ready1');
  assert.equal(rec?.status, 'ready');
  assert.equal(rec?.animAsset, 'atlasA');
  assert.equal(rec?.version, SPRITE_ANIM_VERSION, 'version 要落盘，否则重启后被当 v1 反复重生成烧钱');
  assert.deepEqual(rec?.clipVideos, { idle: 'v1', talking: 'v3' }, '原片 hash 要落盘');
  assert.equal(s2.getSpriteAnim('pending1')?.status, 'failed', '重启把悬空 pending 转 failed');
});

test('POST /admin/sprite-anim/:hash/repack: 拿已存原片重打，全程不碰视频生成；无原片 → 409', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  await generateCharacterAnimation(createMockAdapters(), store, sprite, fakeSheet);
  const oldAtlas = store.getSpriteAnim(sprite)!.animAsset;

  // 服务器上的视频适配器换成「一调就炸」——repack 若偷偷去买视频，这里会把它抓出来。
  const adapters = createMockAdapters();
  adapters.video = {
    async generateClip() {
      throw new Error('repack 不该触发视频生成（那是花钱的）');
    },
  };
  // 重打时假装换了参数（fps 24），产出与原来不同的图集。
  const repack: ToSpriteSheet = async (clips) => {
    assert.equal(clips.length, CLIP_NAMES.length);
    return { atlas: { bytes: Uint8Array.from([9, 9, 9, 9]), mime: 'image/png' }, meta: { ...META, fps: 24 } };
  };
  const app = await buildServer({ adapters, store, toSpriteSheet: repack });

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const noAuth = await app.inject({ method: 'POST', url: `/admin/sprite-anim/${sprite}/repack` });
    assert.equal(noAuth.statusCode, 403, '无 token → 403');

    const ok = await app.inject({
      method: 'POST', url: `/admin/sprite-anim/${sprite}/repack`,
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(ok.statusCode, 200);
    const rec = store.getSpriteAnim(sprite)!;
    assert.equal(rec.meta?.fps, 24, '应按新参数重打');
    assert.notEqual(rec.animAsset, oldAtlas, '应产出新图集');

    // v1 老记录没有原片 → 409（调用方该走 /generate，那条要花钱）
    const old = store.putAsset({ bytes: Uint8Array.from([8, 8, 8]), mime: 'image/png' });
    store.setSpriteAnimReady(old, 'v1atlas', META_V1);
    const conflict = await app.inject({
      method: 'POST', url: `/admin/sprite-anim/${old}/repack`,
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(conflict.statusCode, 409, '无原片 → 409');
    assert.equal(store.getSpriteAnim(old)?.animAsset, 'v1atlas', '409 时不动原记录');

    // repack-all 只挑「有原片」的（v1 老记录不在工作清单里）
    const all = await app.inject({
      method: 'POST', url: '/admin/sprite-anim/repack-all',
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(all.statusCode, 200);
    assert.equal((all.json() as { pending: number }).pending, 1, '只有 1 个立绘存了原片');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
    await app.close();
  }
});

test('POST /admin/sprite-anim/:hash: token 门禁 + 上传图集绑定到立绘 hash', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  const url = '/admin/sprite-anim/spriteX';
  const body = { animPngBase64: Buffer.from([1, 2, 3, 4]).toString('base64'), meta: META };

  // 未配 token → 403
  delete process.env.MALIANG_ADMIN_TOKEN;
  const off = await app.inject({ method: 'POST', url, payload: body });
  assert.equal(off.statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    // token 错 → 403
    const bad = await app.inject({ method: 'POST', url, payload: body, headers: { 'x-admin-token': 'nope' } });
    assert.equal(bad.statusCode, 403);

    // 缺 body → 400
    const miss = await app.inject({ method: 'POST', url, payload: {}, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(miss.statusCode, 400);

    // meta 非法(frameCount 超格数) → 400
    const badMeta = await app.inject({
      method: 'POST', url,
      payload: { animPngBase64: body.animPngBase64, meta: { ...META, frameCount: 999 } },
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(badMeta.statusCode, 400);

    // 正确 → 绑定,图集入库,/sprite-anim 变 ready
    const ok = await app.inject({ method: 'POST', url, payload: body, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(ok.statusCode, 200);
    const animAsset = ok.json().animAsset as string;
    assert.ok(animAsset);
    assert.ok(store.getAsset(animAsset), '图集资产入库');
    const poll = await app.inject({ method: 'GET', url: '/sprite-anim/spriteX' });
    assert.equal((poll.json() as { animAsset: string }).animAsset, animAsset);

    // 上传 WebP(magic bytes)→ 资产 mime 应识别为 image/webp(按 magic,不硬编码 png)
    const webpMagic = Buffer.concat([
      Buffer.from('RIFF'), Buffer.from([0, 0, 0, 0]), Buffer.from('WEBP'), Buffer.from([1, 2, 3, 4]),
    ]);
    const w = await app.inject({
      method: 'POST', url: '/admin/sprite-anim/spriteW',
      payload: { animPngBase64: webpMagic.toString('base64'), meta: META },
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(store.getAsset(w.json().animAsset as string)?.mime, 'image/webp', 'WebP 应识别为 image/webp');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
    await app.close();
  }
});
