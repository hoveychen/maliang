extends SceneTree
## 程序化生成现代城市主题地图并导出 .mltr v2（+ POI/portal json），供 POST /admin/scenes 入库。
## themed-terrain P3 现代城市切片：沥青底 + 5 种地表（沥青/人行道砖/斑马线/水泥/草坪格）
## + 一处景观水池，并造「水泥 mound（楼台）」与「人行道砖 dune」两种不同类型抬高块——
## 复用 P1 类型化侧壁（水泥壁 vs 砖壁）。
##
## 用法：godot --headless --path . --script res://tools/export_modern_city.gd -- --out modern_city.mltr

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_ASPHALT := 28        # 沥青（底）
const T_PAVER_BRICK := 29    # 人行道砖（可抬高）
const T_CROSSWALK := 30      # 斑马线
const T_CONCRETE := 31       # 水泥（可抬高）
const T_LAWN_GRID := 32      # 草坪格
const T_WATER := 2           # 景观水池

func _init() -> void:
	var out_path := _arg("--out", "modern_city.mltr")
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

## 现代城市 POI：广场 / 公园 / 十字路口。
static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_plaza", "name": "广场", "aliases": ["广场", "楼台", "水泥台"] },
		{ "tile": [18, 55], "radius": 7.0, "trigger": "poi_park", "name": "公园", "aliases": ["公园", "草坪", "草地"] },
		{ "tile": [37, 37], "radius": 5.0, "trigger": "poi_crossing", "name": "十字路口", "aliases": ["路口", "斑马线", "过街"] },
	]

## 传送点（scene-portal-graph）：村庄/罗马/未来/医院 各一对双向 portal（度 4，室内簇门户）。
## 落点选边缘干地，避开景观水池(18,55) 与 mound(50,28)/(60,58)。与对向场景互指。
static func build_portal_json() -> Array:
	return [
		{ "tile": [12, 12], "radius": 3.0, "toScene": "village", "toTile": [65, 40] },
		{ "tile": [37, 12], "radius": 3.0, "toScene": "roman", "toTile": [65, 12] },
		{ "tile": [65, 12], "radius": 3.0, "toScene": "future_robot", "toTile": [24, 24] },
		{ "tile": [12, 37], "radius": 3.0, "toScene": "hospital", "toTile": [24, 24] },
	]

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_modern_city.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)

	# ── 底：全图沥青（模态地表 → base_layer = 沥青）──
	for i in range(count):
		types[i] = T_ASPHALT

	# ── 地表分区（顶面语义）──
	_ellipse_type(types, n, 18.5, 55.5, 11.0, 10.0, T_LAWN_GRID)   # 西南 公园草坪
	_ellipse_type(types, n, 55.5, 55.5, 8.0, 7.0, T_LAWN_GRID)     # 东南 街心绿地
	# 人行道砖：沿主路两侧
	_rect_type(types, n, 30, 8, 33, 66, T_PAVER_BRICK)
	_rect_type(types, n, 42, 8, 45, 66, T_PAVER_BRICK)
	# 斑马线：十字路口横穿
	_rect_type(types, n, 34, 35, 41, 39, T_CROSSWALK)

	# ── 水泥 mound（楼台）：footprint 涂水泥，再同心抬高（逐级露水泥崖壁）──
	_ellipse_type(types, n, 50.5, 28.5, 6.5, 6.0, T_CONCRETE)
	_ellipse_h(heights, n, 50.5, 28.5, 6.5, 6.0, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 4.2, 3.8, 2)
	_ellipse_h(heights, n, 50.5, 28.5, 2.2, 2.0, 3)

	# ── 人行道砖 dune：footprint 涂砖，再抬高——侧壁应为「砖壁」而非水泥壁（验证 type-aware）──
	_ellipse_type(types, n, 60.5, 58.5, 5.0, 4.5, T_PAVER_BRICK)
	_ellipse_h(heights, n, 60.5, 58.5, 5.0, 4.5, 1)
	_ellipse_h(heights, n, 60.5, 58.5, 2.8, 2.5, 2)

	# ── 景观水池：公园一角一汪水（浅水外圈 + 深水中心）──
	_ellipse_type(types, n, 18.5, 55.5, 4.0, 3.6, T_WATER)
	for i in range(count):
		if types[i] == T_WATER:
			depths[i] = 1
			heights[i] = 0
	_ellipse_depth(depths, types, n, 18.5, 55.5, 2.2, 2.0, 2)

	# ── 组装物品层（现代城市切片无散布物品）+ 灌回 TerrainMap 自产自销校验 ──
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
	assert(r["ok"], "现代城市地貌自产自销必须可载入: %s" % r.get("error", ""))
	var composed: Dictionary = COMPOSE.compose("modern_city")
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
