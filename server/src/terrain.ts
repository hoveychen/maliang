/**
 * 地形二进制格式（.mltr）编解码。
 *
 * 地形是环面世界的 tile 数据：每格三个字节——类型（草/路/水）、高度（0..N 级台阶）、
 * 水深（湖床下挖级数，只对水 tile 非零）。客户端 TerrainMap 的内存布局就是三个等长
 * 字节数组，本格式即其直接序列化。
 *
 * 布局（小端）：
 *   magic    "MLTR"      4 B
 *   version  u8          1 B
 *   gridW    u8          1 B
 *   gridH    u8          1 B
 *   tileSize f32         4 B
 *   types    u8[W*H]
 *   heights  u8[W*H]
 *   depths   u8[W*H]
 *
 * 75×75 → 11 + 3×5625 = 16886 B（gzip 后实测 495 B）。
 */

export const TERRAIN_MAGIC = 'MLTR';
export const TERRAIN_VERSION = 1;
export const HEADER_BYTES = 11;

/**
 * 第一版所有场景一律 75×75。
 * 客户端 WorldGrid.GRID_TILES 有两处编译期 const 推导（chunk_manager 的 CHUNKS_PER_SIDE、
 * occupancy_map 的 CELLS），运行期值喂不进去——放开尺寸要先改那两处，是独立的一件事。
 */
export const REQUIRED_GRID = 75;
export const DEFAULT_TILE_SIZE = 2.0;

/** 地形 tile 类型，与客户端 TerrainMap.T_* 一一对应。 */
export const T_GRASS = 0;
export const T_PATH = 1;
export const T_WATER = 2;

export interface Terrain {
  gridW: number;
  gridH: number;
  tileSize: number;
  types: Uint8Array;
  heights: Uint8Array;
  depths: Uint8Array;
}

export class TerrainFormatError extends Error {
  constructor(reason: string) {
    super(`bad terrain payload: ${reason}`);
    this.name = 'TerrainFormatError';
  }
}

/** 三个数组必须等长且等于 gridW*gridH，否则解码出来的地图会整体错位。 */
function assertPlanes(t: Terrain): void {
  const n = t.gridW * t.gridH;
  if (t.types.length !== n) throw new TerrainFormatError(`types length ${t.types.length} != ${n}`);
  if (t.heights.length !== n) throw new TerrainFormatError(`heights length ${t.heights.length} != ${n}`);
  if (t.depths.length !== n) throw new TerrainFormatError(`depths length ${t.depths.length} != ${n}`);
}

export function encodeTerrain(t: Terrain): Uint8Array {
  assertPlanes(t);
  if (t.gridW > 255 || t.gridH > 255 || t.gridW < 1 || t.gridH < 1) {
    throw new TerrainFormatError(`grid ${t.gridW}x${t.gridH} out of u8 range`);
  }
  const n = t.gridW * t.gridH;
  const out = new Uint8Array(HEADER_BYTES + 3 * n);
  const view = new DataView(out.buffer);

  for (let i = 0; i < 4; i++) out[i] = TERRAIN_MAGIC.charCodeAt(i);
  out[4] = TERRAIN_VERSION;
  out[5] = t.gridW;
  out[6] = t.gridH;
  view.setFloat32(7, t.tileSize, true);

  out.set(t.types, HEADER_BYTES);
  out.set(t.heights, HEADER_BYTES + n);
  out.set(t.depths, HEADER_BYTES + 2 * n);
  return out;
}

/**
 * 解码并校验。任何一处不对就抛 TerrainFormatError——地形错位是那种「跑起来才发现、
 * 而且看起来像渲染 bug」的故障，宁可入库时就拒收。
 */
export function decodeTerrain(buf: Uint8Array): Terrain {
  if (buf.length < HEADER_BYTES) throw new TerrainFormatError(`too short: ${buf.length} B`);

  const magic = String.fromCharCode(buf[0]!, buf[1]!, buf[2]!, buf[3]!);
  if (magic !== TERRAIN_MAGIC) throw new TerrainFormatError(`magic ${JSON.stringify(magic)}`);

  const version = buf[4]!;
  if (version !== TERRAIN_VERSION) throw new TerrainFormatError(`version ${version}, expect ${TERRAIN_VERSION}`);

  const gridW = buf[5]!;
  const gridH = buf[6]!;
  if (gridW !== REQUIRED_GRID || gridH !== REQUIRED_GRID) {
    throw new TerrainFormatError(`grid ${gridW}x${gridH}, 第一版只接受 ${REQUIRED_GRID}x${REQUIRED_GRID}`);
  }

  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const tileSize = view.getFloat32(7, true);
  if (!Number.isFinite(tileSize) || tileSize <= 0) throw new TerrainFormatError(`tileSize ${tileSize}`);

  const n = gridW * gridH;
  const want = HEADER_BYTES + 3 * n;
  if (buf.length !== want) throw new TerrainFormatError(`length ${buf.length}, expect ${want}`);

  const types = buf.slice(HEADER_BYTES, HEADER_BYTES + n);
  const heights = buf.slice(HEADER_BYTES + n, HEADER_BYTES + 2 * n);
  const depths = buf.slice(HEADER_BYTES + 2 * n, want);

  for (const v of types) {
    if (v !== T_GRASS && v !== T_PATH && v !== T_WATER) throw new TerrainFormatError(`tile type ${v}`);
  }
  // 非水格不该有水深——真出现说明导出端画错了，别把错误数据喂给渲染
  for (let i = 0; i < n; i++) {
    if (types[i] !== T_WATER && depths[i] !== 0) throw new TerrainFormatError(`depth ${depths[i]} on non-water tile ${i}`);
  }

  return { gridW, gridH, tileSize, types, heights, depths };
}
