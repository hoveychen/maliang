/**
 * 地形二进制格式（.mltr）编解码。
 *
 * 地形是环面世界的 tile 数据。v2 起一份矩阵即一个场景的完整静态描述
 * （设计见 docs/scene-item-refactor-design.md）：地貌三平面 + 物品引用平面 +
 * 边缘挂载平面（一期恒 0，数据位）+ palette 尾段（u8 索引 → 物品实体 id）。
 * 物品实体（内置布置物与语音造物同表）见 items.ts。
 *
 * 布局（小端）：
 *   magic    "MLTR"      4 B
 *   version  u8          1 B    v1=3 平面无 palette；v2=9 平面 + palette
 *   gridW    u8          1 B
 *   gridH    u8          1 B
 *   tileSize f32         4 B
 *   types    u8[W*H]            0 草 / 1 路 / 2 水
 *   heights  u8[W*H]            0..N 级台阶
 *   depths   u8[W*H]            水深（湖床下挖级数，只对水 tile 非零）
 *   -- 以下 v2 新增 --
 *   itemRef  u8[W*H]            0=无物品 / 1..count=palette 索引（多 tile 物品只写锚点）
 *   itemArg  u8[W*H]            朝向：全字节 256 档（arg×360/256 度）
 *   edgeN/E/S/W u8[W*H] ×4      边缘挂载 palette 索引，一期恒 0
 *   palette  count u8 + count × (len u8 + item_id UTF-8)
 *
 * v3（palette > 255 时自动启用）：itemRef 与 4 张边缘平面升 u16（小端），palette
 * count 尾段也升 u16——让单场景可同时引用 65535 种物品。itemArg（朝向）与地貌三
 * 平面仍 u8。palette ≤255 时编码器仍写 v2（字节与旧版逐字节一致，存量场景零膨胀）。
 * 三个版本解码侧全兼容（v1 存量/v2 存量/v3 新写）；编码侧按 palette 长度自适应选 v2/v3。
 *
 * 75×75 v1 → 11 + 3×5625 = 16886 B（gzip 后实测 495 B）；
 * v2 → 11 + 9×5625 + palette ≈ 50.7 KB（item 平面低熵，gzip 预计 <3 KB）；
 * v3 → 11 + 14×5625 + palette ≈ 78.8 KB（5 张升 u16 的平面 itemRef 低熵、4 边缘恒 0，gzip 后近乎无增量）。
 */

export const TERRAIN_MAGIC = 'MLTR';
export const TERRAIN_VERSION_1 = 1;
export const TERRAIN_VERSION = 2;
export const TERRAIN_VERSION_3 = 3;
export const HEADER_BYTES = 11;
/** v2 的平面数（v1 是前 3 张；v3 平面数同 9，只是 5 张变宽）。 */
export const PLANES_V2 = 9;
/**
 * palette 容量上限：v2 的 itemRef/count 是 u8（≤255），v3 升 u16（≤65535），
 * 0 恒留给「无物品」。编码器按 palette 长度自适应，>255 走 v3。
 */
export const MAX_PALETTE = 65535;

/**
 * 第一版所有场景一律 75×75。
 * 客户端 WorldGrid.GRID_TILES 有两处编译期 const 推导（chunk_manager 的 CHUNKS_PER_SIDE、
 * occupancy_map 的 CELLS），运行期值喂不进去——放开尺寸要先改那两处，是独立的一件事。
 */
export const REQUIRED_GRID = 75;
export const DEFAULT_TILE_SIZE = 2.0;

/**
 * 地形 tile 类型，与客户端 TerrainMap.T_* 一一对应。
 * 0/1/2 = 草/路/水（一期）。3/4 是客户端 TerrainAtlas 内部的崖唇/崖壁 B 通道码，
 * 从不作为「存储的 tile 类型」出现——故新增可行走地表从 5 起编号，
 * 与客户端 shader 的 body-type（ty=round(B*8)）5/6/7 空档一一对应（见 world-themes-expansion-design.md §1.3）。
 */
export const T_GRASS = 0;
export const T_PATH = 1;
export const T_WATER = 2;
export const T_SAND = 5;   // 沙地（海底/沙滩；复用 dirt 细节贴图，暖 tint）
export const T_SNOW = 6;   // 雪地（冰雪世界；复用 stone 细节贴图，冷白 tint）
export const T_TILE = 7;   // 瓷砖地板（室内厨房/医院/玩具房间；stone 细节，中性灰 tint）

