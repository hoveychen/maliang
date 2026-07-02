class_name TerrainMap
extends RefCounted
## 世界地形数据模型——纯静态，首次访问时确定性生成，无随机状态。
## 每 tile 两个字节：类型（草/路/水）+ 高度（0..2 级台阶）。
## 逻辑网格沿用 WorldGrid（75×75 tile，环面 wrap）；本类只是数据，渲染在 chunk_manager。
##
## 默认地形布局（手绘式确定性生成，坐标单位 = tile 索引 0..74）：
## - 村庄路网：三条纵向双宽路（x=12/37/61 列）+ 一条横向双宽路（z=37 行）+ 中央广场
## - 池塘：村庄西南 (24.5, 24.5) 椭圆水面（岸边全部平地）
## - 北部演示山：(37.5, 6.5) 八级同心台地（织梦岛式；东西向缓坡可逐级爬，南北向陡崖多级跳变）

const T_GRASS := 0
const T_PATH := 1
const T_WATER := 2
const MAX_HEIGHT := 255   ## 数据上限（存储为 byte）；默认地形演示山只到 8 级
const STEP_HEIGHT := 2.0  ## 每级台阶的世界高度（米）= 1 格（tile 边长）；相邻 tile 跳变可超 1 级（陡崖）

static var _types := PackedByteArray()
static var _heights := PackedByteArray()

## 世界坐标（XZ，米）→ tile 类型；直接用 tile 索引请走 tile_type。
static func type_at(p: Vector2) -> int:
	return tile_type(WorldGrid.to_tile(p))

static func tile_type(t: Vector2i) -> int:
	_ensure_built()
	return _types[_idx(t)]

static func tile_height(t: Vector2i) -> int:
	_ensure_built()
	return _heights[_idx(t)]

## 移动规则（纯函数，供 can_step 与测试）：目标是水不可进；
## 一次最多升 1 级；下落超过 4 级视为空气墙。
static func step_allowed(from_h: int, to_h: int, to_type: int) -> bool:
	if to_type == T_WATER:
		return false
	var rise := to_h - from_h
	return rise <= 1 and rise >= -4

## 移动规则的 tile 版：from_t → to_t 是否允许（角色一步跨 tile 时调用）。
static func can_step(from_t: Vector2i, to_t: Vector2i) -> bool:
	return step_allowed(tile_height(from_t), tile_height(to_t), tile_type(to_t))

## tile 中心的逻辑世界坐标（米），供摆放吸附用。
static func tile_center(t: Vector2i) -> Vector2:
	var x := posmod(t.x, WorldGrid.GRID_TILES)
	var z := posmod(t.y, WorldGrid.GRID_TILES)
	return Vector2((float(x) + 0.5) * WorldGrid.TILE_SIZE, (float(z) + 0.5) * WorldGrid.TILE_SIZE)

static func _idx(t: Vector2i) -> int:
	var x := posmod(t.x, WorldGrid.GRID_TILES)
	var z := posmod(t.y, WorldGrid.GRID_TILES)
	return z * WorldGrid.GRID_TILES + x

static func _ensure_built() -> void:
	if not _types.is_empty():
		return
	var n := WorldGrid.GRID_TILES
	_types.resize(n * n)   # 清零 = 全草地
	_heights.resize(n * n) # 清零 = 高度 0
	_paint()

static func _paint() -> void:
	# 北部演示山：8 级同心椭圆台地，逐级覆盖抬高（每级 x 缩 1.3、z 缩 0.75 tile）
	for lvl in range(1, 9):
		_paint_ellipse_height(37.5, 6.5, 12.0 - 1.3 * float(lvl), 6.8 - 0.75 * float(lvl), lvl)

	# 村庄路网：z 范围避开北部高地（z>=14）
	_paint_rect_type(12, 14, 13, 61, T_PATH)   # 西纵路
	_paint_rect_type(37, 14, 38, 61, T_PATH)   # 中纵路
	_paint_rect_type(61, 14, 62, 61, T_PATH)   # 东纵路
	_paint_rect_type(14, 37, 61, 38, T_PATH)   # 横路
	_paint_rect_type(34, 34, 41, 41, T_PATH)   # 中央广场（水井所在）

	# 池塘（村庄西南，避开路网与高地；水面必须整体高度 0）
	_paint_ellipse_type(24.5, 24.5, 5.5, 4.2, T_WATER)

## 矩形 tile 区域 [x0..x1]×[z0..z1] 涂类型（含端点）。
static func _paint_rect_type(x0: int, z0: int, x1: int, z1: int, t: int) -> void:
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			_types[_idx(Vector2i(x, z))] = t

## 椭圆内（tile 中心判定）涂类型。
static func _paint_ellipse_type(cx: float, cz: float, rx: float, rz: float, t: int) -> void:
	for z in range(int(cz - rz), int(cz + rz) + 1):
		for x in range(int(cx - rx), int(cx + rx) + 1):
			if _in_ellipse(x, z, cx, cz, rx, rz):
				_types[_idx(Vector2i(x, z))] = t

## 椭圆内（tile 中心判定）涂高度。
static func _paint_ellipse_height(cx: float, cz: float, rx: float, rz: float, h: int) -> void:
	for z in range(int(cz - rz), int(cz + rz) + 1):
		for x in range(int(cx - rx), int(cx + rx) + 1):
			if _in_ellipse(x, z, cx, cz, rx, rz):
				_heights[_idx(Vector2i(x, z))] = h

static func _in_ellipse(x: int, z: int, cx: float, cz: float, rx: float, rz: float) -> bool:
	var dx := (float(x) + 0.5 - cx) / rx
	var dz := (float(z) + 0.5 - cz) / rz
	return dx * dx + dz * dz <= 1.0
