import { ANON_PLAYER } from '../src/types.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer, createCharacterAsync } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { ToSpriteSheet } from '../src/idle_animation.ts';
import type { SpriteSheetMeta } from '../src/sprite_sheet.ts';

const META: SpriteSheetMeta = {
  cols: 2, rows: 2, frameCount: 3, fps: 8, cellW: 20, cellH: 30, width: 40, height: 60,
};
// 假的视频→图集转换：不碰 ffmpeg/网络，回一张占位图集。
const fakeSheet: ToSpriteSheet = async () => ({
  atlas: { bytes: Uint8Array.from([1, 2, 3, 4]), mime: 'image/png' },
  meta: META,
});

/** 轮询 store 里的 sprite-anim 状态直到离开 pending（fire-and-forget 的收敛点）。 */
async function waitSettled(store: WorldStore, hash: string): Promise<void> {
  for (let i = 0; i < 100; i++) {
    const rec = store.getSpriteAnim(hash);
    if (rec && rec.status !== 'pending') return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error(`sprite-anim ${hash} 未在时限内离开 pending`);
}

test('POST /admin/sprite-anim/:hash/generate: token 门禁 + 404 + 在线生成到 ready', async () => {
  const store = new WorldStore();
  const sprite = store.putAsset({ bytes: Uint8Array.from([9, 9, 9]), mime: 'image/png' });
  const app = await buildServer({ adapters: createMockAdapters(), store, toSpriteSheet: fakeSheet });
  const url = `/admin/sprite-anim/${sprite}/generate`;

  // 未配 token → 403
  delete process.env.MALIANG_ADMIN_TOKEN;
  const off = await app.inject({ method: 'POST', url });
  assert.equal(off.statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const auth = { 'x-admin-token': 'sesame' };
  try {
    // token 错 → 403
    const bad = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'nope' } });
    assert.equal(bad.statusCode, 403);

    // 立绘不在库 → 404（不烧钱）
    const miss = await app.inject({ method: 'POST', url: '/admin/sprite-anim/nope/generate', headers: auth });
    assert.equal(miss.statusCode, 404);

    // 触发生成 → triggered:true，后台跑完 → ready，图集入库
    const ok = await app.inject({ method: 'POST', url, headers: auth });
    assert.equal(ok.statusCode, 200);
    assert.equal(ok.json().triggered, true);
    await waitSettled(store, sprite);
    const rec = store.getSpriteAnim(sprite);
    assert.equal(rec?.status, 'ready');
    assert.ok(store.getAsset(rec!.animAsset!), '图集资产应入库');
    assert.deepEqual(rec?.meta, META);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
    await app.close();
  }
});

test('POST /admin/sprite-anim/:hash/generate: 已 ready 默认跳过，force=true 重生成', async () => {
  const store = new WorldStore();
  const sprite = store.putAsset({ bytes: Uint8Array.from([9, 9, 9]), mime: 'image/png' });
  let calls = 0;
  const counting: ToSpriteSheet = async () => {
    calls += 1;
    return { atlas: { bytes: Uint8Array.from([7, calls]), mime: 'image/png' }, meta: META };
  };
  const app = await buildServer({ adapters: createMockAdapters(), store, toSpriteSheet: counting });
  const url = `/admin/sprite-anim/${sprite}/generate`;
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const auth = { 'x-admin-token': 'sesame' };
  try {
    store.setSpriteAnimReady(sprite, 'existing', META);

    // 已 ready、无 force → 不触发、记录不动
    const skip = await app.inject({ method: 'POST', url, headers: auth });
    assert.deepEqual(skip.json(), { spriteHash: sprite, status: 'ready', triggered: false });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(calls, 0, '已 ready 不应重生成');
    assert.equal(store.getSpriteAnim(sprite)?.animAsset, 'existing');

    // force=true → 重生成，animAsset 换新
    const forced = await app.inject({ method: 'POST', url: `${url}?force=true`, headers: auth });
    assert.equal(forced.json().triggered, true);
    await waitSettled(store, sprite);
    assert.equal(calls, 1);
    assert.notEqual(store.getSpriteAnim(sprite)?.animAsset, 'existing', 'force 应换新图集');

    // pending 时（force 与否）都不打断：手工置 pending 再打
    store.setSpriteAnimPending(sprite);
    const busy = await app.inject({ method: 'POST', url: `${url}?force=true`, headers: auth });
    assert.deepEqual(busy.json(), { spriteHash: sprite, status: 'pending', triggered: false });
    assert.equal(calls, 1, 'pending 中不应再触发');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
    await app.close();
  }
});

test('createCharacterAsync: 造完 NPC 自动异步补 idle 动画', async () => {
  const store = new WorldStore();
  const world = store.createWorld();
  const sent: string[] = [];
  const socket = { send: (d: string) => sent.push(d) };

  await createCharacterAsync(socket, world.id, ANON_PLAYER, '一只蓝色的小兔子', createMockAdapters(), store, fakeSheet);

  const complete = sent.map((s) => JSON.parse(s)).find((m) => m.type === 'gen_complete');
  assert.ok(complete, '应收到 gen_complete');
  const spriteAsset = complete.character.appearance.spriteAsset as string;
  assert.ok(spriteAsset, '角色应有立绘');
  await waitSettled(store, spriteAsset);
  const rec = store.getSpriteAnim(spriteAsset);
  assert.equal(rec?.status, 'ready', '造角色应触发 idle 动画生成');
  assert.ok(store.getAsset(rec!.animAsset!), '图集资产应入库');
});
