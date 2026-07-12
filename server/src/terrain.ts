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
 * 75×75 v1 → 11 + 3×5625 = 16886 B（gzip 后实测 495 B）；
 * v2 → 11 + 9×5625 + palette ≈ 50.7 KB（item 平面低熵，gzip 预计 <3 KB）。
 */

export const TERRAIN_MAGIC = 'MLTR';
export const TERRAIN_VERSION_1 = 1;
export const TERRAIN_VERSION = 2;
export const HEADER_BYTES = 11;
/** v2 的平面数（v1 是前 3 张）。 */
export const PLANES_V2 = 9;
/** palette 容量上限：itemRef 是 u8，0 留给「无物品」。 */
export const MAX_PALETTE = 255;

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
export const T_SAND = 5;   // 沙地（海底：细沙 / 沙滩）
export const T_SNOW = 6;   // 雪地（冰雪世界）
export const T_TILE = 7;   // 瓷砖地板（室内厨房/医院/玩具房间）
// 海底主题地表（themed-terrain P2），与客户端 TerrainMap.T_* 及层贴图一一对应。
export const T_COARSE_SAND = 8;  // 粗沙
export const T_CORAL_SAND = 9;   // 珊瑚砂
export const T_REEF = 10;        // 礁岩（可抬高）
export const T_SEAGRASS = 11;    // 海草地
export const T_DEEP_BED = 12;    // 深水床（暗）
// 冰雪世界主题地表（themed-terrain P3），与客户端 TerrainMap.T_* 及层贴图一一对应。
export const T_PACKED_SNOW = 13; // 压实雪
export const T_ICE = 14;         // 冰面（结冰水共用）
export const T_SLUSH = 15;       // 雪泥/融雪
export const T_ROCK_SNOW = 16;   // 裸岩积雪（可抬高）
// 侏罗纪主题地表（themed-terrain P3），与客户端 TerrainMap.T_* 及层贴图一一对应。
export const T_CRACKED_EARTH = 17; // 干裂土（中国夯土/罗马斗兽场沙土共用）
export const T_VOLCANIC = 18;      // 火山岩（可抬高）
export const T_MUD_BOG = 19;       // 泥沼
export const T_FERN = 20;          // 蕨类草地
export const T_RUBBLE = 21;        // 碎石（罗马碎石共用）
// 中世纪主题地表（themed-terrain P3），与客户端 TerrainMap.T_* 及层贴图一一对应。
export const T_COBBLE = 22;        // 鹅卵石（中国卵石庭共用）
export const T_STONE_SLAB = 23;    // 石板（中国青石板/罗马石板共用，可抬高）
export const T_FARM_FURROW = 24;   // 农田垄
// 罗马主题地表（themed-terrain P3）：罗马石板复用 T_STONE_SLAB、碎石复用 T_RUBBLE、斗兽场沙土复用 T_CRACKED_EARTH。
export const T_MARBLE = 25;        // 大理石（可抬高）
export const T_MOSAIC = 26;        // 马赛克地
// 中国古代主题地表（themed-terrain P3）：青石板复用 T_STONE_SLAB、夯土复用 T_CRACKED_EARTH、卵石庭复用 T_COBBLE。
export const T_WOOD_FLOOR = 27;    // 木地板（廊；玩具/厨房共用，可抬高）
// 现代城市主题地表（themed-terrain P3），与客户端 TerrainMap.T_* 及层贴图一一对应。
export const T_ASPHALT = 28;       // 沥青
export const T_PAVER_BRICK = 29;   // 人行道砖（可抬高）
export const T_CROSSWALK = 30;     // 斑马线
export const T_CONCRETE = 31;      // 水泥（未来混凝土/医院手术室共用，可抬高）
export const T_LAWN_GRID = 32;     // 草坪格
// 玩具房间主题地表（themed-terrain P3）：木地板/瓷砖复用现有类型。
export const T_CARPET_RED = 33;    // 地毯红
export const T_CARPET_BLUE = 34;   // 地毯蓝
export const T_PUZZLE_MAT = 35;    // 拼图垫
// 厨房主题地表（themed-terrain P3）：白瓷砖/木地板复用现有类型。
export const T_CHECKER_TILE = 36;  // 格纹地砖
export const T_ANTISLIP = 37;      // 防滑垫（医院防滑走廊共用）
// 医院主题地表（themed-terrain P3）：白瓷砖复用 T_TILE、手术室地复用 T_CONCRETE、防滑走廊复用 T_ANTISLIP。
export const T_MED_VINYL_GREEN = 38; // 医用地胶浅绿
export const T_MED_VINYL_BLUE = 39;  // 医用地胶浅蓝
// 未来机器人主题地表（themed-terrain P3）：混凝土复用 T_CONCRETE。
export const T_METAL_PLATE = 40;   // 金属板（可抬高）
export const T_GRATING = 41;       // 格栅
export const T_GLOW_TILE = 42;     // 发光地砖
export const T_HAZARD = 43;        // 警戒条纹地
export const T_TOY_WALL = 44;      // 玩具房间墙面（室内房间围墙）

