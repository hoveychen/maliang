/**
 * 地形矩阵的唯一写入口（scene-items P3，设计见 docs/scene-item-refactor-design.md §3.2）。
 * 「把物品放在某处 = 修改那个 tile 的数据」——所有编辑（admin API / 后续玩法意图 /
 * 拾起摆放）都汇到 editSceneTerrain：校验 → 应用 → version+1 → terrain_patch 广播。
 * 客户端收到 patch 按 version 严格 +1 对齐，不合即全量重拉。
 */

import {
  decodeTerrain, yawToArg, MAX_PALETTE,
  T_WATER, VALID_TILE_TYPES, type Terrain,
} from './terrain.ts';
import { validateTerrainItems, type ItemResolver } from './items.ts';
import type { WorldStore } from './persistence.ts';
import type { WorldHub } from './world_hub.ts';
import type { ItemDef } from './types.ts';

/** 一条 tile 编辑（API 入参）：省略的字段不动。item=null 表示移除物品引用。 */
export interface TileEditInput {
  x: number;
  y: number;
  /** tile 类型（草/路/水）。改成非水自动清水深；改成水且未给 d 时默认浅水 1。 */
  t?: number;
  /** 台阶级 0..255。 */
  h?: number;
  /** 水深（仅水 tile 合法）。 */
  d?: number;
  /** 挂物品（实体 id + 朝向角）/ null 移除。多 tile 物品写锚点。 */
  item?: { id: string; yawDeg?: number } | null;
  /** 边缘挂载（贴纸类薄片，side=0..3 对应 N/E/S/W）：id=null 清除该边。 */
  edge?: { side: number; id: string | null };
}

/** 广播给客户端的已应用编辑（item 已翻成 palette 索引）。 */
export interface AppliedEdit {
  x: number;
  y: number;
  t?: number;
  h?: number;
  d?: number;
  item?: [number, number] | null;
  /** [side, ref]，ref=0 表示该边已清空（与 u8 平面语义一致）。 */
  edge?: [number, number];
}

export class TerrainEditError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = 'TerrainEditError';
  }
}

/**
 * 把编辑应用到矩阵（原地改 terrain），返回广播载荷素材。
 * 全部应用完后整图重新语义校验（palette 可解析/footprint 冲突/压水压路/跨台阶）——
 * 编辑不是每帧发生，5625 格全扫是微秒级，换取规则单一权威（items.ts）。
 */
