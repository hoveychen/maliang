import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  BUILTIN_ITEMS, getBuiltinItem, resolveBuiltin,
  footprintOrigin, rotatedFootprint, buildStaticOccupancy, validateTerrainItems,
  creationItemDef,
} from '../src/items.ts';
import { fallbackSdfPropSpec } from '../src/sdf_prop.ts';
import { argYawDeg, yawToArg, emptyTerrain, T_PATH, T_WATER, REQUIRED_GRID } from '../src/terrain.ts';
import { WorldStore } from '../src/persistence.ts';
import type { ItemDef } from '../src/types.ts';

const G = REQUIRED_GRID;
const at = (x: number, y: number) => y * G + x;

// ── 造物 footprint 随体型档（prop-size）────────────────────────────────────
test('creationItemDef: big 造物 footprint 3×3(+1环), small/medium 保持 1×1', () => {
  const big = creationItemDef('w1', 'p-big', { ...fallbackSdfPropSpec('big'), scale: 1.4 });
  assert.equal(big.footprintW, 3);
  assert.equal(big.footprintH, 3);
  const mid = creationItemDef('w1', 'p-mid', { ...fallbackSdfPropSpec('mid'), scale: 1.0 });
  assert.equal(mid.footprintW, 1);
  assert.equal(mid.footprintH, 1);
  const small = creationItemDef('w1', 'p-small', { ...fallbackSdfPropSpec('small'), scale: 0.7 });
  assert.equal(small.footprintW, 1);
  assert.equal(small.footprintH, 1);
});

// ── 内置 seed ────────────────────────────────────────────────────────────

test('内置 seed：id 唯一、footprint 奇数边、语义与旧硬编码表对齐', () => {
  const ids = BUILTIN_ITEMS.map((d) => d.id);
  assert.equal(new Set(ids).size, ids.length, 'id 不重复');
  for (const d of BUILTIN_ITEMS) {
    assert.equal(d.worldId, null, `${d.id} 是全局内置`);
    assert.equal(d.footprintW % 2, 1, `${d.id} footprint 奇数边（锚点居中）`);
    assert.equal(d.footprintH % 2, 1);
  }
  // 语义抽查（迁自 chunk_manager.gd 的 LANDMARKS/SDF_PROPS/散布）
  assert.equal(getBuiltinItem('well')!.pathOk, true, '水井特批压路');
  assert.equal(getBuiltinItem('house_0')!.footprintW, 3, '民居 3×3（旧 reserve=1）');
  assert.equal(getBuiltinItem('tuft_0')!.blocking, false, '草丛可穿行');
  assert.equal(getBuiltinItem('walking_hut')!.wander, 1.6);
  assert.equal(getBuiltinItem('hop_mailbox')!.wander, 1.2);
  assert.equal(getBuiltinItem('nope'), undefined);
});

// ── footprint 几何 ───────────────────────────────────────────────────────

test('footprintOrigin：奇数边锚点居中', () => {
  assert.deepEqual(footprintOrigin(10, 20, 1, 1), [10, 20]);
  assert.deepEqual(footprintOrigin(10, 20, 3, 3), [9, 19]);
});

test('rotatedFootprint：就近象限 90/270 交换宽高，方形恒等', () => {
  const def = { ...getBuiltinItem('house_0')!, footprintW: 3, footprintH: 1 };
  assert.deepEqual(rotatedFootprint(def, yawToArg(0)), [3, 1]);
  assert.deepEqual(rotatedFootprint(def, yawToArg(90)), [1, 3]);
  assert.deepEqual(rotatedFootprint(def, yawToArg(180)), [3, 1]);
  assert.deepEqual(rotatedFootprint(def, yawToArg(270)), [1, 3]);
  assert.deepEqual(rotatedFootprint(def, yawToArg(100)), [1, 3], '100° 就近 90°');
  assert.deepEqual(rotatedFootprint(getBuiltinItem('house_0')!, yawToArg(90)), [3, 3]);
});

test('yaw ↔ arg：256 档往返误差 < 1 档（手调角度不丢）', () => {
  for (const deg of [0, 40, 90, 150, 190, 210, 270, 300, 359]) {
    const back = argYawDeg(yawToArg(deg));
    const diff = Math.min(Math.abs(back - deg), 360 - Math.abs(back - deg));
    assert.ok(diff <= 360 / 256 / 2 + 1e-9, `${deg}° → ${back}°`);
  }
  assert.equal(yawToArg(360), 0);
  assert.equal(yawToArg(-90), yawToArg(270));
});

// ── 派生占用 + 语义校验 ──────────────────────────────────────────────────

/** 一棵树 + 一栋房的合法矩阵。 */
function terrainWithItems() {
  const t = emptyTerrain();
  t.palette = ['tree_puff_a', 'house_0', 'tuft_0'];
  t.itemRef[at(10, 10)] = 1;            // 树 1×1
  t.itemRef[at(30, 30)] = 2;            // 房 3×3 锚点居中 → (29..31)²
  t.itemRef[at(50, 50)] = 3;            // 草丛：非 blocking
  return t;
}

test('buildStaticOccupancy：blocking footprint 展开、草丛不占位', () => {
  const occ = buildStaticOccupancy(terrainWithItems(), resolveBuiltin);
  assert.equal(occ[at(10, 10)], 1, '树占自己');
  assert.equal(occ[at(10, 11)], 0, '树不越界');
  for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
    assert.equal(occ[at(30 + dx, 30 + dy)], 1, `房 footprint (${30 + dx},${30 + dy})`);
  }
  assert.equal(occ[at(28, 30)], 0, '房不越 3×3');
  assert.equal(occ[at(50, 50)], 0, '草丛不占位');
});

