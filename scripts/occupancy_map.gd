class_name OccupancyMap
extends RefCounted
## 占用/碰撞数据层：0.5 tile（1m）分辨率的环面占用位图（150×150 半格）。
## 双层设计：地形（类型/高度，1 tile 分辨率）在 TerrainMap，静态；
## 动态占用（角色/物件脚印）在本图，摆放/移动时登记与释放。
## 尺寸离散化约定：角色边长 1..4 tile @0.5 步进（半格 2..8）；
## 物件边长 1..16 tile @1 步进（半格 2..32）。

const CELLS := WorldGrid.GRID_TILES * 2       ## 150
const CELL_SIZE := WorldGrid.TILE_SIZE * 0.5  ## 1m

static var _occ := PackedByteArray()

static func _ensure() -> void:
	if _occ.is_empty():
		_occ.resize(CELLS * CELLS)

## 清空全图（世界重建/测试用）。
static func clear() -> void:
	_occ = PackedByteArray()

static func _idx(c: Vector2i) -> int:
	return posmod(c.y, CELLS) * CELLS + posmod(c.x, CELLS)

## 逻辑世界坐标（米）→ 半格索引。
static func to_cell(p: Vector2) -> Vector2i:
	var w := WorldGrid.wrap_pos(p)
	return Vector2i(int(w.x / CELL_SIZE), int(w.y / CELL_SIZE))

## tile 索引 → 该 tile 的 NW 半格索引。
static func tile_to_cell(t: Vector2i) -> Vector2i:
	return Vector2i(posmod(t.x, WorldGrid.GRID_TILES) * 2, posmod(t.y, WorldGrid.GRID_TILES) * 2)

## 角色边长（tile，0.5 步进）→ 半格数（离散化 + 上下限 1..4 tile）。
static func char_span(tiles: float) -> int:
	return clampi(roundi(tiles * 2.0), 2, 8)

## 物件边长（tile，1 步进）→ 半格数（上下限 1..16 tile）。
static func prop_span(tiles: int) -> int:
	return clampi(tiles, 1, 16) * 2

## origin 起 w×h 半格矩形全空闲（环面 wrap）。
static func is_free_rect(origin: Vector2i, w: int, h: int) -> bool:
	_ensure()
	for dz in range(h):
		for dx in range(w):
			if _occ[_idx(origin + Vector2i(dx, dz))] != 0:
				return false
	return true

static func occupy_rect(origin: Vector2i, w: int, h: int) -> void:
	_ensure()
	for dz in range(h):
		for dx in range(w):
			_occ[_idx(origin + Vector2i(dx, dz))] = 1

static func free_rect(origin: Vector2i, w: int, h: int) -> void:
	_ensure()
	for dz in range(h):
		for dx in range(w):
			_occ[_idx(origin + Vector2i(dx, dz))] = 0

## 物件可放置判定（摆放器/未来编辑器共用）：
## w×h tile 内 无水、（除非 allow_path）无路、高度与原点一致（不跨崖悬空）、无已有占用。
static func prop_area_ok(tile_origin: Vector2i, w_tiles: int, h_tiles: int, allow_path := false) -> bool:
	var h0 := TerrainMap.tile_height(tile_origin)
	for dz in range(h_tiles):
		for dx in range(w_tiles):
			var t := tile_origin + Vector2i(dx, dz)
			var ty := TerrainMap.tile_type(t)
			if ty == TerrainMap.T_WATER or (ty == TerrainMap.T_PATH and not allow_path):
				return false
			if TerrainMap.tile_height(t) != h0:
				return false
	return is_free_rect(tile_to_cell(tile_origin), w_tiles * 2, h_tiles * 2)
