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
const T_TOY_WALL := 44       # 玩具房间墙面（围墙，抬高成四壁）

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
		{ "tile": [37, 37], "radius": 6.0, "trigger": "poi_blocktable", "name": "积木台", "aliases": ["积木台", "台子", "木台"] },
		{ "tile": [28, 28], "radius": 6.0, "trigger": "poi_rug", "name": "地毯", "aliases": ["地毯", "毯子", "红毯"] },
		{ "tile": [28, 46], "radius": 6.0, "trigger": "poi_puzzle", "name": "拼图角", "aliases": ["拼图", "拼图垫", "垫子"] },
	]

## 传送点（scene-portal-graph）：厨房/未来 各一对双向 portal（室内簇末梢，度 2）。
## 室内落点选房间内部地板角（[20..54] 内），避开中央玩具台(37,37)。与对向场景互指。
static func build_portal_json() -> Array:
	return [
		{ "tile": [24, 24], "radius": 3.0, "toScene": "kitchen", "toTile": [50, 50] },
		{ "tile": [50, 24], "radius": 3.0, "toScene": "future_robot", "toTile": [24, 50] },
	]

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

	# ── 房间：玩具房间墙面 tile 围一圈抬高成四壁（老板拍板「tile 当墙搭带墙的房间」）。
	# 内部 [X0..X1]×[Z0..Z1] 铺地面装饰，四周 2 格厚墙环抬高 WALL_H 级成围墙。
	# 墙用 T_TOY_WALL（专属托儿所壁纸墙面，type-aware 侧壁），不倒角（室内墙保持利落直角）。
	var X0 := 20; var X1 := 54; var Z0 := 20; var Z1 := 54
	var WALL_H := 3
	# 地面装饰（限房间内部）：红毯 NW / 蓝毯 SE / 拼图角 SW / 瓷砖区 NE
	_ellipse_type(types, n, 28.5, 28.5, 6.5, 6.0, T_CARPET_RED)
	_ellipse_type(types, n, 46.5, 46.5, 6.5, 6.0, T_CARPET_BLUE)
	_ellipse_type(types, n, 28.5, 46.5, 5.5, 5.0, T_PUZZLE_MAT)
	_rect_type(types, n, 44, 24, 51, 31, T_TILE)
	# 中央矮玩具台（1 级木平台，木壁 type-aware）
	_ellipse_type(types, n, 37.5, 37.5, 3.5, 3.2, T_WOOD_FLOOR)
	_ellipse_h(heights, n, 37.5, 37.5, 3.5, 3.2, 1)
	# 四壁：房间边界 2 格厚墙环（内缘 X0/Z0..X1/Z1，外扩 2 格），抬高 WALL_H
	_wall_ring(types, heights, n, X0, Z0, X1, Z1, 2, T_TOY_WALL, WALL_H)

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

## 房间四壁：内部矩形 [x0..x1]×[z0..z1] 外扩 thick 格的环形边框设为墙 tile 类型 t + 抬高 h。
## 内部保持地面不动；外扩环 = 墙 footprint（抬高后成四面围墙，type-aware 侧壁 = 墙贴图）。
static func _wall_ring(types: PackedByteArray, heights: PackedByteArray, n: int, x0: int, z0: int, x1: int, z1: int, thick: int, t: int, h: int) -> void:
	for z in range(z0 - thick, z1 + thick + 1):
		for x in range(x0 - thick, x1 + thick + 1):
			if x >= x0 and x <= x1 and z >= z0 and z <= z1:
				continue  # 内部地面不动
			var i := _idx(n, x, z)
			types[i] = t
			heights[i] = h

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
