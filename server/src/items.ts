/**
 * 物品实体：内置 seed + 地形矩阵的语义校验/派生占用（纯函数）。
 * 设计见 docs/scene-item-refactor-design.md。
 *
 * 内置定义是代码常量而非 DB seed 行——render_ref 与客户端 preload 映射表必须
 * 联动改，本质是代码契约；语音造物才落 items 表（persistence.ts）。
 * 语义（footprint/blocking/wander）逐项迁自客户端硬编码表
 * （scripts/chunk_manager.gd 的 LANDMARKS/SDF_PROPS/散布种类），迁完后客户端表删除。
 *
 * 占地约定（与客户端 _spawn_on_tile 的 reserve 语义对齐）：
 * footprint 奇数边、锚点居中——3×3 即旧 reserve=1。环面 wrap 由取模兜底。
 */

import type { ItemDef, } from './types.ts';
import { GRID_TILES } from './types.ts';
import type { SdfPropSpec } from './sdf_prop.ts';
import { T_PATH, T_WATER, TerrainFormatError, argYawDeg, type Terrain } from './terrain.ts';

/** 内置物品定义（≈22 行）。顺序即村庄 palette 的习惯顺序，无语义。 */
export const BUILTIN_ITEMS: readonly ItemDef[] = [
  // 散布布景：SDF 烘焙棉花糖树/灌木（MultiMesh 合批）
  builtin('tree_puff_a', '蓬蓬树·甲', 'baked:tree_puff_a', 1, true),
  builtin('tree_puff_b', '蓬蓬树·乙', 'baked:tree_puff_b', 1, true),
  builtin('tree_puff_c', '蓬蓬树·丙', 'baked:tree_puff_c', 1, true),
  builtin('bush_puff', '圆灌木', 'baked:bush_puff', 1, true),
  // 散布布景：KayKit 石/草丛（草丛可穿行，不占位）
  builtin('rock_0', '岩石·甲', 'kaykit:rock_0', 1, true),
  builtin('rock_1', '岩石·乙', 'kaykit:rock_1', 1, true),
  builtin('rock_2', '岩石·丙', 'kaykit:rock_2', 1, true),
  { ...builtin('tuft_0', '草丛·甲', 'kaykit:tuft_0', 1, false) },
  { ...builtin('tuft_1', '草丛·乙', 'kaykit:tuft_1', 1, false) },
  // 村庄地标建筑（3×3 = 旧 reserve=1）
  builtin('house_0', '蓝顶民居', 'kaykit:house_0', 3, true),
  builtin('house_1', '红顶民居', 'kaykit:house_1', 3, true),
  builtin('house_2', '黄顶民居', 'kaykit:house_2', 3, true),
  builtin('house_3', '绿顶民居', 'kaykit:house_3', 3, true),
  { ...builtin('well', '水井', 'kaykit:well', 3, true), pathOk: true }, // 地标特批压路（坐镇广场）
  builtin('windmill', '风车', 'kaykit:windmill', 3, true),
  // SDF 可动物件（打包内 spec，wander 为围绕锚点的游走半径）
  { ...builtin('walking_hut', '走路小屋', 'sdf_res:walking_hut', 3, true), wander: 1.6 },
  { ...builtin('hop_mailbox', '蹦跳信箱', 'sdf_res:hop_mailbox', 3, true), wander: 1.2 },
  builtin('nodding_flower', '点头花', 'sdf_res:nodding_flower', 1, true),
  builtin('pinwheel', '纸风车', 'sdf_res:pinwheel', 1, true),
  builtin('paper_note', '纸条', 'sdf_res:paper_note', 1, true),
  builtin('crayon', '蜡笔', 'sdf_res:crayon', 1, true),
  builtin('village_sign', '村口路牌', 'sdf_res:village_sign', 1, true),
  // 贴纸系列（挂 tile 边缘的薄片，docs/sticker-items-design.md）：不占位不阻挡，
  // 小红花商店购买进背包，允许拾回（贴错能揭下来）。
  sticker('sticker_sun', '太阳贴纸'),
  sticker('sticker_flower', '花朵贴纸'),
  sticker('sticker_star', '星星贴纸'),
  sticker('sticker_rainbow', '彩虹贴纸'),
  sticker('sticker_heart', '爱心贴纸'),
  sticker('sticker_butterfly', '蝴蝶贴纸'),
  sticker('sticker_moon', '月亮贴纸'),
  sticker('sticker_cloud', '云朵贴纸'),
  sticker('sticker_strawberry', '草莓贴纸'),
  sticker('sticker_smile', '笑脸贴纸'),
  sticker('sticker_flag', '小旗贴纸'),
  sticker('sticker_mushroom', '蘑菇贴纸'),
];

function builtin(id: string, name: string, renderRef: string, span: number, blocking: boolean): ItemDef {
  return { id, worldId: null, name, renderRef, footprintW: span, footprintH: span, blocking, pathOk: false, wander: 0 };
}

/** 贴纸：mount:'edge' 薄片，footprint/blocking/wander 对边缘物无意义（恒 1×1/false/0）。 */
function sticker(id: string, name: string): ItemDef {
  return { ...builtin(id, name, `sticker:${id.replace(/^sticker_/, '')}`, 1, false), pathOk: true, mount: 'edge' };
}