/** 合法的存储 tile 类型集合（校验用；3/4 是客户端崖壁 B 码，不入此集）。 */
export const VALID_TILE_TYPES: ReadonlySet<number> = new Set([T_GRASS, T_PATH, T_WATER, T_SAND, T_SNOW, T_TILE]);
/** 可行走地表（非水）——新地形一律按草地行走规则；仅水阻挡。 */
export function isWalkableTileType(t: number): boolean {
  return VALID_TILE_TYPES.has(t) && t !== T_WATER;
}

/** 边缘平面顺序（itemRef 后的 4 张），与客户端 TerrainMap.EDGE_* 一一对应。 */
export const EDGE_N = 0;
export const EDGE_E = 1;
export const EDGE_S = 2;
export const EDGE_W = 3;

export interface Terrain {
  gridW: number;
  gridH: number;
  tileSize: number;
  types: Uint8Array;
  heights: Uint8Array;
  depths: Uint8Array;
  /** 物品引用平面：0=无 / 1..N=palette 索引（多 tile 物品只写锚点 tile）。u16 容纳 v3 高索引。 */
  itemRef: Uint16Array;
  /** 物品参数平面：朝向全字节 256 档（argYawDeg/yawToArg）。恒 u8。 */
  itemArg: Uint8Array;
  /** 边缘挂载平面 N/E/S/W（一期恒 0，数据位）。u16 与 itemRef 同宽（共享 palette）。 */
  edges: [Uint16Array, Uint16Array, Uint16Array, Uint16Array];
  /** palette：索引-1 → 物品实体 id（items.ts / items 表）。 */
  palette: string[];
}

export class TerrainFormatError extends Error {
  constructor(reason: string) {
    super(`bad terrain payload: ${reason}`);
    this.name = 'TerrainFormatError';
  }
}

/** 空地形（全草地、无物品）：测试与迁移的起点。 */
export function emptyTerrain(): Terrain {
  const n = REQUIRED_GRID * REQUIRED_GRID;
  return {
    gridW: REQUIRED_GRID, gridH: REQUIRED_GRID, tileSize: DEFAULT_TILE_SIZE,
    types: new Uint8Array(n), heights: new Uint8Array(n), depths: new Uint8Array(n),
    itemRef: new Uint16Array(n), itemArg: new Uint8Array(n),
    edges: [new Uint16Array(n), new Uint16Array(n), new Uint16Array(n), new Uint16Array(n)],
    palette: [],
  };
}

/** itemArg 朝向：全字节 256 档（≈1.4°/档），保住地标/SDF 物件的手调角度。 */
export function argYawDeg(arg: number): number {
  return (arg & 0xff) * (360 / 256);
}

/** 朝向角 → itemArg 字节（就近取档，任意角度归一到 [0,360)）。 */
export function yawToArg(deg: number): number {
  const norm = ((deg % 360) + 360) % 360;
  return Math.round(norm / (360 / 256)) % 256;
}

function planes(t: Terrain): (Uint8Array | Uint16Array)[] {
  return [t.types, t.heights, t.depths, t.itemRef, t.itemArg, ...t.edges];
}

const PLANE_NAMES = ['types', 'heights', 'depths', 'itemRef', 'itemArg', 'edgeN', 'edgeE', 'edgeS', 'edgeW'];

/** 九个平面必须等长且等于 gridW*gridH，否则解码出来的地图会整体错位。 */
function assertPlanes(t: Terrain): void {
  const n = t.gridW * t.gridH;
  planes(t).forEach((p, i) => {
    if (p.length !== n) throw new TerrainFormatError(`${PLANE_NAMES[i]} length ${p.length} != ${n}`);
  });
}

const utf8Enc = new TextEncoder();
const utf8Dec = new TextDecoder('utf-8', { fatal: true });

/**
 * 编码自适应版本：palette ≤255 写 v2（字节与旧版逐字节一致，存量场景零膨胀），
 * >255 写 v3（itemRef+4 边缘平面 + palette count 升 u16 小端）。v1 只在解码侧兼容。
 */
