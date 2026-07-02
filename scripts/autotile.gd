class_name Autotile
extends RefCounted
## Blob autotile 的纯函数核心：8 邻居掩码 → 每 tile 四个角的变体索引。
## 思路（corner/dual-grid 式）：一个 tile 拆成 4 个角 quad，每个角只看
## 「相邻两条边的邻居 + 对角邻居」共 3 位，得 5 种变体——比整块 47 变体 blob
## 简单得多，且视觉等价。渲染层按 (类型, 角, 变体) 去 atlas 取 UV。
## 本类不依赖 TerrainMap：掩码由调用方给的谓词生成（P6 悬崖复用同一套逻辑）。

## 8 邻居位（自北起顺时针）。
const N := 1
const NE := 2
const E := 4
const SE := 8
const S := 16
const SW := 32
const W := 64
const NW := 128

## 角索引（与渲染层 quad 顺序约定一致）。
const C_NW := 0
const C_NE := 1
const C_SW := 2
const C_SE := 3

## 角变体：FULL 内部 / INNER 凹角 / EDGE_H 水平边线 / EDGE_V 垂直边线 / OUTER 凸圆角。
const V_FULL := 0
const V_INNER := 1
const V_EDGE_H := 2
const V_EDGE_V := 3
const V_OUTER := 4
const VARIANT_COUNT := 5

## 单角变体：h=水平方向邻居(E/W)同类, v=垂直方向邻居(N/S)同类, d=对角同类。
static func corner_variant(h: bool, v: bool, d: bool) -> int:
	if h and v:
		return V_FULL if d else V_INNER
	if h:
		return V_EDGE_H  # 只横向相连 → 边界线沿水平方向
	if v:
		return V_EDGE_V  # 只纵向相连 → 边界线沿垂直方向
	return V_OUTER

## 8 位掩码 → [NW, NE, SW, SE] 四个角的变体。
static func corners_from_mask(mask: int) -> PackedInt32Array:
	return PackedInt32Array([
		corner_variant(mask & W != 0, mask & N != 0, mask & NW != 0),
		corner_variant(mask & E != 0, mask & N != 0, mask & NE != 0),
		corner_variant(mask & W != 0, mask & S != 0, mask & SW != 0),
		corner_variant(mask & E != 0, mask & S != 0, mask & SE != 0),
	])

## 用谓词 same(tile: Vector2i) -> bool 生成 8 邻居掩码（调用方负责环面 wrap）。
static func mask_of(t: Vector2i, same: Callable) -> int:
	var m := 0
	if same.call(t + Vector2i(0, -1)): m |= N
	if same.call(t + Vector2i(1, -1)): m |= NE
	if same.call(t + Vector2i(1, 0)): m |= E
	if same.call(t + Vector2i(1, 1)): m |= SE
	if same.call(t + Vector2i(0, 1)): m |= S
	if same.call(t + Vector2i(-1, 1)): m |= SW
	if same.call(t + Vector2i(-1, 0)): m |= W
	if same.call(t + Vector2i(-1, -1)): m |= NW
	return m
