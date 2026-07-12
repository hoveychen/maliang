extends SceneTree
## 程序化生成玩具房间主题地图并导出 .mltr v2（+ POI/portal json），供 POST /admin/scenes 入库。
## themed-terrain P3 玩具房间切片：木地板底 + 5 种地表（木地板/地毯红/地毯蓝/拼图垫/瓷砖）
## + 造「木地板 mound（玩具台）」与「瓷砖 dune（浴垫台）」两种不同类型抬高块——
## 复用 P1 类型化侧壁（木壁 vs 瓷砖壁）。室内主题无水体。
##
## 用法：godot --headless --path . --script res://tools/export_toy_room.gd -- --out toy_room.mltr

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_WOOD_FLOOR := 27     # 木地板（底，可抬高）
const T_CARPET_RED := 33     # 地毯红
const T_CARPET_BLUE := 34    # 地毯蓝
const T_PUZZLE_MAT := 35     # 拼图垫
const T_TILE := 7            # 瓷砖（可抬高）

func _init() -> void:
	var out_path := _arg("--out", "toy_room.mltr")
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

## 玩具房间 POI：积木台 / 地毯 / 拼图角。
static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_blocktable", "name": "积木台", "aliases": ["积木台", "台子", "木台"] },
		{ "tile": [20, 20], "radius": 6.0, "trigger": "poi_rug", "name": "地毯", "aliases": ["地毯", "毯子", "红毯"] },
		{ "tile": [24, 52], "radius": 6.0, "trigger": "poi_puzzle", "name": "拼图角", "aliases": ["拼图", "拼图垫", "垫子"] },
	]

static func build_portal_json() -> Array:
	return []

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_toy_room.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)

	# ── 底：全图木地板（模态地表 → base_layer = 木地板）──
	for i in range(count):
		types[i] = T_WOOD_FLOOR

	# ── 地表分区（顶面语义）──
	_ellipse_type(types, n, 20.5, 20.5, 11.0, 10.0, T_CARPET_RED)   # 西北 红地毯
	_ellipse_type(types, n, 56.5, 56.5, 9.0, 8.0, T_CARPET_BLUE)    # 东南 蓝地毯
	_ellipse_type(types, n, 24.5, 52.5, 9.0, 8.0, T_PUZZLE_MAT)     # 西南 拼图角
	_rect_type(types, n, 40, 44, 52, 56, T_TILE)                    # 东南一角 瓷砖

	# ── 木地板 mound（玩具台）：footprint 涂木地板，再同心抬高（逐级露木崖壁）──
	_ellipse_type(types, n, 50.5, 28.5, 6.5, 6.0, T_WOOD_FLOOR)
	_ellipse_h(heights, n, 50.5, 28.5, 6.5, 6.0, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 4.2, 3.8, 2)

	# ── 瓷砖 dune（浴垫台）：footprint 涂瓷砖，再抬高——侧壁应为「瓷砖壁」而非木壁（验证 type-aware）──
	_ellipse_type(types, n, 46.5, 50.5, 4.0, 3.6, T_TILE)
	_ellipse_h(heights, n, 46.5, 50.5, 4.0, 3.6, 1)
	_ellipse_h(heights, n, 46.5, 50.5, 2.2, 2.0, 2)

	# ── 组装物品层（玩具房间切片无散布物品）+ 灌回 TerrainMap 自产自销校验 ──
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
	assert(r["ok"], "玩具房间地貌自产自销必须可载入: %s" % r.get("error", ""))
	var composed: Dictionary = COMPOSE.compose("toy_room")
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

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
