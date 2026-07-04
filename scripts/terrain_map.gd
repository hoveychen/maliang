class_name TerrainMap
extends RefCounted
## 世界地形数据模型——纯静态，首次访问时确定性生成，无随机状态。
## 每 tile 两个字节：类型（草/路/水）+ 高度（0..2 级台阶）。
## 逻辑网格沿用 WorldGrid（75×75 tile，环面 wrap）；本类只是数据，渲染在 chunk_manager。
##
## 默认地形布局（手绘式确定性生成，坐标单位 = tile 索引 0..74）：
## - 北部主峰：(37.5, 6.5) 八级同心台地（西山脊缓坡可逐级爬到峰顶，南面陡崖）
## - 东北肩丘：(56.5, 8.5) 三级矮丘，与主峰之间留一条山口谷地
## - 东南瞭望丘：(59.5, 54.5) 三级缓坡（每环 +1 级可直接走上去），顶上是风车平台
## - 水系：主峰南麓涌泉 → 溪流汇入池塘 (24.5, 24.5) → 南出水口蜿蜒 → 西南沼泽小潭；
##   水面全部高度 0、岸边平地；西辐路压过出水口形成涉水石滩（先画水后画路）
## - 路网：中央广场 + 四条辐路（北→登山口接上山小径、西→池塘观景、东→拐向风车丘
##   再有支径爬上丘顶、南→集市小广场），另有一条草甸小径从集市穿过环面接缝回到
##   西北出生林间空地——环面世界「一直往南走会从山背后回来」的示范

const T_GRASS := 0
const T_PATH := 1
const T_WATER := 2
const MAX_HEIGHT := 255   ## 数据上限（存储为 byte）；默认地形主峰只到 8 级
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
	# ---- 高地 ----
	# 北部主峰：8 级同心椭圆台地（每级 x 缩 1.3、z 缩 0.75 tile；测试/POI/爬坡路线锚定，勿动）
	for lvl in range(1, 9):
		_paint_ellipse_height(37.5, 6.5, 12.0 - 1.3 * float(lvl), 6.8 - 0.75 * float(lvl), lvl)
	# 东北肩丘：主峰东侧 1..3 级矮丘，与主峰之间在 x≈49 留出山口谷地
	for lvl in range(1, 4):
		_paint_ellipse_height(56.5, 8.5, 6.0 - 1.6 * float(lvl - 1), 4.8 - 1.2 * float(lvl - 1), lvl)
	# 东南瞭望丘：3 级缓坡（同心每环 +1，任意方向都能走上去），顶面留 3×3 平台放风车
	for lvl in range(1, 4):
		_paint_ellipse_height(59.5, 54.5, 7.5 - 2.25 * float(lvl - 1), 6.0 - 1.8 * float(lvl - 1), lvl)

	# ---- 水系（全部处于高度 0 平地；折线顶点取 tile 中心保证顶点 tile 必为水）----
	# 涌泉溪：主峰南麓 (29,13) 涌出，向西南汇入池塘北岸
	_paint_polyline_type([Vector2(29.5, 13.5), Vector2(27.5, 17.5), Vector2(25.5, 20.5)], 0.7, T_WATER)
	# 池塘（原位保持——poi_pond 与岸线测试锚定于此）
	_paint_ellipse_type(24.5, 24.5, 5.5, 4.2, T_WATER)
	# 出水口：池塘南岸向南蜿蜒（其中 (21,37) 一带稍后被西辐路盖成涉水石滩）
	_paint_polyline_type([
		Vector2(23.5, 29.5), Vector2(22.5, 33.5), Vector2(21.5, 37.5),
		Vector2(19.5, 42.5), Vector2(16.5, 46.5), Vector2(14.5, 49.5)], 0.7, T_WATER)
	# 西南沼泽小潭：溪流归宿
	_paint_ellipse_type(13.5, 50.5, 3.0, 2.5, T_WATER)

	# ---- 路网（后画：与水交叉处路面自然盖过水 = 涉水石滩）----
	_paint_rect_type(34, 34, 41, 41, T_PATH)   # 中央广场（水井所在）
	_paint_rect_type(37, 14, 38, 33, T_PATH)   # 北辐路：广场 → 主峰登山口
	_paint_rect_type(37, 42, 38, 60, T_PATH)   # 南辐路：广场 → 集市小广场
	_paint_rect_type(14, 37, 33, 38, T_PATH)   # 西辐路：广场 → 西郊（压过出水口成石滩）
	_paint_rect_type(42, 37, 51, 38, T_PATH)   # 东辐路：广场 → 东郊
	_paint_rect_type(35, 61, 40, 63, T_PATH)   # 集市小广场（南辐路尽头）
	# 西辐路支径：拐向池塘南岸观景处
	_paint_polyline_type([Vector2(15.5, 37.5), Vector2(17.5, 33.5), Vector2(20.5, 30.5)], 1.0, T_PATH)
	# 东辐路支径：拐向东南，接瞭望丘西麓
	_paint_polyline_type([Vector2(51.5, 38.5), Vector2(54.5, 43.5), Vector2(53.5, 47.5)], 1.0, T_PATH)
	# 瞭望丘登顶小径：沿缓坡爬到 h2 环便收——顶面 3×3 平台留纯草放风车
	_paint_polyline_type([Vector2(53.5, 47.5), Vector2(56.5, 50.5), Vector2(57.5, 51.5)], 0.7, T_PATH)
	# 上山小径：登山口沿山脚绕到西山脊，再沿脊线（z=6 行，逐级 +1）登顶
	_paint_polyline_type([
		Vector2(37.5, 14.5), Vector2(32.5, 11.5), Vector2(28.5, 8.5),
		Vector2(26.5, 6.5), Vector2(33.5, 6.5), Vector2(37.5, 6.5)], 0.7, T_PATH)
	# 草甸小径：集市向西南穿过环面接缝（z 越过 74 wrap 回 0），回到西北出生林间空地
	_paint_polyline_type([
		Vector2(37.5, 63.5), Vector2(30.5, 67.5), Vector2(22.5, 70.5),
		Vector2(14.5, 73.5), Vector2(9.5, 77.5), Vector2(4.5, 80.5), Vector2(2.5, 82.5)], 0.7, T_PATH)

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

## 沿折线涂类型：tile 中心到任一线段距离 ≤ radius（tile 单位）者涂 t。
## 顶点坐标可越出 [0,75)，_idx 会环面 wrap——用于画穿过接缝的小径。
static func _paint_polyline_type(pts: Array, radius: float, t: int) -> void:
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		for z in range(int(minf(a.y, b.y) - radius) - 1, int(maxf(a.y, b.y) + radius) + 2):
			for x in range(int(minf(a.x, b.x) - radius) - 1, int(maxf(a.x, b.x) + radius) + 2):
				var c := Vector2(float(x) + 0.5, float(z) + 0.5)
				var q := Geometry2D.get_closest_point_to_segment(c, a, b)
				if c.distance_to(q) <= radius:
					_types[_idx(Vector2i(x, z))] = t

static func _in_ellipse(x: int, z: int, cx: float, cz: float, rx: float, rz: float) -> bool:
	var dx := (float(x) + 0.5 - cx) / rx
	var dz := (float(z) + 0.5 - cz) / rz
	return dx * dx + dz * dz <= 1.0
