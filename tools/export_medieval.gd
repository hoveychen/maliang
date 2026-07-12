extends SceneTree
## 程序化生成中世纪小镇主题地图并导出 .mltr v2（+ POI/portal json），供 POST /admin/scenes 入库。
## themed-terrain P3 中世纪切片：草地底 + 5 种地表（泥土路/鹅卵石/石板/草地/农田垄）
## + 一处护城河水，并造「石板 mound（城台）」与「鹅卵石 dune（水井台）」两种不同类型抬高块——
## 复用 P1「崖壁按被抬高 tile 类型选侧壁层」（石板壁 vs 鹅卵石壁）。
##
## 用法：godot --headless --path . --script res://tools/export_medieval.gd -- --out medieval.mltr

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_GRASS := 0          # 草地（底）
const T_PATH := 1           # 泥土路
const T_COBBLE := 22        # 鹅卵石（可抬高）
const T_STONE_SLAB := 23    # 石板（可抬高）
const T_FARM_FURROW := 24   # 农田垄
const T_WATER := 2          # 护城河

func _init() -> void:
	var out_path := _arg("--out", "medieval.mltr")
	var buf := build_terrain_bytes()
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("无法写入 ", out_path, "：", error_string(FileAccess.get_open_error()))
		quit(1)
		return
	f.store_buffer(buf)
	f.close()
	var gz := buf.compress(FileAccess.COMPRESSION_GZIP)
	print("导出 %s：%d B（gzip %d B）grid=%d×%d" % [
		out_path, buf.size(), gz.size(), WorldGrid.GRID_TILES, WorldGrid.GRID_TILES])

	var poi_path := _arg("--poi-out", out_path.get_basename() + ".pois.json")
	var pf := FileAccess.open(poi_path, FileAccess.WRITE)
	if pf == null:
		printerr("无法写入 ", poi_path)
		quit(1)
		return
	pf.store_string(JSON.stringify(build_poi_json(), "  "))
	pf.close()
	print("导出 %s：%d 个 POI" % [poi_path, build_poi_json().size()])

	var portal_path := _arg("--portal-out", out_path.get_basename() + ".portals.json")
	var qf := FileAccess.open(portal_path, FileAccess.WRITE)
	if qf == null:
		printerr("无法写入 ", portal_path)
		quit(1)
		return
	qf.store_string(JSON.stringify(build_portal_json(), "  "))
	qf.close()
	print("导出 %s：%d 个传送点" % [portal_path, build_portal_json().size()])
	quit(0)

## 中世纪 POI：给意图 LLM 的地名（城堡 / 集市 / 农田）。
static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_castle", "name": "城堡", "aliases": ["城堡", "城", "石台"] },
		{ "tile": [28, 50], "radius": 5.0, "trigger": "poi_well", "name": "水井", "aliases": ["水井", "井", "广场"] },
		{ "tile": [18, 18], "radius": 7.0, "trigger": "poi_farmland", "name": "农田", "aliases": ["农田", "田", "麦田"] },
	]

