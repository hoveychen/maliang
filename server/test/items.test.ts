import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  BUILTIN_ITEMS, getBuiltinItem, resolveBuiltin,
  footprintOrigin, rotatedFootprint, buildStaticOccupancy, validateTerrainItems,
  creationItemDef,
} from '../src/items.ts';
import { fallbackSdfPropSpec } from '../src/sdf_prop.ts';
import { argYawDeg, yawToArg, emptyTerrain, encodeTerrain, T_PATH, T_WATER, REQUIRED_GRID } from '../src/terrain.ts';
import { WorldStore } from '../src/persistence.ts';
import { DEFAULT_SCENE, type ItemDef } from '../src/types.ts';

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

// 真实比例家具（interior-camera-and-size）：非方形/偶数 footprint，NW 锚点展开（见 footprintOrigin）。
const NON_SQUARE_FURNITURE: Record<string, [number, number]> = {
  toy_bed_single: [1, 2],
  toy_bed_bunk: [1, 2],
  toy_sofa: [2, 1],
  toy_table: [2, 2],
};

test('内置 seed：id 唯一、footprint 分档合法（正整数，偶数走 NW 锚点）、语义与旧硬编码表对齐', () => {
  const ids = BUILTIN_ITEMS.map((d) => d.id);
  assert.equal(new Set(ids).size, ids.length, 'id 不重复');
  // 全量纲化：footprint=地基=尺寸唯一真相。奇数边居中锚点、偶数边（2×2 小设施/非方形家具）NW 锚点，
  // 两者 footprintOrigin 都支持——故不再强制奇数边，只守正整数。visualTilesW/H 若存在须 ≥ footprint。
  for (const d of BUILTIN_ITEMS) {
    assert.equal(d.worldId, null, `${d.id} 是全局内置`);
    const rect = NON_SQUARE_FURNITURE[d.id];
    if (rect) {
      assert.deepEqual([d.footprintW, d.footprintH], rect, `${d.id} 真实比例 footprint`);
    } else {
      assert.ok(Number.isInteger(d.footprintW) && d.footprintW >= 1, `${d.id} footprintW 正整数`);
      assert.ok(Number.isInteger(d.footprintH) && d.footprintH >= 1, `${d.id} footprintH 正整数`);
    }
    if (d.visualTilesW !== undefined) assert.ok(d.visualTilesW >= d.footprintW, `${d.id} 视觉宽 ≥ 地基宽`);
    if (d.visualTilesH !== undefined) assert.ok(d.visualTilesH >= d.footprintH, `${d.id} 视觉高 ≥ 地基高`);
  }
  // 分档抽查（老板 2026-07-23 拍板的 footprint 分档表）
  assert.equal(getBuiltinItem('mk_castle')!.footprintW, 7, '城堡类 7×7');
  assert.equal(getBuiltinItem('roman_fort')!.footprintW, 7, '罗马要塞 7×7');
  assert.equal(getBuiltinItem('city_tower_a')!.footprintW, 5, '高楼 5×5');
  assert.equal(getBuiltinItem('mv_church')!.footprintW, 5, '教堂 5×5');
  assert.equal(getBuiltinItem('mk_barracks')!.footprintW, 5, '兵营 5×5');
  assert.equal(getBuiltinItem('house_0')!.footprintW, 3, '民居 3×3');
  assert.equal(getBuiltinItem('well')!.footprintW, 2, '水井 小设施 2×2');
  assert.equal(getBuiltinItem('windmill')!.footprintW, 2, '风车 小设施 2×2');
  assert.equal(getBuiltinItem('mk_watchtower')!.footprintW, 2, '瞭望塔 小设施 2×2');
  assert.equal(getBuiltinItem('sea_fish_a')!.footprintW, 1, '小鱼 1×1');
  // 树：小地基密植（1×1），视觉靠 visualTiles 外延交叠树冠
  assert.equal(getBuiltinItem('snow_tree_a')!.footprintW, 1, '雪松地基 1×1');
  assert.deepEqual(
    [getBuiltinItem('snow_tree_a')!.visualTilesW, getBuiltinItem('snow_tree_a')!.visualTilesH],
    [2, 2],
    '雪松树冠视觉 2×2 超地基',
  );
  // 语义抽查（迁自 chunk_manager.gd 的 LANDMARKS/SDF_PROPS/散布）
  assert.equal(getBuiltinItem('well')!.pathOk, true, '水井特批压路');
  assert.equal(getBuiltinItem('tuft_0')!.blocking, false, '草丛可穿行');
  assert.equal(getBuiltinItem('walking_hut')!.wander, 1.6);
  assert.equal(getBuiltinItem('hop_mailbox')!.wander, 1.2);
  assert.equal(getBuiltinItem('nope'), undefined);
});

// ── footprint 几何 ───────────────────────────────────────────────────────

