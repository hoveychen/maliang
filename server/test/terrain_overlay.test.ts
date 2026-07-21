// world-template-arch P3 地形 base+overlay 纯函数(terrain_overlay.ts):diff / compose / 序列化。
// 核心不变式:compose(base, diff(child, base)) 逐字节还原 child(迁移无损);且 base 改动的非 overlay
// tile 自动流入合成结果(作者改地形传播),孩子碰过的 tile 恒用 overlay 值(per-tile-wins)。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  emptyTerrain, encodeTerrain, decodeTerrain,
  T_PATH, T_WATER, yawToArg, type Terrain,
} from '../src/terrain.ts';
import {
  diffTerrain, composeTerrain, emptyOverlay, serializeOverlay, deserializeOverlay,
} from '../src/terrain_overlay.ts';

/** 在某 tile 挂一个物品(占 palette),返回其 ref。 */
function putItem(t: Terrain, idx: number, id: string, yawDeg = 0): void {
  let ref = t.palette.indexOf(id) + 1;
  if (ref === 0) { t.palette.push(id); ref = t.palette.length; }
  t.itemRef[idx] = ref;
  t.itemArg[idx] = yawToArg(yawDeg);
}
function putEdge(t: Terrain, idx: number, side: number, id: string): void {
  let ref = t.palette.indexOf(id) + 1;
  if (ref === 0) { t.palette.push(id); ref = t.palette.length; }
  t.edges[side]![idx] = ref;
}
function bytesEqual(a: Terrain, b: Terrain): boolean {
  return Buffer.from(encodeTerrain(a)).equals(Buffer.from(encodeTerrain(b)));
}
/**
 * 语义相等(而非逐字节):compose 的 palette 顺序按 base→overlay intern,child 有自己的顺序,
 * 故字节可能不同但每 tile 解引用后的 id 一致。用 diffTerrain 反查(它按解析后 id 比较)==空 即语义相等。
 * 语义相等对渲染足够——客户端读合成字节渲染,缓存键走 version 而非 hash(见 world.gd _apply_scene)。
 */
function sameSemantics(a: Terrain, b: Terrain): boolean {
  return diffTerrain(a, b).tiles.length === 0 && diffTerrain(b, a).tiles.length === 0;
}

// ── 核心不变式:diff→compose 无损还原(迁移路径) ──────────────────────────────

test('P3 compose(base, diff(child, base)) 语义还原 child(地貌+物品+边缘)', () => {
  const base = emptyTerrain(75);
  base.types[10] = T_PATH; base.heights[20] = 3; base.depths[30] = 0;
  putItem(base, 40, 'tree', 90);

  const child = decodeTerrain(encodeTerrain(base)); // 从 base 拷一份再改
  child.types[100] = T_WATER; child.depths[100] = 2;   // 孩子挖了水
  child.heights[200] = 5;                               // 抬高
  putItem(child, 300, 'crayon_house', 45);             // 孩子放了造物
  putItem(child, 40, 'flower', 0);                     // 覆盖 base 原本的 tree
  putEdge(child, 500, 1, 'sticker_star');              // 边缘贴纸

  const overlay = diffTerrain(child, base);
  const composed = composeTerrain(base, overlay);
  assert.ok(sameSemantics(composed, child), 'compose(base, diff) 与 child 语义逐 tile 一致');
  // 直接抽查几个 tile,别只靠 diff 自证
  const idAt = (t: Terrain, i: number) => (t.itemRef[i] === 0 ? null : t.palette[t.itemRef[i]! - 1]);
  assert.equal(composed.types[100], T_WATER);
  assert.equal(composed.depths[100], 2);
  assert.equal(composed.heights[200], 5);
  assert.equal(idAt(composed, 300), 'crayon_house');
  assert.equal(idAt(composed, 40), 'flower', '孩子覆盖 base 的 tree → 合成为 flower');
  assert.ok(encodeTerrain(composed).length > 0, '合成结果可编码');
});

test('P3 diff:child==base → 空 overlay;compose(base, 空) == base', () => {
  const base = emptyTerrain(75);
  base.types[5] = T_PATH; putItem(base, 6, 'well');
  const child = decodeTerrain(encodeTerrain(base));
  assert.equal(diffTerrain(child, base).tiles.length, 0, 'child==base → 无 diff tile');
  assert.ok(bytesEqual(composeTerrain(base, emptyOverlay(75, 75)), base), '空 overlay 合成 == base');
});

