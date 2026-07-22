// 室内系统 MVP（home-interior P2）：主场景 village_forest ↔ 独立室内场景 home_interior 的
// 双向传送门必须互指、可 BFS 寻路、且落点与对向 portal 错开 > radius（防落地即弹回）。
//
// ⚠️ portal 坐标的唯一权威是客户端 tools/export_terrain.gd build_portal_json。本测试把两条边
// 镜像过来做服务端寻路/防弹回断言——改 export_terrain 的 village_forest/home_interior portal
// 坐标时，这里要同步（同 oz_portal.test.ts 的跨端约定）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { routeScenes } from '../src/scene_graph.ts';
import type { Scene, ScenePortal } from '../src/types.ts';

// —— 镜像 tools/export_terrain.gd build_portal_json ——
// village_forest 有两座门：去 oz（森林深处）+ 进室内（村核家门口）。
const VF_TO_OZ: ScenePortal = { tile: [30, 78], radius: 3, toScene: 'oz', toTile: [14, 14] };
const VF_TO_HOME: ScenePortal = { tile: [24, 26], radius: 3, toScene: 'home_interior', toTile: [24, 22] };
const HOME_TO_VF: ScenePortal = { tile: [24, 32], radius: 3, toScene: 'village_forest', toTile: [24, 31] };
const OZ_TO_VF: ScenePortal = { tile: [16, 20], radius: 3, toScene: 'village_forest', toTile: [26, 80] };

function mkScene(worldId: string, sceneId: string, gridTiles: number, portals: ScenePortal[]): Scene {
  return { worldId, sceneId, name: sceneId, terrainAsset: '', gridTiles, pois: [], portals, terrainVersion: 0 };
}

function seedHomeWorld(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  store.upsertScene(mkScene('w1', 'village_forest', 100, [VF_TO_OZ, VF_TO_HOME]));
  store.upsertScene(mkScene('w1', 'home_interior', 50, [HOME_TO_VF]));
  store.upsertScene(mkScene('w1', 'oz', 75, [OZ_TO_VF]));
  return store;
}

/** 平面距离（同格坐标系，近距离防弹回判定，两点都远小于半图故不 wrap）。 */
function dist(a: [number, number], b: [number, number]): number {
  return Math.hypot(a[0] - b[0], a[1] - b[1]);
}

test('home_interior portal：村庄主场景可 BFS 走进室内（1 跳，走村核家门口那座门）', () => {
  const store = seedHomeWorld();
  const route = routeScenes(store, 'w1', 'village_forest', 'home_interior');
  assert.ok(route, '村庄可达室内');
  assert.equal(route!.length, 1, '相邻 1 跳');
  assert.equal(route![0]!.toScene, 'home_interior');
  assert.deepEqual(route![0]!.portalTile, { tileX: 24, tileY: 26 });
});

test('home_interior portal：室内可原路 BFS 走回村庄主场景（1 跳）', () => {
  const store = seedHomeWorld();
  const route = routeScenes(store, 'w1', 'home_interior', 'village_forest');
  assert.ok(route, '室内可达村庄');
  assert.equal(route!.length, 1);
  assert.equal(route![0]!.toScene, 'village_forest');
  assert.deepEqual(route![0]!.portalTile, { tileX: 24, tileY: 32 });
});

test('home_interior portal：双向互指（各自的 toScene 指向对方）', () => {
  assert.equal(VF_TO_HOME.toScene, 'home_interior');
  assert.equal(HOME_TO_VF.toScene, 'village_forest');
});

test('home_interior portal：落点与对向传送门错开 > radius（防落地即弹回）', () => {
  // 从村庄进室内，落在室内 toTile；它必须离室内返回门 > 其 radius，否则一落地就被弹回村庄。
  assert.ok(dist(VF_TO_HOME.toTile, HOME_TO_VF.tile) > HOME_TO_VF.radius,
    `室内落点 ${VF_TO_HOME.toTile} 离室内返回门 ${HOME_TO_VF.tile} 必须 > ${HOME_TO_VF.radius}`);
  // 反向同理：从室内回村庄，落在村庄 toTile，必须离村庄那座家门 portal > radius。
  assert.ok(dist(HOME_TO_VF.toTile, VF_TO_HOME.tile) > VF_TO_HOME.radius,
    `村庄落点 ${HOME_TO_VF.toTile} 离村庄家门 ${VF_TO_HOME.tile} 必须 > ${VF_TO_HOME.radius}`);
});

test('home_interior portal：加了进室内的门后，去 oz 那条老路仍在（不回归）', () => {
  const store = seedHomeWorld();
  const route = routeScenes(store, 'w1', 'village_forest', 'oz');
  assert.ok(route, '村庄仍可达 oz');
  assert.equal(route![0]!.toScene, 'oz');
});
