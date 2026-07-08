import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { generateIdleAnimation, triggerIdleAnimation, type ToSpriteSheet } from '../src/idle_animation.ts';
import type { SpriteSheetMeta } from '../src/sprite_sheet.ts';

const META: SpriteSheetMeta = {
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

test('generateIdleAnimation: 成功 → ready，图集入库 + meta 记录', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  await generateIdleAnimation(createMockAdapters(), store, sprite, fakeSheet);

  const rec = store.getSpriteAnim(sprite);
  assert.equal(rec?.status, 'ready');
  assert.ok(rec?.animAsset, '应有 animAsset hash');
  assert.deepEqual(rec?.meta, META);
  assert.ok(store.getAsset(rec!.animAsset!), '图集资产应可取回');
});

test('generateIdleAnimation: 转换抛错 → failed（不崩，客户端保留静态）', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  const boom: ToSpriteSheet = async () => {
    throw new Error('ffmpeg boom');
  };
  await generateIdleAnimation(createMockAdapters(), store, sprite, boom);
  assert.equal(store.getSpriteAnim(sprite)?.status, 'failed');
});

test('generateIdleAnimation: 立绘不在库 → 不留记录', async () => {
  const store = new WorldStore();
  await generateIdleAnimation(createMockAdapters(), store, 'nope', fakeSheet);
  assert.equal(store.getSpriteAnim('nope'), undefined);
});

test('triggerIdleAnimation: 已 ready 则去重（不再触发转换）', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  store.setSpriteAnimReady(sprite, 'existing', META);
  let called = false;
  const spy: ToSpriteSheet = async () => {
    called = true;
    return { atlas: { bytes: Uint8Array.from([0]), mime: 'image/png' }, meta: META };
  };
  triggerIdleAnimation(createMockAdapters(), store, sprite, spy);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(called, false, '已 ready 不应再触发生成');
  assert.equal(store.getSpriteAnim(sprite)?.animAsset, 'existing', '记录不被覆盖');
});

test('GET /sprite-anim/:hash: ready 返回记录；未知返回 none', async () => {
  const store = new WorldStore();
  const sprite = putSprite(store);
  store.setSpriteAnimReady(sprite, 'atlas123', META);
  const app = await buildServer({ adapters: createMockAdapters(), store });

  const ok = await app.inject({ method: 'GET', url: `/sprite-anim/${sprite}` });
  assert.equal(ok.statusCode, 200);
  assert.deepEqual(ok.json(), { status: 'ready', animAsset: 'atlas123', meta: META });

  const none = await app.inject({ method: 'GET', url: '/sprite-anim/unknownhash' });
  assert.deepEqual(none.json(), { status: 'none' });
  await app.close();
});

test('sprite-anim 持久化：重启后 ready 保留、pending 转 failed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'mlanim-persist-'));

  const s1 = new WorldStore(dir);
  s1.setSpriteAnimReady('ready1', 'atlasA', META);
  s1.setSpriteAnimPending('pending1');

  const s2 = new WorldStore(dir); // 模拟重启：重新从磁盘加载
  assert.equal(s2.getSpriteAnim('ready1')?.status, 'ready');
  assert.equal(s2.getSpriteAnim('ready1')?.animAsset, 'atlasA');
  assert.equal(s2.getSpriteAnim('pending1')?.status, 'failed', '重启把悬空 pending 转 failed');
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
    assert.deepEqual(poll.json(), { status: 'ready', animAsset, meta: META });

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