export function encodeTerrain(t: Terrain): Uint8Array {
  assertPlanes(t);
  if (t.gridW > 255 || t.gridH > 255 || t.gridW < 1 || t.gridH < 1) {
    throw new TerrainFormatError(`grid ${t.gridW}x${t.gridH} out of u8 range`);
  }
  if (t.palette.length > MAX_PALETTE) throw new TerrainFormatError(`palette ${t.palette.length} > ${MAX_PALETTE}`);
  const ids = t.palette.map((id) => {
    const b = utf8Enc.encode(id);
    if (b.length < 1 || b.length > 255) throw new TerrainFormatError(`palette id ${JSON.stringify(id)} length ${b.length}`);
    return b;
  });

  const wide = t.palette.length > 255;         // v3 门槛：超出 u8 索引域
  const n = t.gridW * t.gridH;
  // v2：9 平面各 1B + palette(count u8 + 项)；v3：itemRef+4 边缘各 2B、其余 1B + palette(count u16 + 项)
  const planeBytes = wide ? (4 * n + 5 * 2 * n) : PLANES_V2 * n;
  const countBytes = wide ? 2 : 1;
  const paletteBytes = countBytes + ids.reduce((s, b) => s + 1 + b.length, 0);
  const out = new Uint8Array(HEADER_BYTES + planeBytes + paletteBytes);
  const view = new DataView(out.buffer);

  for (let i = 0; i < 4; i++) out[i] = TERRAIN_MAGIC.charCodeAt(i);
  out[4] = wide ? TERRAIN_VERSION_3 : TERRAIN_VERSION;
  out[5] = t.gridW;
  out[6] = t.gridH;
  view.setFloat32(7, t.tileSize, true);

  let off = HEADER_BYTES;
  const putU8 = (p: Uint8Array | Uint16Array) => { out.set(p, off); off += n; };
  const putU16 = (p: Uint16Array) => {
    for (let i = 0; i < n; i++) { view.setUint16(off, p[i]!, true); off += 2; }
  };
  // 顺序恒 types,heights,depths,itemRef,itemArg,edgeN,E,S,W——v2 全 u8，v3 仅 itemRef 与 4 边缘 u16
  putU8(t.types); putU8(t.heights); putU8(t.depths);
  wide ? putU16(t.itemRef) : putU8(t.itemRef);
  putU8(t.itemArg);
  for (const e of t.edges) wide ? putU16(e) : putU8(e);

  if (wide) { view.setUint16(off, ids.length, true); off += 2; }
  else { out[off++] = ids.length; }
  for (const b of ids) {
    out[off++] = b.length;
    out.set(b, off);
    off += b.length;
  }
  return out;
}

/**
 * 解码并校验。任何一处不对就抛 TerrainFormatError——地形错位是那种「跑起来才发现、
 * 而且看起来像渲染 bug」的故障，宁可入库时就拒收。
 * 兼容 v1（旧导出工具/存量库）：item/edge 平面补零、palette 为空。
 * 这里只做格式级校验；「引用的物品实体是否存在/占地是否冲突」是语义校验，
 * 需要实体表在手，见 items.ts 的 validateTerrainItems。
 */
