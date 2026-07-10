import { test } from 'node:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';
import {
  encodeTerrain, decodeTerrain, TerrainFormatError,
  HEADER_BYTES, REQUIRED_GRID, DEFAULT_TILE_SIZE, TERRAIN_VERSION,
  T_GRASS, T_PATH, T_WATER, type Terrain,
} from '../src/terrain.ts';

const N = REQUIRED_GRID * REQUIRED_GRID;

/** 造一份合法地形：默认全草地，指定几格水（带水深）与路。 */
function terrain(mut?: (t: Terrain) => void): Terrain {
  const t: Terrain = {
    gridW: REQUIRED_GRID, gridH: REQUIRED_GRID, tileSize: DEFAULT_TILE_SIZE,
    types: new Uint8Array(N), heights: new Uint8Array(N), depths: new Uint8Array(N),
  };
  t.types[0] = T_WATER; t.depths[0] = 2;   // 深水
  t.types[1] = T_PATH;
  t.heights[2] = 8;                         // 实测主峰最高 8 级
  mut?.(t);
  return t;
}

test('round-trip：编码再解码，三个平面逐字节一致', () => {
  const t = terrain();
  const back = decodeTerrain(encodeTerrain(t));

  assert.equal(back.gridW, REQUIRED_GRID);
  assert.equal(back.gridH, REQUIRED_GRID);
  assert.equal(back.tileSize, DEFAULT_TILE_SIZE);
  assert.deepEqual(back.types, t.types);
  assert.deepEqual(back.heights, t.heights);
  assert.deepEqual(back.depths, t.depths);
});

test('体积就是 11 + 3×gridW×gridH', () => {
  const buf = encodeTerrain(terrain());
  assert.equal(buf.length, HEADER_BYTES + 3 * N);
  assert.equal(buf.length, 16886, '75×75 → 16886 B');
});

test('头部字段：magic / version 落在约定位置', () => {
  const buf = encodeTerrain(terrain());
  assert.equal(String.fromCharCode(buf[0]!, buf[1]!, buf[2]!, buf[3]!), 'MLTR');
  assert.equal(buf[4], TERRAIN_VERSION);
  assert.equal(buf[5], REQUIRED_GRID);
  assert.equal(buf[6], REQUIRED_GRID);
});

test('拒收：magic 不对', () => {
  const buf = encodeTerrain(terrain());
  buf[0] = 'X'.charCodeAt(0);
  assert.throws(() => decodeTerrain(buf), TerrainFormatError);
});

test('拒收：版本号不认识', () => {
  const buf = encodeTerrain(terrain());
  buf[4] = 99;
  assert.throws(() => decodeTerrain(buf), TerrainFormatError);
});

test('拒收：网格尺寸不是 75×75（第一版锁死）', () => {
  const buf = encodeTerrain(terrain());
  buf[5] = 64;
  assert.throws(() => decodeTerrain(buf), /只接受 75x75/);
});

test('拒收：长度对不上头部声明（截断/多余尾巴）', () => {
  const buf = encodeTerrain(terrain());
  assert.throws(() => decodeTerrain(buf.slice(0, buf.length - 1)), /length/);

  const longer = new Uint8Array(buf.length + 1);
  longer.set(buf);
  assert.throws(() => decodeTerrain(longer), /length/);
});

test('拒收：非法 tile 类型', () => {
  const buf = encodeTerrain(terrain());
  buf[HEADER_BYTES + 5] = 7; // 既不是草也不是路/水
  assert.throws(() => decodeTerrain(buf), /tile type 7/);
});

test('拒收：非水格带水深（导出端画错了）', () => {
  // 实测真实地形：130 个水格，0 个非水格带水深——这条不变量是有据的
  const buf = encodeTerrain(terrain());
  buf[HEADER_BYTES + 2 * N + 10] = 1; // 第 10 格是草地，却给了水深
  assert.throws(() => decodeTerrain(buf), /non-water tile/);
});

