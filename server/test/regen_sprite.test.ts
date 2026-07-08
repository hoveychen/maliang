import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string, desc: string): Character {
  const c: Character = {
    id,
    worldId,
    isFairy: false,
    name: '小狐',
    personality: '机灵',
    voiceId: 'v1',
    appearance: { visualDescription: desc, spriteAsset: 'oldhash', scale: 1 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 },
    abilities: ['move_to'],
    relationships: {},
  };
  store.addCharacter(c);
  return c;
}

// 管理端点：按存量描述重生成立绘。烧钱且改小朋友的角色形象——必须过 admin token 门禁。
test('regen-sprite: token 门禁 + 按存量描述重生成并更新 spriteAsset', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1', 'a cute fox');
  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());

  const url = '/worlds/w1/characters/c1/regen-sprite';

  // 未配置 MALIANG_ADMIN_TOKEN → 一律 403（安全默认）
  delete process.env.MALIANG_ADMIN_TOKEN;
  const off = await app.inject({ method: 'POST', url });
  assert.equal(off.statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    // token 错 → 403
    const bad = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'nope' } });
    assert.equal(bad.statusCode, 403);

    // token 对 → 重生成，spriteAsset 更新，prev 带回旧值
    const good = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(good.statusCode, 200);
    const r = good.json() as { id: string; prev: string; spriteAsset: string };
    assert.equal(r.prev, 'oldhash');
    assert.ok(r.spriteAsset.length > 0);
    assert.notEqual(r.spriteAsset, 'oldhash');
    assert.equal(store.getCharacter('w1', 'c1')!.appearance.spriteAsset, r.spriteAsset);
    // 新资产真实可取
    const asset = await app.inject({ method: 'GET', url: `/assets/${r.spriteAsset}` });
    assert.equal(asset.statusCode, 200);

    // 角色不存在 → 404；无 visualDescription → 400
    const miss = await app.inject({ method: 'POST', url: '/worlds/w1/characters/ghost/regen-sprite', headers: { 'x-admin-token': 'sesame' } });
    assert.equal(miss.statusCode, 404);
    seedChar(store, 'w1', 'c2', '  ');
    const nodesc = await app.inject({ method: 'POST', url: '/worlds/w1/characters/c2/regen-sprite', headers: { 'x-admin-token': 'sesame' } });
    assert.equal(nodesc.statusCode, 400);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
