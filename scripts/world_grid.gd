class_name WorldGrid
extends RefCounted
## Toroidal（环面）世界坐标数学——纯静态工具，无状态。
## 世界是 GRID_TILES × GRID_TILES 个 tile 的有限网格，首尾循环。
## 逻辑坐标用世界单位表示（不是 tile 索引），范围 [0, WORLD_SPAN)。

const GRID_TILES := 75
const TILE_SIZE := 2.0
const WORLD_SPAN := float(GRID_TILES) * TILE_SIZE  ## = 150.0（god 一屏≈60 单位 → 左右拖约 2.5 屏绕回原点）

## 把单个坐标分量 wrap 回 [0, WORLD_SPAN)。
static func wrap_scalar(v: float) -> float:
	return fposmod(v, WORLD_SPAN)

## 把世界坐标（XZ 平面，用 Vector2(x, z)）wrap 回 [0, WORLD_SPAN)²。
static func wrap_pos(p: Vector2) -> Vector2:
	return Vector2(fposmod(p.x, WORLD_SPAN), fposmod(p.y, WORLD_SPAN))

## 从 a 到 b 的最短环面位移；每个分量落在 [-WORLD_SPAN/2, WORLD_SPAN/2)。
## 用于「以玩家为中心」渲染：把任意逻辑点放到离渲染原点最近的那个等价位置。
static func shortest_delta(a: Vector2, b: Vector2) -> Vector2:
	var half := WORLD_SPAN * 0.5
	var dx := fposmod(b.x - a.x + half, WORLD_SPAN) - half
	var dy := fposmod(b.y - a.y + half, WORLD_SPAN) - half
	return Vector2(dx, dy)

## 世界坐标 → tile 索引（0..GRID_TILES-1），用于 UI 显示 / 寻路。
static func to_tile(p: Vector2) -> Vector2i:
	var w := wrap_pos(p)
	return Vector2i(int(w.x / TILE_SIZE), int(w.y / TILE_SIZE))

## tile 索引 → 该格中心的世界坐标（to_tile 的逆，取中心而非左上角，避免落在格边界上）。
## 服务端只存 tile 精度，重载读回时用它还原坐标。
static func from_tile_center(t: Vector2i) -> Vector2:
	return wrap_pos(Vector2(float(t.x) + 0.5, float(t.y) + 0.5) * TILE_SIZE)

## tile 是否落在世界内（与服务端 types.isValidTile 同口径）。
static func is_valid_tile(t: Vector2i) -> bool:
	return t.x >= 0 and t.x < GRID_TILES and t.y >= 0 and t.y < GRID_TILES