test('拒收：太短的载荷（连头都不够）', () => {
  assert.throws(() => decodeTerrain(new Uint8Array(5)), /too short/);
});

test('编码期自检：平面长度与 grid 不符直接抛', () => {
  const t = terrain();
  t.types = new Uint8Array(N - 1);
  assert.throws(() => encodeTerrain(t), /types length/);
});

test('水格可以有水深，草/路格水深为 0 —— 合法数据不该被误杀', () => {
  const t = terrain((x) => {
    for (let i = 0; i < 100; i++) { x.types[i] = T_WATER; x.depths[i] = i % 3; }
    for (let i = 100; i < 200; i++) { x.types[i] = T_GRASS; x.depths[i] = 0; }
  });
  assert.doesNotThrow(() => decodeTerrain(encodeTerrain(t)));
});

// ── scenes 表 ────────────────────────────────────────────────────────────
import { WorldStore } from '../src/persistence.ts';
import { DEFAULT_SCENE, type Scene } from '../src/types.ts';

function scene(over: Partial<Scene> = {}): Scene {
  return {
    worldId: 'w1', sceneId: DEFAULT_SCENE, name: '村庄',
    terrainAsset: 'abc123', gridTiles: REQUIRED_GRID,
    pois: [{ tile: [24, 24], radius: 20, trigger: 'poi_pond', name: '池塘', aliases: ['湖', '水边'] }],
    portals: [],
    ...over,
  };
}

test('scenes：upsert → get 读回，pois/portals JSON 往返', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.upsertScene(scene());

  const got = s.getScene('w1', DEFAULT_SCENE)!;
  assert.equal(got.name, '村庄');
  assert.equal(got.terrainAsset, 'abc123');
  assert.equal(got.gridTiles, REQUIRED_GRID);
  assert.deepEqual(got.pois[0]!.aliases, ['湖', '水边']);
  assert.equal(got.pois[0]!.trigger, 'poi_pond');
  assert.deepEqual(got.portals, []);
});

test('scenes：同 (world, scene) 再 upsert 是更新不是插入', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.upsertScene(scene());
  s.upsertScene(scene({ terrainAsset: 'def456', name: '新村庄' }));

  assert.equal(s.listScenes('w1').length, 1);
  assert.equal(s.getScene('w1', DEFAULT_SCENE)!.terrainAsset, 'def456');
  assert.equal(s.getScene('w1', DEFAULT_SCENE)!.name, '新村庄');
});

test('scenes：按 world 隔离；listScenes 按 sceneId 排序', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.createWorld('w2');
  s.upsertScene(scene({ sceneId: 'village' }));
  s.upsertScene(scene({ sceneId: 'forest' }));
  s.upsertScene(scene({ worldId: 'w2', sceneId: 'beach' }));

  assert.deepEqual(s.listScenes('w1').map((x) => x.sceneId), ['forest', 'village']);
  assert.deepEqual(s.listScenes('w2').map((x) => x.sceneId), ['beach']);
  assert.equal(s.getScene('w2', 'village'), undefined);
});

test('scenes：世界不存在 → upsert 抛错，不建孤儿场景', () => {
  const s = new WorldStore();
  assert.throws(() => s.upsertScene(scene({ worldId: 'nope' })), /world not found/);
});

test('scenes：跨重启保留', () => {
  const dir = join(tmpdir(), 'maliang-test-scenes');
  rmSync(dir, { recursive: true, force: true });

  const s1 = new WorldStore(dir);
  s1.createWorld('w1');
  s1.upsertScene(scene({ portals: [{ tile: [70, 5], radius: 3, toScene: 'forest', toTile: [2, 40] }] }));

  const s2 = new WorldStore(dir);
  const got = s2.getScene('w1', DEFAULT_SCENE)!;
  assert.equal(got.portals[0]!.toScene, 'forest');
  assert.deepEqual(got.portals[0]!.toTile, [2, 40]);
});