// ── 传播 + per-tile-wins:作者改 base 的非孩子 tile 流入;孩子 tile 恒胜 ─────────────

test('P3 §7:孩子改 tile A + 作者改 base 另一 tile B → 合成里 A 用孩子的、B 用作者的', () => {
  const base = emptyTerrain(75);           // 初始全草
  const child = decodeTerrain(encodeTerrain(base));
  child.types[111] = T_WATER; child.depths[111] = 1;   // 孩子在 A=111 挖水
  const overlay = diffTerrain(child, base);             // overlay 只含 A

  // 作者事后改 base 的 B=222(与孩子无关的另一格)为路
  const newBase = decodeTerrain(encodeTerrain(base));
  newBase.types[222] = T_PATH;

  const composed = composeTerrain(newBase, overlay);
  assert.equal(composed.types[111], T_WATER, 'A=111:孩子的水保留(per-tile-wins)');
  assert.equal(composed.depths[111], 1);
  assert.equal(composed.types[222], T_PATH, 'B=222:作者对 base 的新改动流入(传播)');
});

test('P3 per-tile-wins:作者改了孩子也碰过的同一 tile → 孩子胜', () => {
  const base = emptyTerrain(75);
  const child = decodeTerrain(encodeTerrain(base));
  child.types[50] = T_WATER; child.depths[50] = 2;     // 孩子把 50 挖成水
  const overlay = diffTerrain(child, base);

  const newBase = decodeTerrain(encodeTerrain(base));
  newBase.types[50] = T_PATH;                          // 作者也改了 50 → 路

  const composed = composeTerrain(newBase, overlay);
  assert.equal(composed.types[50], T_WATER, '冲突 tile:孩子胜');
  assert.equal(composed.depths[50], 2);
});

// ── palette 跨表 intern:base 与 overlay 各自 palette,合成后 ref 正确解引用 ──────────

test('P3 compose 跨 palette intern:base 物品与 overlay 物品在合成结果里都能解引用回原 id', () => {
  const base = emptyTerrain(75);
  putItem(base, 1, 'base_rock');           // base palette=[base_rock]
  const child = decodeTerrain(encodeTerrain(base));
  putItem(child, 2, 'kid_castle');         // 孩子加一个新物品(base 没有)
  putItem(child, 3, 'base_rock');          // 孩子也放了个 base 已有的物品

  const composed = composeTerrain(base, diffTerrain(child, base));
  const idAt = (idx: number) => composed.itemRef[idx] === 0 ? null : composed.palette[composed.itemRef[idx]! - 1];
  assert.equal(idAt(1), 'base_rock', 'base 原物品解引用不变');
  assert.equal(idAt(2), 'kid_castle', '孩子新物品被 intern 进合成 palette');
  assert.equal(idAt(3), 'base_rock', '孩子放的 base 已有物品复用同一 palette 项');
  // 合成结果能被编码器接受(palette 合法)
  assert.doesNotThrow(() => encodeTerrain(composed));
});

test('P3 compose:overlay 把某 tile 的物品清成 null → 合成结果该 tile 无物品', () => {
  const base = emptyTerrain(75);
  putItem(base, 7, 'base_tree');
  const child = decodeTerrain(encodeTerrain(base));
  child.itemRef[7] = 0; child.itemArg[7] = 0;   // 孩子移走了 base 的树
  const composed = composeTerrain(base, diffTerrain(child, base));
  assert.equal(composed.itemRef[7], 0, 'overlay 清物品 → 合成里也无物品');
});

// ── 序列化往返 ───────────────────────────────────────────────────────────────

test('P3 overlay 序列化往返:serialize→deserialize 后 compose 结果不变', () => {
  const base = emptyTerrain(75);
  const child = decodeTerrain(encodeTerrain(base));
  child.types[9] = T_PATH; putItem(child, 10, 'lamp', 180); putEdge(child, 11, 2, 'poster');
  const overlay = diffTerrain(child, base);
  const round = deserializeOverlay(serializeOverlay(overlay));
  assert.ok(sameSemantics(composeTerrain(base, round), child), '序列化往返后合成仍语义等于 child');
});

test('P3 diff/compose 尺寸不一致抛错(不静默错位)', () => {
  const b75 = emptyTerrain(75);
  const c100 = emptyTerrain(100);
  assert.throws(() => diffTerrain(c100, b75), /grid mismatch/);
  assert.throws(() => composeTerrain(b75, emptyOverlay(100, 100)), /grid mismatch/);
});