test('buildStaticOccupancy：footprint 环面 wrap（锚点贴边）', () => {
  const t = emptyTerrain();
  t.palette = ['house_0'];
  t.itemRef[at(0, 0)] = 1; // 3×3 锚点在原点 → 覆盖 (74,74)..(1,1)
  const occ = buildStaticOccupancy(t, resolveBuiltin);
  assert.equal(occ[at(74, 74)], 1);
  assert.equal(occ[at(1, 1)], 1);
  assert.equal(occ[at(2, 2)], 0);
});

test('拒收：palette 引用无法解析的实体', () => {
  const t = emptyTerrain();
  t.palette = ['ghost_item'];
  assert.throws(() => validateTerrainItems(t), /无法解析/);
});

test('拒收：占地冲突（两栋房 footprint 重叠）', () => {
  const t = emptyTerrain();
  t.palette = ['house_0'];
  t.itemRef[at(30, 30)] = 1;
  t.itemRef[at(32, 30)] = 1; // 3×3 与 3×3 相距 2 → 重叠一列
  assert.throws(() => validateTerrainItems(t), /冲突/);
});

test('拒收：占地压水 / 压路（除非 pathOk）/ 跨台阶', () => {
  const onWater = terrainWithItems();
  onWater.types[at(10, 10)] = T_WATER; onWater.depths[at(10, 10)] = 1;
  assert.throws(() => validateTerrainItems(onWater), /水面/);

  const onPath = terrainWithItems();
  onPath.types[at(29, 29)] = T_PATH; // 房 footprint 一角压路
  assert.throws(() => validateTerrainItems(onPath), /压路/);

  const wellOnPath = emptyTerrain();
  wellOnPath.palette = ['well'];
  wellOnPath.itemRef[at(37, 37)] = 1;
  for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) wellOnPath.types[at(37 + dx, 37 + dy)] = T_PATH;
  assert.doesNotThrow(() => validateTerrainItems(wellOnPath), 'pathOk 的水井可压路');

  const cliff = terrainWithItems();
  cliff.heights[at(31, 31)] = 2; // 房 footprint 一角抬高
  assert.throws(() => validateTerrainItems(cliff), /跨台阶/);
});

test('拒收：草丛（非 blocking）也不能长在水里', () => {
  const t = emptyTerrain();
  t.palette = ['tuft_0'];
  t.itemRef[at(5, 5)] = 1;
  t.types[at(5, 5)] = T_WATER;
  assert.throws(() => validateTerrainItems(t), /水面/);
});

test('edge 平面：tile 物品挂边 → 拒；贴纸（mount edge）→ 放行（sticker-items 起渲染二期已开）', () => {
  const t = terrainWithItems();
  t.edges[1][at(3, 3)] = 1; // palette[0] 是 tile 物品 → mount 错位
  assert.throws(() => validateTerrainItems(t), /挂在 edge/);

  const ok = terrainWithItems();
  ok.palette.push('sticker_sun');
  ok.edges[1][at(3, 3)] = ok.palette.length;
  assert.doesNotThrow(() => validateTerrainItems(ok));
});

test('合法矩阵通过校验', () => {
  assert.doesNotThrow(() => validateTerrainItems(terrainWithItems()));
});

// ── items 表（造物实体持久化）────────────────────────────────────────────

function creation(id: string, worldId = 'w1'): ItemDef {
  return {
    id, worldId, name: '小明的花', renderRef: 'sdf_inline',
    spec: { name: 'flower' } as ItemDef['spec'],
    footprintW: 1, footprintH: 1, blocking: true, pathOk: false, wander: 0,
  };
}

test('items 表：upsert → getItemDef 读回；内置优先级', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.upsertItem(creation('flower_xm'));

  const got = s.getItemDef('w1', 'flower_xm')!;
  assert.equal(got.renderRef, 'sdf_inline');
  assert.equal(got.name, '小明的花');
  assert.equal(s.getItemDef('w1', 'tree_puff_a')!.worldId, null, '内置从常量拿');
  assert.equal(s.getItemDef('w1', 'ghost'), undefined);
});

test('items 表：拒绝内置 id / builtin 定义 / 幽灵世界', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  assert.throws(() => s.upsertItem(creation('tree_puff_a')), /与内置冲突/);
  assert.throws(() => s.upsertItem({ ...creation('x'), worldId: null }), /builtin item 不入库/);
  assert.throws(() => s.upsertItem(creation('x', 'nope')), /world not found/);
});

test('items 表：按 world 隔离；itemResolver 内置+造物都可解析', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.createWorld('w2');
  s.upsertItem(creation('flower_xm', 'w1'));

  assert.equal(s.listWorldItems('w1').length, 1);
  assert.equal(s.listWorldItems('w2').length, 0);
  assert.equal(s.getItemDef('w2', 'flower_xm'), undefined);

  const resolve = s.itemResolver('w1');
  assert.equal(resolve('flower_xm')!.name, '小明的花');
  assert.equal(resolve('windmill')!.footprintW, 3);

  // 造物实体作为 palette 项参与校验
  const t = emptyTerrain();
  t.palette = ['flower_xm'];
  t.itemRef[at(7, 7)] = 1;
  assert.doesNotThrow(() => validateTerrainItems(t, resolve));
  const occ = buildStaticOccupancy(t, resolve);
  assert.equal(occ[at(7, 7)], 1);
});
