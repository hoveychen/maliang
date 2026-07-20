import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  emptyTerrain, encodeTerrain, decodeTerrain, isPresetGrid, PRESET_GRIDS,
  TerrainFormatError,
} from '../src/terrain.ts';
import { buildStaticOccupancy, resolveBuiltin } from '../src/items.ts';
import { isValidTile, MAX_GRID_TILES } from '../src/types.ts';

// ── 尺寸预设放开：50/75/100 都是 CHUNK_TILES=25 的倍数 ─────────────────────

test('PRESET_GRIDS = {50,75,100}，isPresetGrid 判定', () => {
  assert.deepEqual([...PRESET_GRIDS].sort((a, b) => a - b), [50, 75, 100]);
  for (const g of [50, 75, 100]) assert.equal(isPresetGrid(g), true, `${g} 是预设`);
  for (const g of [49, 60, 76, 90, 25, 0, 255]) assert.equal(isPresetGrid(g), false, `${g} 非预设`);
});

test('emptyTerrain(grid)：按尺寸建，平面长度 = grid²', () => {
  for (const g of [50, 75, 100]) {
    const t = emptyTerrain(g);
    assert.equal(t.gridW, g);
    assert.equal(t.gridH, g);
    assert.equal(t.types.length, g * g, `types 平面 ${g}²`);
    assert.equal(t.itemRef.length, g * g, `itemRef 平面 ${g}²`);
    for (const e of t.edges) assert.equal(e.length, g * g);
  }
  assert.equal(emptyTerrain().gridW, 75, '不传参默认 75');
});

test('encode/decode 往返：每档预设 gridW/gridH 与首字节尺寸正确', () => {
  for (const g of [50, 75, 100]) {
    const t = emptyTerrain(g);
    // 埋一个可辨识的路 tile，确认平面数据随尺寸正确往返
    t.types[g * g - 1] = 1; // T_PATH，最后一格
    const buf = encodeTerrain(t);
    assert.equal(buf[5], g, `header gridW=${g}`);
    assert.equal(buf[6], g, `header gridH=${g}`);
    const back = decodeTerrain(buf);
    assert.equal(back.gridW, g);
    assert.equal(back.gridH, g);
    assert.equal(back.types.length, g * g);
    assert.equal(back.types[g * g - 1], 1, '末格路 tile 保真');
  }
});

test('decode 拒收：非预设尺寸（方形）', () => {
  const buf = encodeTerrain(emptyTerrain(75));
  buf[5] = 76; buf[6] = 76; // 方形但非预设
  assert.throws(() => decodeTerrain(buf), TerrainFormatError);
});

test('decode 拒收：非方形（gridW≠gridH）', () => {
  const buf = encodeTerrain(emptyTerrain(100));
  buf[5] = 50; buf[6] = 100; // 头声称 50×100，非方形
  assert.throws(() => decodeTerrain(buf), TerrainFormatError);
});

// ── 坐标合法域：兜底用最松预设上界 ──────────────────────────────────────────

test('isValidTile：上界 = MAX_GRID_TILES(100)，兜底挡越界垃圾', () => {
  assert.equal(MAX_GRID_TILES, 100);
  assert.equal(isValidTile({ tileX: 0, tileY: 0 }), true);
  assert.equal(isValidTile({ tileX: 99, tileY: 99 }), true, '100 格场景的边角 tile 合法');
  assert.equal(isValidTile({ tileX: 100, tileY: 0 }), false, '恰好越界');
  assert.equal(isValidTile({ tileX: 0, tileY: 500 }), false, '早年大世界残留 tile 500 被挡');
  assert.equal(isValidTile({ tileX: -1, tileY: 0 }), false);
  assert.equal(isValidTile({ tileX: 1.5, tileY: 0 }), false, '非整数拒收');
});

// ── 占用位图 wrap 随场景尺寸 ────────────────────────────────────────────────

test('buildStaticOccupancy：footprint 环面 wrap 按本地形 gridW（100 格）', () => {
  const g = 100;
  const at = (x: number, y: number) => y * g + x;
  const t = emptyTerrain(g);
  t.palette = ['house_0'];
  t.itemRef[at(0, 0)] = 1; // 3×3 锚点在原点 → 覆盖 (99,99)..(1,1)（按 100 wrap）
  const occ = buildStaticOccupancy(t, resolveBuiltin);
  // 判别性断言：wrap 用 gridW=100 才会覆盖 (99,99)；若误用旧全局 75，(99,99)=0 而 (74,74)=1
  assert.equal(occ[at(99, 99)], 1, 'wrap 到 99（gridW=100）');
  assert.equal(occ[at(1, 1)], 1, '对角覆盖 (1,1)');
  assert.equal(occ[at(74, 74)], 0, 'wrap 不是全局 75');
});