## 传送点（scene-portal-graph）：村庄/罗马/中国 各一对双向 portal。落点选边缘干地，
## 避开护城河(60,28) 与 mound(50,28)/(28,50)。与对向场景 build_portal_json() 互指。
static func build_portal_json() -> Array:
	return [
		{ "tile": [12, 12], "radius": 3.0, "toScene": "village", "toTile": [37, 12] },
		{ "tile": [37, 12], "radius": 3.0, "toScene": "roman", "toTile": [12, 12] },
		{ "tile": [12, 65], "radius": 3.0, "toScene": "ancient_china", "toTile": [12, 12] },
	]

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_medieval.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)

	# ── 底：全图草地（模态地表 → base_layer = 草）──
	for i in range(count):
		types[i] = T_GRASS

	# ── 地表分区（顶面语义）──
	_ellipse_type(types, n, 18.5, 18.5, 12.0, 10.0, T_FARM_FURROW)  # 西北 农田
	_ellipse_type(types, n, 55.5, 55.5, 10.0, 9.0, T_FARM_FURROW)   # 东南 农田
	# 泥土路网：十字主路 + 环路
	_rect_type(types, n, 36, 8, 39, 66, T_PATH)
	_rect_type(types, n, 8, 36, 66, 39, T_PATH)
	# 鹅卵石广场（水井周边）
	_ellipse_type(types, n, 28.5, 50.5, 6.0, 5.5, T_COBBLE)
	# 石板路引向城堡
	_rect_type(types, n, 44, 26, 56, 31, T_STONE_SLAB)

	# ── 石板 mound（城台）：footprint 涂石板，再同心抬高（逐级露石板崖壁）──
	_ellipse_type(types, n, 50.5, 28.5, 6.5, 6.0, T_STONE_SLAB)
	_ellipse_h(heights, n, 50.5, 28.5, 6.5, 6.0, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 4.2, 3.8, 2)
	_ellipse_h(heights, n, 50.5, 28.5, 2.2, 2.0, 3)

	# ── 鹅卵石 dune（水井台）：footprint 涂鹅卵石，再抬高——侧壁应为「鹅卵石壁」（验证 type-aware）──
	_ellipse_type(types, n, 28.5, 50.5, 3.5, 3.2, T_COBBLE)
	_ellipse_h(heights, n, 28.5, 50.5, 3.5, 3.2, 1)
	_ellipse_h(heights, n, 28.5, 50.5, 1.8, 1.6, 2)

	# ── 护城河水：城台一侧一弯水（浅水外圈 + 深水中心）──
	_ellipse_type(types, n, 60.5, 28.5, 4.5, 4.0, T_WATER)
	for i in range(count):
		if types[i] == T_WATER:
			depths[i] = 1
			heights[i] = 0
	_ellipse_depth(depths, types, n, 60.5, 28.5, 2.5, 2.2, 2)

	# ── 组装物品层（中世纪切片无散布物品）+ 灌回 TerrainMap 自产自销校验 ──
	var v1 := PackedByteArray()
	v1.resize(HEADER_BYTES)
	for i in range(4):
		v1[i] = TerrainMap.MLTR_MAGIC.unicode_at(i)
	v1[4] = TerrainMap.MLTR_VERSION_1
	v1[5] = n
	v1[6] = n
	v1.encode_float(7, WorldGrid.TILE_SIZE)
	v1.append_array(types)
	v1.append_array(heights)
	v1.append_array(depths)
	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(v1)
	assert(r["ok"], "中世纪地貌自产自销必须可载入: %s" % r.get("error", ""))
	var composed: Dictionary = COMPOSE.compose("medieval")
	TerrainMap.reset()
	return COMPOSE.build_v2_bytes(types, heights, depths, composed)

static func _idx(n: int, x: int, z: int) -> int:
	return posmod(z, n) * n + posmod(x, n)

static func _in_ellipse(x: int, z: int, cx: float, cz: float, rx: float, rz: float) -> bool:
	var dx := (float(x) + 0.5 - cx) / rx
	var dz := (float(z) + 0.5 - cz) / rz
	return dx * dx + dz * dz <= 1.0

static func _ellipse_h(arr: PackedByteArray, n: int, cx: float, cz: float, rx: float, rz: float, h: int) -> void:
	for z in range(int(cz - rz), int(cz + rz) + 1):
		for x in range(int(cx - rx), int(cx + rx) + 1):
			if _in_ellipse(x, z, cx, cz, rx, rz):
				arr[_idx(n, x, z)] = h

static func _ellipse_type(arr: PackedByteArray, n: int, cx: float, cz: float, rx: float, rz: float, t: int) -> void:
	for z in range(int(cz - rz), int(cz + rz) + 1):
		for x in range(int(cx - rx), int(cx + rx) + 1):
			if _in_ellipse(x, z, cx, cz, rx, rz):
				arr[_idx(n, x, z)] = t

static func _rect_type(arr: PackedByteArray, n: int, x0: int, z0: int, x1: int, z1: int, t: int) -> void:
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			arr[_idx(n, x, z)] = t

static func _ellipse_depth(depths: PackedByteArray, types: PackedByteArray, n: int, cx: float, cz: float, rx: float, rz: float, d: int) -> void:
	for z in range(int(cz - rz), int(cz + rz) + 1):
		for x in range(int(cx - rx), int(cx + rx) + 1):
			if _in_ellipse(x, z, cx, cz, rx, rz) and types[_idx(n, x, z)] == T_WATER:
				depths[_idx(n, x, z)] = d

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