export function applyTileEdits(
  terrain: Terrain,
  edits: TileEditInput[],
  resolve: ItemResolver,
): { applied: AppliedEdit[]; paletteAppend: { index: number; itemId: string }[] } {
  if (edits.length === 0) throw new TerrainEditError('edits 为空');
  const applied: AppliedEdit[] = [];
  const paletteAppend: { index: number; itemId: string }[] = [];

  for (const e of edits) {
    if (!Number.isInteger(e.x) || !Number.isInteger(e.y) || e.x < 0 || e.x >= terrain.gridW || e.y < 0 || e.y >= terrain.gridH) {
      throw new TerrainEditError(`tile (${e.x},${e.y}) 越界`);
    }
    const i = e.y * terrain.gridW + e.x;
    const out: AppliedEdit = { x: e.x, y: e.y };

    if (e.t !== undefined) {
      if (!VALID_TILE_TYPES.has(e.t)) throw new TerrainEditError(`tile 类型 ${e.t} 非法`);
      terrain.types[i] = e.t;
      out.t = e.t;
      if (e.t !== T_WATER && terrain.depths[i] !== 0) {
        terrain.depths[i] = 0; // 填掉水面自动清水深
        out.d = 0;
      }
      if (e.t === T_WATER && e.d === undefined && terrain.depths[i] === 0) {
        terrain.depths[i] = 1; // 新挖的水默认浅水
        out.d = 1;
      }
    }
    if (e.h !== undefined) {
      if (!Number.isInteger(e.h) || e.h < 0 || e.h > 255) throw new TerrainEditError(`高度 ${e.h} 非法`);
      terrain.heights[i] = e.h;
      out.h = e.h;
    }
    if (e.d !== undefined) {
      if (!Number.isInteger(e.d) || e.d < 0 || e.d > 255) throw new TerrainEditError(`水深 ${e.d} 非法`);
      if (terrain.types[i] !== T_WATER && e.d !== 0) throw new TerrainEditError(`非水 tile (${e.x},${e.y}) 不能有水深`);
      terrain.depths[i] = e.d;
      out.d = e.d;
    }
    if (e.item !== undefined) {
      if (e.item === null) {
        terrain.itemRef[i] = 0;
        terrain.itemArg[i] = 0;
        out.item = null;
      } else {
        if (!resolve(e.item.id)) throw new TerrainEditError(`物品实体 ${JSON.stringify(e.item.id)} 不存在`);
        let ref = terrain.palette.indexOf(e.item.id) + 1;
        if (ref === 0) {
          if (terrain.palette.length >= MAX_PALETTE) throw new TerrainEditError(`palette 满（${MAX_PALETTE}）`);
          terrain.palette.push(e.item.id);
          ref = terrain.palette.length;
          paletteAppend.push({ index: ref, itemId: e.item.id });
        }
        const arg = yawToArg(e.item.yawDeg ?? 0);
        terrain.itemRef[i] = ref;
        terrain.itemArg[i] = arg;
        out.item = [ref, arg];
      }
    }
    if (e.edge !== undefined) {
      const { side, id } = e.edge;
      if (!Number.isInteger(side) || side < 0 || side > 3) throw new TerrainEditError(`edge side ${side} 非法`);
      if (id === null) {
        terrain.edges[side]![i] = 0;
        out.edge = [side, 0];
      } else {
        const def = resolve(id);
        if (!def) throw new TerrainEditError(`物品实体 ${JSON.stringify(id)} 不存在`);
        if (def.mount !== 'edge') throw new TerrainEditError(`物品 ${id} 不能挂边缘（mount=${def.mount ?? 'tile'}）`);
        let ref = terrain.palette.indexOf(id) + 1;
        if (ref === 0) {
          if (terrain.palette.length >= MAX_PALETTE) throw new TerrainEditError(`palette 满（${MAX_PALETTE}）`);
          terrain.palette.push(id);
          ref = terrain.palette.length;
          paletteAppend.push({ index: ref, itemId: id });
        }
        terrain.edges[side]![i] = ref;
        out.edge = [side, ref];
      }
    }
    applied.push(out);
  }

  try {
    validateTerrainItems(terrain, resolve); // 物品语义整图复检（占地冲突/压水压路/跨台阶）
  } catch (err) {
    throw new TerrainEditError((err as Error).message);
  }
  return { applied, paletteAppend };
}

/**
 * 场景地形编辑编排：读 blob → 应用 → 持久化（version+1）→ terrain_patch 广播。
 * 失败（校验不过/场景无矩阵）抛 TerrainEditError，库不落一字节。
 */
export function editSceneTerrain(
  store: WorldStore,
  hub: WorldHub | undefined,
  worldId: string,
  sceneId: string,
  edits: TileEditInput[],
  /**
   * 强制随 patch 带上的实体 id（即便其 palette 引用早已存在、非新增）。
   * 用于「实体定义本身变了而 tile 引用没变」的场景——当前是造物体型调整（A1 试用·还差一点，
   * def.spec.scale 改了但 palette ref 不变），客户端据此覆写目录里的旧 def 后按新 scale 重渲染。
   */
  forceIncludeDefs: string[] = [],
): { version: number; applied: AppliedEdit[]; paletteAppend: { index: number; itemId: string }[]; items: ItemDef[] } {
  const rec = store.getSceneTerrain(worldId, sceneId);
  if (!rec) throw new TerrainEditError(`scene ${worldId}/${sceneId} 无地形矩阵`);
  const terrain = decodeTerrain(rec.bytes); // 合成地形（overlay 世界=base+overlay；老式=世界自己 blob）
  const resolve = store.itemResolver(worldId);
  const { applied, paletteAppend } = applyTileEdits(terrain, edits, resolve);

  // base+overlay P3：落库由 store 决定 overlay（重 diff 出 tile-diff）还是老式全量 blob；返回对外新版本。
  const version = store.commitSceneTerrain(worldId, sceneId, terrain);

  // 新引用实体的定义随 patch 带上（客户端可能没见过该造物）
  const items = paletteAppend.map((p) => resolve(p.itemId)!).filter(Boolean);
  // 强制携带的实体（定义变了但引用没变，如体型调整后的造物）：去重后追加。
  for (const id of forceIncludeDefs) {
    if (items.some((d) => d.id === id)) continue;
    const d = resolve(id);
    if (d) items.push(d);
  }
  hub?.broadcast(worldId, {
    type: 'terrain_patch', worldId, sceneId, version, paletteAppend, items, edits: applied,
  });
  return { version, applied, paletteAppend, items };
}