/** 合法的存储 tile 类型集合（校验用；3/4 是客户端崖壁 B 码，不入此集）。 */
export const VALID_TILE_TYPES: ReadonlySet<number> = new Set([
  T_GRASS, T_PATH, T_WATER, T_SAND, T_SNOW, T_TILE,
  T_COARSE_SAND, T_CORAL_SAND, T_REEF, T_SEAGRASS, T_DEEP_BED,
  T_PACKED_SNOW, T_ICE, T_SLUSH, T_ROCK_SNOW,
  T_CRACKED_EARTH, T_VOLCANIC, T_MUD_BOG, T_FERN, T_RUBBLE,
  T_COBBLE, T_STONE_SLAB, T_FARM_FURROW, T_MARBLE, T_MOSAIC, T_WOOD_FLOOR,
  T_ASPHALT, T_PAVER_BRICK, T_CROSSWALK, T_CONCRETE, T_LAWN_GRID,
  T_CARPET_RED, T_CARPET_BLUE, T_PUZZLE_MAT,
  T_CHECKER_TILE, T_ANTISLIP, T_MED_VINYL_GREEN, T_MED_VINYL_BLUE,
  T_METAL_PLATE, T_GRATING, T_GLOW_TILE, T_HAZARD, T_TOY_WALL,
]);
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
  /** 物品引用平面：0=无 / 1..N=palette 索引（多 tile 物品只写锚点 tile）。 */
  itemRef: Uint8Array;
  /** 物品参数平面：朝向全字节 256 档（argYawDeg/yawToArg）。 */
  itemArg: Uint8Array;
  /** 边缘挂载平面 N/E/S/W（一期恒 0，数据位）。 */
  edges: [Uint8Array, Uint8Array, Uint8Array, Uint8Array];
  /** palette：u8 索引-1 → 物品实体 id（items.ts / items 表）。 */
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
    itemRef: new Uint8Array(n), itemArg: new Uint8Array(n),
    edges: [new Uint8Array(n), new Uint8Array(n), new Uint8Array(n), new Uint8Array(n)],
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

function planes(t: Terrain): Uint8Array[] {
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

/** 编码恒为 v2（v1 只在解码侧兼容旧库存量/旧导出工具）。 */
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

  const n = t.gridW * t.gridH;
  const paletteBytes = 1 + ids.reduce((s, b) => s + 1 + b.length, 0);
  const out = new Uint8Array(HEADER_BYTES + PLANES_V2 * n + paletteBytes);
  const view = new DataView(out.buffer);

  for (let i = 0; i < 4; i++) out[i] = TERRAIN_MAGIC.charCodeAt(i);
  out[4] = TERRAIN_VERSION;
  out[5] = t.gridW;
  out[6] = t.gridH;
  view.setFloat32(7, t.tileSize, true);

  let off = HEADER_BYTES;
  for (const p of planes(t)) {
    out.set(p, off);
    off += n;
  }
  out[off++] = ids.length;
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
  if (version !== TERRAIN_VERSION_1 && version !== TERRAIN_VERSION) {
    throw new TerrainFormatError(`version ${version}, expect ${TERRAIN_VERSION_1}|${TERRAIN_VERSION}`);
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
    const planesEnd = HEADER_BYTES + PLANES_V2 * n;
    if (buf.length < planesEnd + 1) throw new TerrainFormatError(`length ${buf.length}, expect >= ${planesEnd + 1}`); // palette 至少 count 一个字节
    let off = HEADER_BYTES;
    t.types = buf.slice(off, off + n); off += n;
    t.heights = buf.slice(off, off + n); off += n;
    t.depths = buf.slice(off, off + n); off += n;
    t.itemRef = buf.slice(off, off + n); off += n;
    t.itemArg = buf.slice(off, off + n); off += n;
    for (let e = 0; e < 4; e++) { t.edges[e] = buf.slice(off, off + n); off += n; }

    const count = buf[off]!; off += 1;
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
    const refPlanes: Array<[string, Uint8Array]> = [
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