test('footprintOrigin：奇数边锚点居中、偶数边 NW 锚点', () => {
  assert.deepEqual(footprintOrigin(10, 20, 1, 1), [10, 20]);
  assert.deepEqual(footprintOrigin(10, 20, 3, 3), [9, 19]);
  // 偶数边（真实比例家具）：锚点落 NW 角，向 S/E 展开（(w-1)>>1 = 0）。
  assert.deepEqual(footprintOrigin(10, 20, 1, 2), [10, 20]);  // 床 1×2 → 占 (10,20)(10,21)
  assert.deepEqual(footprintOrigin(10, 20, 2, 2), [10, 20]);  // 桌 2×2 → 占 [10,11]×[20,21]
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

test('items 表：listWorldItems 按创造来源过滤；itemResolver 内置+造物都可解析', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.createWorld('w2');
  s.upsertItem(creation('flower_xm', 'w1'));

  // listWorldItems 仍按 creating world_id 过滤（provenance 视图不变）
  assert.equal(s.listWorldItems('w1').length, 1);
  assert.equal(s.listWorldItems('w2').length, 0);

  const resolve = s.itemResolver('w1');
  assert.equal(resolve('flower_xm')!.name, '小明的花');
  assert.equal(resolve('windmill')!.footprintW, 2);

  // 造物实体作为 palette 项参与校验
  const t = emptyTerrain();
  t.palette = ['flower_xm'];
  t.itemRef[at(7, 7)] = 1;
  assert.doesNotThrow(() => validateTerrainItems(t, resolve));
  const occ = buildStaticOccupancy(t, resolve);
  assert.equal(occ[at(7, 7)], 1);
});

// ── 全局共享（items-global-shared）：def 全局解析，world_id 只作创造来源记账 ─────
test('getItemDef 全局解析：world A 造的物品 id 在 world B 也解析出同一 def', () => {
  const s = new WorldStore();
  s.createWorld('wA');
  s.createWorld('wB');
  s.upsertItem(creation('flower_xm', 'wA'));

  const fromA = s.getItemDef('wA', 'flower_xm')!;
  const fromB = s.getItemDef('wB', 'flower_xm')!;
  assert.deepEqual(fromB, fromA, 'B 按 id 解析出与 A 同一 def（不再被 world_id 卡住）');
  assert.equal(fromB.worldId, 'wA', 'def 仍记创造来源 wA（provenance）');

  // itemResolver（任意 worldId 闭包）都全局解析
  assert.equal(s.itemResolver('wB')('flower_xm')!.name, '小明的花');

  // crux：world-scoped 造物被 world B 的场景 palette 引用时，校验/占用能全局解出 def
  const resolveB = s.itemResolver('wB');
  const t = emptyTerrain();
  t.palette = ['flower_xm'];
  t.itemRef[at(7, 7)] = 1;
  assert.doesNotThrow(() => validateTerrainItems(t, resolveB), 'B 引用 A 的造物 palette 校验通过');
  assert.equal(buildStaticOccupancy(t, resolveB)[at(7, 7)], 1);
});

/** 给 world 的 DEFAULT_SCENE 装一份 palette 引用了 refs 的地形。 */
function seedSceneWithPalette(s: WorldStore, worldId: string, refs: string[]): void {
  s.upsertScene({
    worldId, sceneId: DEFAULT_SCENE, name: '场景', terrainAsset: 'h',
    gridTiles: G, terrainVersion: 1, pois: [], portals: [],
  });
  const t = emptyTerrain();
  t.palette = [...refs];
  refs.forEach((_id, i) => { t.itemRef[at(5 + i, 5)] = i + 1; });
  s.setSceneTerrain(worldId, DEFAULT_SCENE, encodeTerrain(t), 1);
}

test('listReferencedItems：只含本世界引用到的造物（palette∪背包），不泄漏别世界造物，剔内置', () => {
  const s = new WorldStore();
  s.createWorld('wA');
  s.createWorld('wB');
  // A 造两个：flower_a（A 摆了、且 B 也引用=克隆场景 crux），secret_a（只在 A 摆，B 从不引用）
  s.upsertItem(creation('flower_a', 'wA'));
  s.upsertItem(creation('secret_a', 'wA'));
  // B 造一个：rocket_b（B 摆了 + 进 B 背包）
  s.upsertItem(creation('rocket_b', 'wB'));

  // A 的场景 palette 引用 flower_a + secret_a（+ 一个内置，验证剔除）
  seedSceneWithPalette(s, 'wA', ['flower_a', 'secret_a', 'tree_puff_a']);
  // B 的场景 palette 引用 rocket_b + flower_a（crux：引用了 A 造的物品）
  seedSceneWithPalette(s, 'wB', ['rocket_b', 'flower_a']);
  s.bagAdd('wB', 'child', 'rocket_b'); // rocket_b 也在 B 背包

  const aIds = s.listReferencedItems('wA').map((d) => d.id).sort();
  assert.deepEqual(aIds, ['flower_a', 'secret_a'], 'A 引用到 flower_a+secret_a；内置 tree_puff_a 剔除');

  const bIds = s.listReferencedItems('wB').map((d) => d.id).sort();
  assert.deepEqual(bIds, ['flower_a', 'rocket_b'], 'B 引用到自己的 rocket_b + 跨世界的 flower_a(crux)');
  assert.ok(!bIds.includes('secret_a'), '无泄漏：A 造但 B 未引用的 secret_a 不在 B 载荷');

  // 引用到的 def 是全局解析出的真 def（B 拿到 flower_a 的来源仍记 wA）
  const flowerFromB = s.listReferencedItems('wB').find((d) => d.id === 'flower_a')!;
  assert.equal(flowerFromB.worldId, 'wA');
  assert.equal(flowerFromB.name, '小明的花');
});

test('listReferencedItems：背包持有但未摆放的物品也在（客户端要渲染背包）', () => {
  const s = new WorldStore();
  s.createWorld('wA');
  s.upsertItem(creation('bagged_only', 'wA'));
  s.bagAdd('wA', 'child', 'bagged_only'); // 只进背包，没摆到 palette
  assert.deepEqual(s.listReferencedItems('wA').map((d) => d.id), ['bagged_only']);
});
