import { test } from 'node:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';
import {
  encodeTerrain, decodeTerrain, emptyTerrain, TerrainFormatError,
  HEADER_BYTES, PLANES_V2, REQUIRED_GRID, DEFAULT_TILE_SIZE,
  TERRAIN_VERSION, TERRAIN_VERSION_1,
  T_GRASS, T_PATH, T_WATER, T_SAND, T_SNOW, T_TILE, type Terrain,
} from '../src/terrain.ts';

const N = REQUIRED_GRID * REQUIRED_GRID;

/** 造一份合法地形：默认全草地，指定几格水（带水深）与路。 */
function terrain(mut?: (t: Terrain) => void): Terrain {
  const t = emptyTerrain();
  t.types[0] = T_WATER; t.depths[0] = 2;   // 深水
  t.types[1] = T_PATH;
  t.heights[2] = 8;                         // 实测主峰最高 8 级
  mut?.(t);
  return t;
}

/** 手工拼一份 v1 载荷（旧导出工具/存量库的格式）。 */
function v1Bytes(mut?: (t: Terrain) => void): Uint8Array {
  const t = terrain(mut);
  const out = new Uint8Array(HEADER_BYTES + 3 * N);
  const view = new DataView(out.buffer);
  for (let i = 0; i < 4; i++) out[i] = 'MLTR'.charCodeAt(i);
  out[4] = TERRAIN_VERSION_1;
  out[5] = REQUIRED_GRID;
  out[6] = REQUIRED_GRID;
  view.setFloat32(7, DEFAULT_TILE_SIZE, true);
  out.set(t.types, HEADER_BYTES);
  out.set(t.heights, HEADER_BYTES + N);
  out.set(t.depths, HEADER_BYTES + 2 * N);
  return out;
}

test('v2 round-trip：九平面 + palette 逐字节一致', () => {
  const t = terrain((x) => {
    x.palette = ['tree_puff_a', 'house_0', '小明的花'];
    x.itemRef[100] = 1; x.itemArg[100] = 57;   // yaw ≈80°
    x.itemRef[200] = 3; x.itemArg[200] = 128;  // yaw 180°
  });
  const back = decodeTerrain(encodeTerrain(t));

  assert.equal(back.gridW, REQUIRED_GRID);
  assert.equal(back.tileSize, DEFAULT_TILE_SIZE);
  assert.deepEqual(back.types, t.types);
  assert.deepEqual(back.heights, t.heights);
  assert.deepEqual(back.depths, t.depths);
  assert.deepEqual(back.itemRef, t.itemRef);
  assert.deepEqual(back.itemArg, t.itemArg);
  for (let e = 0; e < 4; e++) assert.deepEqual(back.edges[e], t.edges[e]);
  assert.deepEqual(back.palette, ['tree_puff_a', 'house_0', '小明的花']);
});

test('v2 体积：11 + 9×N + palette 尾段', () => {
  const empty = encodeTerrain(terrain());
  assert.equal(empty.length, HEADER_BYTES + PLANES_V2 * N + 1, '空 palette 只有 count 一个字节');

  const withPalette = encodeTerrain(terrain((x) => { x.palette = ['ab', 'cde']; }));
  assert.equal(withPalette.length, HEADER_BYTES + PLANES_V2 * N + 1 + (1 + 2) + (1 + 3));
});

test('头部字段：magic / version=2 落在约定位置', () => {
  const buf = encodeTerrain(terrain());
  assert.equal(String.fromCharCode(buf[0]!, buf[1]!, buf[2]!, buf[3]!), 'MLTR');
  assert.equal(buf[4], TERRAIN_VERSION);
  assert.equal(buf[5], REQUIRED_GRID);
  assert.equal(buf[6], REQUIRED_GRID);
});

test('v1 兼容：三平面读回，item/edge 平面补零、palette 为空', () => {
  const back = decodeTerrain(v1Bytes());
  assert.equal(back.types[0], T_WATER);
  assert.equal(back.depths[0], 2);
  assert.equal(back.heights[2], 8);
  assert.equal(back.itemRef.length, N);
  assert.ok(back.itemRef.every((v) => v === 0));
  assert.ok(back.edges.every((p) => p.every((v) => v === 0)));
  assert.deepEqual(back.palette, []);
});

