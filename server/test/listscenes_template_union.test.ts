// listScenes/getScene 的「新 template 场景零迁移传播到存量世界」回归。
//
// 背景（house-interiors 真机踩坑）：给 template 加了全新场景（如各室内）后，NEW 玩家 fresh 克隆拿到全部，
// 但【存量世界】的场景列表原本只返回它自己的行 + 对同名场景叠加 template meta——新场景本体不进列表，
// 客户端进门拿不到地形 → 保留旧场景地形 = 破房间。修法：listScenes 把 template 独有的场景【并上】，
// getScene 在世界缺自己行时回退到 template 场景。这样加新场景零逐世界迁移。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import type { Scene, ScenePortal } from '../src/types.ts';

function mkScene(worldId: string, sceneId: string, gridTiles: number, portals: ScenePortal[] = []): Scene {
  return { worldId, sceneId, name: sceneId, terrainAsset: `hash_${sceneId}`, gridTiles, pois: [], portals, homes: [], terrainVersion: 0 };
}

// 存量世界：建好时只克隆了 village_forest；cabin_interior 是它建好【之后】才加进 template 的新场景。
function seedStore(): WorldStore {
  const store = new WorldStore();
  store.createWorld(TEMPLATE_WORLD_ID);
  store.upsertScene(mkScene(TEMPLATE_WORLD_ID, 'village_forest', 100, [
    { tile: [24, 26], radius: 3, toScene: 'cabin_interior', toTile: [24, 22] },
  ]));
  store.upsertScene(mkScene(TEMPLATE_WORLD_ID, 'cabin_interior', 50, [
    { tile: [24, 30], radius: 2.5, toScene: 'village_forest', toTile: [24, 31] },
  ]));
  store.createWorld('w1');
  store.upsertScene(mkScene('w1', 'village_forest', 100)); // 只有 village_forest 自己的行，无 cabin_interior
  return store;
}

test('listScenes：新 template 场景自动进存量世界（union 独有场景，非只 overlay 同名）', () => {
  const scenes = seedStore().listScenes('w1');
  const ids = scenes.map((s) => s.sceneId).sort();
  assert.deepEqual(ids, ['cabin_interior', 'village_forest'], '新 template 场景 cabin_interior 应出现在存量世界列表');
  const cabin = scenes.find((s) => s.sceneId === 'cabin_interior')!;
  assert.equal(cabin.gridTiles, 50, 'cabin 取 template 的 grid（50 非 100）');
  assert.equal(cabin.terrainAsset, 'hash_cabin_interior', 'cabin 取 template 的 terrainAsset');
  assert.equal(cabin.portals.length, 1, 'cabin 带 template 的返回门');
  assert.equal(cabin.portals[0]!.toScene, 'village_forest');
});

test('listScenes：同名场景仍叠加 template meta（原 overlay 行为不回归）', () => {
  const vf = seedStore().listScenes('w1').find((s) => s.sceneId === 'village_forest')!;
  assert.equal(vf.portals.length, 1, 'village_forest 的门取 template overlay');
  assert.equal(vf.portals[0]!.toScene, 'cabin_interior');
});

test('getScene：存量世界缺自己的行时回退到 template 场景', () => {
  const cabin = seedStore().getScene('w1', 'cabin_interior');
  assert.ok(cabin, 'getScene 应回退到 template 的 cabin_interior，而非 undefined');
  assert.equal(cabin!.gridTiles, 50);
  assert.equal(cabin!.terrainAsset, 'hash_cabin_interior');
  assert.equal(cabin!.portals.length, 1);
});

test('getScene：template 与世界都没有的场景仍 undefined', () => {
  assert.equal(seedStore().getScene('w1', 'nope_interior'), undefined);
});

test('listScenes：template 世界本身不 union 自己（无重复）', () => {
  const ids = seedStore().listScenes(TEMPLATE_WORLD_ID).map((s) => s.sceneId).sort();
  assert.deepEqual(ids, ['cabin_interior', 'village_forest']);
});
