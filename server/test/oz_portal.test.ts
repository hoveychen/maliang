// 第一季册 5《绿野仙踪》：复活的多场景/portal 基建——主场景 village_forest ↔ 独立场景 oz 的
// 双向传送门必须互指、可 BFS 寻路、且落点与对向 portal 错开 > radius（防落地即弹回）。
//
// ⚠️ portal 坐标的唯一权威是客户端 tools/export_terrain.gd build_portal_json（导出时写进 .mltr 旁的
// portals.json，POST /admin/scenes 入库）。本测试把那两条边镜像过来做服务端寻路/防弹回断言——
// 改 export_terrain 的 oz/village_forest portal 坐标时，这里要同步（同 sticker 四处同口径的跨端约定）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { routeScenes } from '../src/scene_graph.ts';
import type { Scene, ScenePortal } from '../src/types.ts';

// —— 镜像 tools/export_terrain.gd build_portal_json ——
const VF_TO_OZ: ScenePortal = { tile: [30, 78], radius: 3, toScene: 'oz', toTile: [14, 14] };
const OZ_TO_VF: ScenePortal = { tile: [16, 20], radius: 3, toScene: 'village_forest', toTile: [26, 80] };

function mkScene(worldId: string, sceneId: string, gridTiles: number, portals: ScenePortal[]): Scene {
  return { worldId, sceneId, name: sceneId, terrainAsset: '', gridTiles, pois: [], portals, terrainVersion: 0 };
}

function seedOzWorld(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  store.upsertScene(mkScene('w1', 'village_forest', 100, [VF_TO_OZ]));
  store.upsertScene(mkScene('w1', 'oz', 75, [OZ_TO_VF]));
  return store;
}

/** 环面无关的平面距离（同格子坐标系，只用于近距离防弹回判定，两点都远小于半图故不 wrap）。 */
function dist(a: [number, number], b: [number, number]): number {
  return Math.hypot(a[0] - b[0], a[1] - b[1]);
}

test('oz portal：村庄主场景可 BFS 走到 oz（1 跳，走 village_forest 森林深处那座门）', () => {
  const store = seedOzWorld();
  const route = routeScenes(store, 'w1', 'village_forest', 'oz');
  assert.ok(route, '村庄可达 oz');
  assert.equal(route!.length, 1, '相邻 1 跳');
  assert.equal(route![0]!.toScene, 'oz');
  assert.deepEqual(route![0]!.portalTile, { tileX: 30, tileY: 78 });
});

test('oz portal：oz 可原路 BFS 走回村庄主场景（1 跳）', () => {
  const store = seedOzWorld();
  const route = routeScenes(store, 'w1', 'oz', 'village_forest');
  assert.ok(route, 'oz 可达村庄');
  assert.equal(route!.length, 1);
  assert.equal(route![0]!.toScene, 'village_forest');
  assert.deepEqual(route![0]!.portalTile, { tileX: 16, tileY: 20 });
});

test('oz portal：双向互指（各自的 toScene 指向对方）', () => {
  assert.equal(VF_TO_OZ.toScene, 'oz');
  assert.equal(OZ_TO_VF.toScene, 'village_forest');
});

test('oz portal：落点与对向传送门错开 > radius（防落地即弹回，arm/disarm 见 world.gd _step_portal）', () => {
  // 从 village_forest 进 oz，落在 oz 的 toTile；它必须离 oz 自己那座返回门 > 其 radius，否则一落地就被弹回村庄。
  assert.ok(dist(VF_TO_OZ.toTile, OZ_TO_VF.tile) > OZ_TO_VF.radius,
    `oz 落点 ${VF_TO_OZ.toTile} 离 oz 返回门 ${OZ_TO_VF.tile} 必须 > ${OZ_TO_VF.radius}`);
  // 反向同理：从 oz 回村庄，落在 village_forest 的 toTile，必须离 village_forest 那座去 oz 的门 > radius。
  assert.ok(dist(OZ_TO_VF.toTile, VF_TO_OZ.tile) > VF_TO_OZ.radius,
    `村庄落点 ${OZ_TO_VF.toTile} 离村庄去 oz 门 ${VF_TO_OZ.tile} 必须 > ${VF_TO_OZ.radius}`);
});
