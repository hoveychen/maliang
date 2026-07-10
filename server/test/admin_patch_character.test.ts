import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { REQUIRED_GRID } from '../src/terrain.ts';
import { WORLD_CENTER_TILE, type Character } from '../src/types.ts';

function char(worldId: string, id: string, sceneId: string): Character {
  return {
    id, worldId, isFairy: false, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: 'd', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId, abilities: [], relationships: {},
  };
}

test('admin PATCH 角色：修 sceneId/position/spriteAsset + 逐项校验 + token 门禁', async () => {
  const store = new WorldStore();
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    store.createWorld('w1');
    store.upsertScene({
      worldId: 'w1', sceneId: 'forest', name: '森林', terrainAsset: 'h', gridTiles: REQUIRED_GRID,
      pois: [], portals: [],
    });
    store.addCharacter(char('w1', 'c1', 'village'));
    const asset = store.putAsset({ bytes: Uint8Array.from([1, 2, 3]), mime: 'image/png' });
    const url = '/admin/worlds/w1/characters/c1';
    const H = { 'x-admin-token': 'sesame' };

    // 门禁：无 token / 坏 token → 403；不存在的角色 → 404
    assert.equal((await app.inject({ method: 'PATCH', url, body: {} })).statusCode, 403);
    assert.equal((await app.inject({ method: 'PATCH', url, headers: { 'x-admin-token': 'no' }, body: {} })).statusCode, 403);
    assert.equal((await app.inject({ method: 'PATCH', url: '/admin/worlds/w1/characters/ghost', headers: H, body: {} })).statusCode, 404);

    // 校验：未入库场景 / 越界坐标 / 不存在的资产 → 400，且一律不落库
    assert.equal((await app.inject({ method: 'PATCH', url, headers: H, body: { sceneId: 'desert' } })).statusCode, 400);
    assert.equal((await app.inject({ method: 'PATCH', url, headers: H, body: { position: { tileX: 500, tileY: 500 } } })).statusCode, 400);
    assert.equal((await app.inject({ method: 'PATCH', url, headers: H, body: { spriteAsset: 'nope' } })).statusCode, 400);
    assert.equal(store.getCharacter('w1', 'c1')?.sceneId, 'village', '校验失败不落库');

    // 三项一起修：搬去森林 seed 座位 + 指回旧立绘
    const res = await app.inject({
      method: 'PATCH', url, headers: H,
      body: { sceneId: 'forest', position: { tileX: 53, tileY: 28 }, spriteAsset: asset },
    });
    assert.equal(res.statusCode, 200);
    const c = store.getCharacter('w1', 'c1')!;
    assert.equal(c.sceneId, 'forest');
    assert.deepEqual(c.position, { tileX: 53, tileY: 28 });
    assert.equal(c.appearance.spriteAsset, asset);

    // 修完 positions_report 的 guard 语义应认新场景：forest 上报收、village 上报拒
    assert.equal(store.setCharacterTile('w1', 'c1', { tileX: 54, tileY: 28 }, 'forest'), true);
    assert.equal(store.setCharacterTile('w1', 'c1', { tileX: 1, tileY: 1 }, 'village'), false);
  } finally {
    await app.close();
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