export function decodeTerrain(buf: Uint8Array): Terrain {
  if (buf.length < HEADER_BYTES) throw new TerrainFormatError(`too short: ${buf.length} B`);

  const magic = String.fromCharCode(buf[0]!, buf[1]!, buf[2]!, buf[3]!);
  if (magic !== TERRAIN_MAGIC) throw new TerrainFormatError(`magic ${JSON.stringify(magic)}`);

  const version = buf[4]!;
  if (version !== TERRAIN_VERSION_1 && version !== TERRAIN_VERSION && version !== TERRAIN_VERSION_3) {
    throw new TerrainFormatError(`version ${version}, expect ${TERRAIN_VERSION_1}|${TERRAIN_VERSION}|${TERRAIN_VERSION_3}`);
  }

  const gridW = buf[5]!;
  const gridH = buf[6]!;
  if (gridW !== REQUIRED_GRID || gridH !== REQUIRED_GRID) {
    throw new TerrainFormatError(`grid ${gridW}x${gridH}, 第一版只接受 ${REQUIRED_GRID}x${REQUIRED_GRID}`);
  }

  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const tileSize = view.getFloat32(7, true);
  if (!Number.isFinite(tileSize) || tileSize <= 0) throw new TerrainFormatError(`tileSize ${tileSize}`);

  const n = gridW * gridH;
  const t = emptyTerrain();
  t.tileSize = tileSize;

  if (version === TERRAIN_VERSION_1) {
    const want = HEADER_BYTES + 3 * n;
    if (buf.length !== want) throw new TerrainFormatError(`length ${buf.length}, expect ${want}`);
    t.types = buf.slice(HEADER_BYTES, HEADER_BYTES + n);
    t.heights = buf.slice(HEADER_BYTES + n, HEADER_BYTES + 2 * n);
    t.depths = buf.slice(HEADER_BYTES + 2 * n, want);
  } else {
    const wide = version === TERRAIN_VERSION_3;   // v3：itemRef+4 边缘 + count 升 u16 小端
    const refWidth = wide ? 2 : 1;
    const countWidth = wide ? 2 : 1;
    // 平面字节：types/heights/depths/itemArg 各 1B，itemRef+4 边缘各 refWidth
    const planeBytes = 4 * n + 5 * refWidth * n;
    const planesEnd = HEADER_BYTES + planeBytes;
    if (buf.length < planesEnd + countWidth) throw new TerrainFormatError(`length ${buf.length}, expect >= ${planesEnd + countWidth}`); // palette 至少 count 字段
    const readU16Plane = (from: number): Uint16Array => {
      const p = new Uint16Array(n);
      for (let i = 0; i < n; i++) p[i] = view.getUint16(from + 2 * i, true);
      return p;
    };
    let off = HEADER_BYTES;
    t.types = buf.slice(off, off + n); off += n;
    t.heights = buf.slice(off, off + n); off += n;
    t.depths = buf.slice(off, off + n); off += n;
    if (wide) { t.itemRef = readU16Plane(off); off += 2 * n; }
    else { t.itemRef = Uint16Array.from(buf.slice(off, off + n)); off += n; }
    t.itemArg = buf.slice(off, off + n); off += n;
    for (let e = 0; e < 4; e++) {
      if (wide) { t.edges[e] = readU16Plane(off); off += 2 * n; }
      else { t.edges[e] = Uint16Array.from(buf.slice(off, off + n)); off += n; }
    }

    const count = wide ? view.getUint16(off, true) : buf[off]!; off += countWidth;
    const seen = new Set<string>();
    for (let i = 0; i < count; i++) {
      if (off >= buf.length) throw new TerrainFormatError(`palette truncated at entry ${i}`);
      const len = buf[off]!; off += 1;
      if (len < 1) throw new TerrainFormatError(`palette entry ${i} empty`);
      if (off + len > buf.length) throw new TerrainFormatError(`palette truncated at entry ${i}`);
      let id: string;
      try {
        id = utf8Dec.decode(buf.slice(off, off + len));
      } catch {
        throw new TerrainFormatError(`palette entry ${i} bad utf-8`);
      }
      if (seen.has(id)) throw new TerrainFormatError(`palette duplicate ${JSON.stringify(id)}`);
      seen.add(id);
      t.palette.push(id);
      off += len;
    }
    if (off !== buf.length) throw new TerrainFormatError(`length ${buf.length}, expect ${off}（palette 后有多余尾巴）`);

    // 引用平面的索引必须落在 palette 内
    const refPlanes: Array<[string, Uint16Array]> = [
      ['itemRef', t.itemRef], ['edgeN', t.edges[0]], ['edgeE', t.edges[1]], ['edgeS', t.edges[2]], ['edgeW', t.edges[3]],
    ];
    for (const [name, plane] of refPlanes) {
      for (let i = 0; i < n; i++) {
        if (plane[i]! > count) throw new TerrainFormatError(`${name}[${i}] = ${plane[i]}, palette 只有 ${count} 项`);
      }
    }
  }

  for (const v of t.types) {
    if (!VALID_TILE_TYPES.has(v)) throw new TerrainFormatError(`tile type ${v}`);
  }
  // 非水格不该有水深——真出现说明导出端画错了，别把错误数据喂给渲染
  for (let i = 0; i < n; i++) {
    if (t.types[i] !== T_WATER && t.depths[i] !== 0) throw new TerrainFormatError(`depth ${t.depths[i]} on non-water tile ${i}`);
  }

  return t;
}
