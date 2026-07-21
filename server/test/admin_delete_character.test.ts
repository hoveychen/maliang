import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WORLD_CENTER_TILE, type Character } from '../src/types.ts';

function char(worldId: string, id: string, sceneId: string, isFairy = false): Character {
  return {
    id, worldId, isFairy, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: 'd', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId, abilities: [], relationships: {},
  };
}

test('admin DELETE 角色：删 roster 实例 + 保留 character_defs（可复用）+ 门禁 + 拒删仙子', async () => {
  const store = new WorldStore();
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    store.createWorld('w1');
    store.addCharacter(char('w1', 'c1', 'forest'));    // 退役场景旧村民（roster + def 都建）
    store.addCharacter(char('w1', 'fairy1', 'village', true));
    const url = '/admin/worlds/w1/characters/c1';
    const H = { 'x-admin-token': 'sesame' };

    // 前置：addCharacter 已建 roster 实例 + 共享定义
    assert.ok(store.getCharacter('w1', 'c1'), '删前 roster 实例在');
    assert.ok(store.getCharacterDef('c1'), '删前 character_defs 定义在');

    // 门禁：无 token / 坏 token → 403；不存在的角色 → 404
    assert.equal((await app.inject({ method: 'DELETE', url })).statusCode, 403);
    assert.equal((await app.inject({ method: 'DELETE', url, headers: { 'x-admin-token': 'no' } })).statusCode, 403);
    assert.equal((await app.inject({ method: 'DELETE', url: '/admin/worlds/w1/characters/ghost', headers: H })).statusCode, 404);
    assert.ok(store.getCharacter('w1', 'c1'), '门禁/404 一律不落库');

    // 拒删仙子（删点点会毁世界）
    const fairyRes = await app.inject({ method: 'DELETE', url: '/admin/worlds/w1/characters/fairy1', headers: H });
    assert.equal(fairyRes.statusCode, 400, '仙子拒删');
    assert.ok(store.getCharacter('w1', 'fairy1'), '仙子还在');

    // 正常删：roster 实例没了，但共享定义保留（老板：删引用不删实体表，defId 可复用）
    const res = await app.inject({ method: 'DELETE', url, headers: H });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().ok, true);
    assert.equal(store.getCharacter('w1', 'c1'), undefined, 'roster 实例已删');
    assert.ok(store.getCharacterDef('c1'), 'character_defs 定义保留（可复用）');

    // 幂等：再删已不存在 → 404
    assert.equal((await app.inject({ method: 'DELETE', url, headers: H })).statusCode, 404);
  } finally {
    await app.close();
  }
});
