/**
 * 地形 base+overlay 合成（world-template-arch P3，设计见 docs/template-overlay-arch-design.md §3/§4）。
 *
 * 世界模板架构下,每个玩家世界的地形 = template base(作者内容,随作者更新走) + 该世界自己的 overlay
 * (孩子改过的 tile 的绝对状态)。读时 composeTerrain(base, overlay) 现算出该世界看到的地形:
 * 孩子碰过的 tile 用 overlay 的值(per-tile-wins),其余一律用 base——作者改 base 的非孩子 tile 自动流入。
 *
 * overlay 里 item/edge 存的是**实体 id 字符串**(不是 palette 索引),因为 base 与 overlay 各有自己的
 * palette;compose 时把 id intern 进合成结果的 palette,避免跨 palette 的索引重映射错位。
 *
 * 这两个函数是**纯函数**、无任何校验(compose 绝不 throw,坏数据也要能渲染出个东西,而不是让读路径崩)。
 * 语义校验(footprint 冲突/压水压路)只在**编辑入口** applyTileEdits 做——那时针对的是当时的合成结果。
 */

import type { Terrain } from './terrain.ts';

/** 一个 overlay tile:孩子在该 tile 的完整绝对状态(per-tile-wins)。 */
export interface OverlayTile {
  /** tile 线性下标 = y * gridW + x。 */
  idx: number;
  type: number;
  height: number;
  depth: number;
  /** 锚点物品实体 id + 朝向档(itemArg);null=该 tile 无物品。 */
  item: { id: string; arg: number } | null;
  /** 四条边缘挂载(N/E/S/W)的实体 id,或 null=该边空。长度恒 4。 */
  edges: (string | null)[];
}

/** 一个世界某场景相对 base 的地形 overlay。gridW/gridH 用于与 base 尺寸对齐校验。 */
export interface TerrainOverlay {
  gridW: number;
  gridH: number;
  tiles: OverlayTile[];
}

/** 空 overlay(世界地形 == base,没有任何孩子编辑)。 */
export function emptyOverlay(gridW: number, gridH: number): TerrainOverlay {
  return { gridW, gridH, tiles: [] };
}

/** 解析某 tile 的锚点物品(itemRef→palette id)。ref=0 → null。 */
function tileItem(t: Terrain, idx: number): { id: string; arg: number } | null {
  const ref = t.itemRef[idx]!;
  if (ref === 0) return null;
  return { id: t.palette[ref - 1]!, arg: t.itemArg[idx]! };
}

/** 解析某 tile 的四条边缘挂载(edge ref→palette id)。ref=0 → null。 */
function tileEdges(t: Terrain, idx: number): (string | null)[] {
  return t.edges.map((plane) => {
    const ref = plane[idx]!;
    return ref === 0 ? null : t.palette[ref - 1]!;
  });
}

/** 两地形的同一 tile 是否逐字段相等(地貌 + 物品 by id + 四边 by id)。 */
function sameTile(a: Terrain, b: Terrain, idx: number): boolean {
  if (a.types[idx] !== b.types[idx] || a.heights[idx] !== b.heights[idx] || a.depths[idx] !== b.depths[idx]) return false;
  const ia = tileItem(a, idx);
  const ib = tileItem(b, idx);
  if ((ia === null) !== (ib === null)) return false;
  if (ia && ib && (ia.id !== ib.id || ia.arg !== ib.arg)) return false;
  const ea = tileEdges(a, idx);
  const eb = tileEdges(b, idx);
  for (let s = 0; s < 4; s++) if (ea[s] !== eb[s]) return false;
  return true;
}

/**
 * child 相对 base 的 overlay:凡与 base 逐字段不同的 tile,记下 child 的完整绝对状态。
 * child == base 的 tile 不入 overlay(那些将随 base 走)。两者尺寸必须一致。
 */
export function diffTerrain(child: Terrain, base: Terrain): TerrainOverlay {
  if (child.gridW !== base.gridW || child.gridH !== base.gridH) {
    throw new Error(`overlay diff grid mismatch ${child.gridW}x${child.gridH} vs ${base.gridW}x${base.gridH}`);
  }
  const n = base.gridW * base.gridH;
  const tiles: OverlayTile[] = [];
  for (let idx = 0; idx < n; idx++) {
    if (sameTile(child, base, idx)) continue;
    tiles.push({
      idx,
      type: child.types[idx]!,
      height: child.heights[idx]!,
      depth: child.depths[idx]!,
      item: tileItem(child, idx),
      edges: tileEdges(child, idx),
    });
  }
  return { gridW: base.gridW, gridH: base.gridH, tiles };
}

/**
 * 把 overlay 叠到 base 上,现算该世界看到的完整地形。overlay tile 的 item/edge id 就地 intern 进
 * 合成 palette(base palette 打底,新 id 追加)。无校验——坏数据宁可渲染出错也别让读路径崩。
 */
export function composeTerrain(base: Terrain, overlay: TerrainOverlay): Terrain {
  if (overlay.gridW !== base.gridW || overlay.gridH !== base.gridH) {
    throw new Error(`overlay compose grid mismatch ${overlay.gridW}x${overlay.gridH} vs ${base.gridW}x${base.gridH}`);
  }
  const n = base.gridW * base.gridH;
  const out: Terrain = {
    gridW: base.gridW,
    gridH: base.gridH,
    tileSize: base.tileSize,
    types: Uint8Array.from(base.types),
    heights: Uint8Array.from(base.heights),
    depths: Uint8Array.from(base.depths),
    itemRef: Uint16Array.from(base.itemRef),
    itemArg: Uint8Array.from(base.itemArg),
    edges: [
      Uint16Array.from(base.edges[0]),
      Uint16Array.from(base.edges[1]),
      Uint16Array.from(base.edges[2]),
      Uint16Array.from(base.edges[3]),
    ],
    palette: [...base.palette],
  };
  const index = new Map<string, number>();
  out.palette.forEach((id, i) => index.set(id, i + 1)); // 1-based ref
  const intern = (id: string): number => {
    const found = index.get(id);
    if (found !== undefined) return found;
    out.palette.push(id);
    const ref = out.palette.length;
    index.set(id, ref);
    return ref;
  };
  for (const t of overlay.tiles) {
    const idx = t.idx;
    if (!Number.isInteger(idx) || idx < 0 || idx >= n) continue; // 防御:越界 tile 跳过
    out.types[idx] = t.type;
    out.heights[idx] = t.height;
    out.depths[idx] = t.depth;
    if (t.item === null) {
      out.itemRef[idx] = 0;
      out.itemArg[idx] = 0;
    } else {
      out.itemRef[idx] = intern(t.item.id);
      out.itemArg[idx] = t.item.arg;
    }
    for (let s = 0; s < 4; s++) {
      const eid = t.edges[s] ?? null;
      out.edges[s]![idx] = eid === null ? 0 : intern(eid);
    }
  }
  return out;
}

/** overlay ↔ 存储字符串(scenes.terrain_overlay 列)。JSON 直存,tile 稀疏故体量小、可读。 */
export function serializeOverlay(o: TerrainOverlay): string {
  return JSON.stringify(o);
}

export function deserializeOverlay(s: string): TerrainOverlay {
  const o = JSON.parse(s) as TerrainOverlay;
  if (typeof o.gridW !== 'number' || typeof o.gridH !== 'number' || !Array.isArray(o.tiles)) {
    throw new Error('bad terrain overlay json');
  }
  return o;
}