test('v1 兼容：长度对不上 v1 声明照样拒收', () => {
  assert.throws(() => decodeTerrain(v1Bytes().slice(0, HEADER_BYTES + 3 * N - 1)), /length/);
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

test('拒收：长度对不上（截断/palette 后多余尾巴）', () => {
  const buf = encodeTerrain(terrain());
  assert.throws(() => decodeTerrain(buf.slice(0, buf.length - 1)), /length|truncated/);

  const longer = new Uint8Array(buf.length + 1);
  longer.set(buf);
  assert.throws(() => decodeTerrain(longer), /多余尾巴/);
});

test('拒收：itemRef 索引越出 palette', () => {
  const buf = encodeTerrain(terrain((x) => { x.palette = ['tree_puff_a']; }));
  buf[HEADER_BYTES + 3 * N + 7] = 2; // palette 只有 1 项，itemRef 却写 2
  assert.throws(() => decodeTerrain(buf), /itemRef\[7\] = 2/);
});

test('拒收：edge 索引越出 palette', () => {
  const buf = encodeTerrain(terrain());
  buf[HEADER_BYTES + 5 * N + 9] = 1; // edgeN 平面，空 palette
  assert.throws(() => decodeTerrain(buf), /edgeN\[9\] = 1/);
});

test('拒收：palette 截断 / 空项 / 重复项', () => {
  const good = encodeTerrain(terrain((x) => { x.palette = ['ab', 'ab2']; }));
  assert.throws(() => decodeTerrain(good.slice(0, good.length - 2)), /truncated|length/);

  const emptyEntry = encodeTerrain(terrain((x) => { x.palette = ['ab']; }));
  emptyEntry[HEADER_BYTES + PLANES_V2 * N + 1] = 0; // len=0
  assert.throws(() => decodeTerrain(emptyEntry), /empty|truncated|length|多余/);

  const t = terrain();
  t.palette = ['same', 'same'];
  assert.throws(() => decodeTerrain(encodeTerrain(t)), /duplicate/);
});

test('拒收：非法 tile 类型', () => {
  const buf = encodeTerrain(terrain());
  buf[HEADER_BYTES + 5] = 99; // 99 不在合法集 {0,1,2,5..12}
  assert.throws(() => decodeTerrain(buf), /tile type 99/);
});

test('拒收：3/4 是崖壁 B 码不作 tile 类型', () => {
  // 崖唇=3/崖壁=4 只活在客户端 atlas B 通道，从不存进 types 平面
  const buf = encodeTerrain(terrain());
  buf[HEADER_BYTES + 5] = 3;
  assert.throws(() => decodeTerrain(buf), /tile type 3/);
});

test('新增地表类型 sand/snow/tile 往返', () => {
  const t = terrain();
  // 用干净的陆地格（避开 helper 里的水/深度格），三种新地表都应无损往返
  t.types[10] = T_SAND; t.depths[10] = 0;
  t.types[11] = T_SNOW; t.depths[11] = 0;
  t.types[12] = T_TILE; t.depths[12] = 0;
  const back = decodeTerrain(encodeTerrain(t));
  assert.equal(back.types[10], T_SAND);
  assert.equal(back.types[11], T_SNOW);
  assert.equal(back.types[12], T_TILE);
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

test('编码期自检：平面长度与 grid 不符 / palette 超上限直接抛', () => {
  const t = terrain();
  t.types = new Uint8Array(N - 1);
  assert.throws(() => encodeTerrain(t), /types length/);

  const t2 = terrain();
  t2.itemRef = new Uint8Array(N + 1);
  assert.throws(() => encodeTerrain(t2), /itemRef length/);

  const t3 = terrain();
  t3.palette = Array.from({ length: 256 }, (_, i) => `it${i}`);
  assert.throws(() => encodeTerrain(t3), /palette 256/);
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
    terrainAsset: 'abc123', gridTiles: REQUIRED_GRID, terrainVersion: 1,
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