/**
 * 语音造物的实体行（spec 内联进 items 表）。占地统一 1×1（旧动态物件同款），
 * pathOk=true——孩子把玩具摆在路上是常态，不拦；wander 与客户端 _prop_wander 同款推导
 * （会动的物件给一点游走半径）。
 */
export function creationItemDef(worldId: string, id: string, spec: SdfPropSpec): ItemDef {
  return {
    id,
    worldId,
    name: spec.name || '小宝贝',
    renderRef: 'sdf_inline',
    spec,
    footprintW: 1,
    footprintH: 1,
    blocking: true,
    pathOk: true,
    wander: spec.locomotion && spec.locomotion.type !== 'none' ? 1.2 : 0,
  };
}

const BUILTIN_BY_ID = new Map(BUILTIN_ITEMS.map((d) => [d.id, d]));

export function getBuiltinItem(id: string): ItemDef | undefined {
  return BUILTIN_BY_ID.get(id);
}

/** 实体解析器：palette id → 定义。内置查常量表，造物由调用方接 items 表。 */
export type ItemResolver = (id: string) => ItemDef | undefined;

/** 只认内置（导出工具产的初始矩阵、无造物场景用）。 */
export const resolveBuiltin: ItemResolver = (id) => BUILTIN_BY_ID.get(id);

/** footprint 锚点居中展开的原点（奇数边居中；偶数边偏西北，当前无此形状）。 */
export function footprintOrigin(x: number, y: number, w: number, h: number): [number, number] {
  return [x - ((w - 1) >> 1), y - ((h - 1) >> 1)];
}

/** 朝向旋转后的 footprint 尺寸（就近象限，90°/270° 交换宽高；当前全方形，恒等）。 */
export function rotatedFootprint(def: ItemDef, arg: number): [number, number] {
  const quadrant = Math.round(argYawDeg(arg) / 90) % 4;
  return quadrant === 1 || quadrant === 3 ? [def.footprintH, def.footprintW] : [def.footprintW, def.footprintH];
}

const wrap = (v: number) => ((v % GRID_TILES) + GRID_TILES) % GRID_TILES;

/**
 * 从矩阵派生静态占用位图（tile 分辨率，1=被 blocking 物品 footprint 覆盖）。
 * 客户端 TerrainMap 的派生占用与此逐字节对齐（P4 参照实现）。
 * 语义非法（引用无法解析/占地冲突/压水…）直接抛——派生与校验是同一次遍历。
 */
export function buildStaticOccupancy(t: Terrain, resolve: ItemResolver): Uint8Array {
  const n = t.gridW * t.gridH;
  const occ = new Uint8Array(n);

  // palette 全部可解析（未被引用的空悬 palette 项也算错——palette 该压实）
  const defs: ItemDef[] = t.palette.map((id) => {
    const def = resolve(id);
    if (!def) throw new TerrainFormatError(`palette item ${JSON.stringify(id)} 无法解析`);
    return def;
  });

  for (let i = 0; i < n; i++) {
    const ref = t.itemRef[i]!;
    if (ref === 0) continue;
    const def = defs[ref - 1]!;
    const ax = i % t.gridW;
    const ay = Math.floor(i / t.gridW);

    // 边缘物（贴纸）不许挂 tile 正上方——mount 错位是数据损坏
    if (def.mount === 'edge') throw new TerrainFormatError(`edge 物品 ${def.id} at (${ax},${ay}) 挂在 itemRef`);

    // 非 blocking（草丛类）：纯点缀，只禁水面，不占位
    if (!def.blocking) {
      if (t.types[i] === T_WATER) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 落在水面`);
      continue;
    }

    const [w, h] = rotatedFootprint(def, t.itemArg[i]!);
    const [ox, oy] = footprintOrigin(ax, ay, w, h);
    const anchorHeight = t.heights[i]!;
    for (let dy = 0; dy < h; dy++) {
      for (let dx = 0; dx < w; dx++) {
        const j = wrap(oy + dy) * t.gridW + wrap(ox + dx);
        const ty = t.types[j]!;
        if (ty === T_WATER) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 占地覆盖水面`);
        if (ty === T_PATH && !def.pathOk) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 占地压路`);
        if (t.heights[j] !== anchorHeight) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 占地跨台阶`);
        if (occ[j]) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 占地与他物冲突`);
        occ[j] = 1;
      }
    }
  }
  return occ;
}

/**
 * 矩阵的物品语义校验（入库/编辑前守门）：palette 可解析、footprint 不压水/
 * 不压路（除非 pathOk）/不跨台阶/互不重叠。edge 平面（贴纸等薄片）只做引用
 * 合法性校验：可解析且 mount==='edge'，不参与占用（sticker-items 设计 §1.1）。
 */
export function validateTerrainItems(t: Terrain, resolve: ItemResolver = resolveBuiltin): void {
  for (let e = 0; e < 4; e++) {
    const plane = t.edges[e]!;
    for (let i = 0; i < plane.length; i++) {
      const ref = plane[i]!;
      if (ref === 0) continue;
      const id = t.palette[ref - 1];
      const def = id !== undefined ? resolve(id) : undefined;
      if (!def) throw new TerrainFormatError(`edge[${e}][${i}] 引用 ${ref} 无法解析`);
      if (def.mount !== 'edge') throw new TerrainFormatError(`tile 物品 ${def.id} 挂在 edge[${e}][${i}]`);
    }
  }
  buildStaticOccupancy(t, resolve);
}
