/**
 * 地形矩阵的唯一写入口（scene-items P3，设计见 docs/scene-item-refactor-design.md §3.2）。
 * 「把物品放在某处 = 修改那个 tile 的数据」——所有编辑（admin API / 后续玩法意图 /
 * 拾起摆放）都汇到 editSceneTerrain：校验 → 应用 → version+1 → terrain_patch 广播。
 * 客户端收到 patch 按 version 严格 +1 对齐，不合即全量重拉。
 */

import {
  decodeTerrain, encodeTerrain, yawToArg, MAX_PALETTE,
  T_GRASS, T_PATH, T_WATER, type Terrain,
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
}

/** 广播给客户端的已应用编辑（item 已翻成 palette 索引）。 */
export interface AppliedEdit {
  x: number;
  y: number;
  t?: number;
  h?: number;
  d?: number;
  item?: [number, number] | null;
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
      if (e.t !== T_GRASS && e.t !== T_PATH && e.t !== T_WATER) throw new TerrainEditError(`tile 类型 ${e.t} 非法`);
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
): { version: number; applied: AppliedEdit[]; paletteAppend: { index: number; itemId: string }[]; items: ItemDef[] } {
  const rec = store.getSceneTerrain(worldId, sceneId);
  if (!rec) throw new TerrainEditError(`scene ${worldId}/${sceneId} 无地形矩阵`);
  const terrain = decodeTerrain(rec.bytes);
  const resolve = store.itemResolver(worldId);
  const { applied, paletteAppend } = applyTileEdits(terrain, edits, resolve);

  const version = rec.version + 1;
  store.setSceneTerrain(worldId, sceneId, encodeTerrain(terrain), version);

  // 新引用实体的定义随 patch 带上（客户端可能没见过该造物）
  const items = paletteAppend.map((p) => resolve(p.itemId)!).filter(Boolean);
  hub?.broadcast(worldId, {
    type: 'terrain_patch', worldId, sceneId, version, paletteAppend, items, edits: applied,
  });
  return { version, applied, paletteAppend, items };
}
