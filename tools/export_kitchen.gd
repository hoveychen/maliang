extends SceneTree
## 程序化生成厨房主题地图并导出 .mltr v2（themed-terrain P3，室内带墙房间）。
## 白瓷砖地板底 + 白瓷砖墙围四壁（T_KITCHEN_WALL，抬高成围墙）+ 内部地面装饰
## （格纹地砖 / 防滑垫 / 木地板料理岛）+ 中央矮灶台（瓷砖平台，type-aware 侧壁）。室内无水。
## 用法：godot --headless --path . --script res://tools/export_kitchen.gd -- --out kitchen.mltr

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_TILE := 7            # 白瓷砖（底，可抬高）
const T_CHECKER_TILE := 36   # 格纹地砖
const T_WOOD_FLOOR := 27     # 木地板（可抬高）
const T_ANTISLIP := 37       # 防滑垫
const T_KITCHEN_WALL := 45   # 厨房墙面（围墙，抬高成四壁）

func _init() -> void:
	var out_path := _arg("--out", "kitchen.mltr")
	var buf := build_terrain_bytes()
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("无法写入 ", out_path); quit(1); return
	f.store_buffer(buf); f.close()
	var gz := buf.compress(FileAccess.COMPRESSION_GZIP)
	print("导出 %s：%d B（gzip %d B）grid=%d×%d" % [out_path, buf.size(), gz.size(), WorldGrid.GRID_TILES, WorldGrid.GRID_TILES])
	_dump(_arg("--poi-out", out_path.get_basename() + ".pois.json"), build_poi_json())
	_dump(_arg("--portal-out", out_path.get_basename() + ".portals.json"), build_portal_json())
	quit(0)

## 厨房 POI：灶台 / 料理岛 / 花砖区（均落在房间内部）。
static func build_poi_json() -> Array:
	return [
		{ "tile": [37, 37], "radius": 6.0, "trigger": "poi_stove", "name": "灶台", "aliases": ["灶台", "炉子", "瓷砖台"] },
		{ "tile": [28, 46], "radius": 5.0, "trigger": "poi_island", "name": "料理岛", "aliases": ["料理岛", "木台", "案板"] },
		{ "tile": [28, 28], "radius": 6.0, "trigger": "poi_checkerfloor", "name": "花砖区", "aliases": ["花砖", "格纹", "格子"] },
	]

static func build_portal_json() -> Array:
	return []

static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray(); types.resize(count)
	var heights := PackedByteArray(); heights.resize(count)
	var depths := PackedByteArray(); depths.resize(count)

	# ── 底：全图白瓷砖（模态地表 → base_layer = 瓷砖）──
	for i in range(count):
		types[i] = T_TILE

	# ── 房间内部 [X0..X1]×[Z0..Z1] 铺地面装饰，四周 2 格厚墙环抬高成围墙 ──
	var X0 := 20; var X1 := 54; var Z0 := 20; var Z1 := 54
	var WALL_H := 3
	# 地面装饰（限房间内部）：格纹区 NW / 防滑垫 NE(水槽) / 木料理岛地 SW
	_ellipse_type(types, n, 28.5, 28.5, 6.5, 6.0, T_CHECKER_TILE)
	_rect_type(types, n, 43, 24, 50, 31, T_ANTISLIP)
	_ellipse_type(types, n, 28.5, 46.5, 5.5, 5.0, T_WOOD_FLOOR)
	# 木料理岛（1 级木平台，木壁 type-aware）
	_ellipse_h(heights, n, 28.5, 46.5, 4.0, 3.6, 1)
	# 中央矮灶台（1 级瓷砖平台，瓷砖壁 type-aware）
	_ellipse_type(types, n, 37.5, 37.5, 3.5, 3.2, T_TILE)
	_ellipse_h(heights, n, 37.5, 37.5, 3.5, 3.2, 1)
	# 四壁：房间边界 2 格厚墙环，抬高 WALL_H（白瓷砖墙 type-aware，不倒角）
	_wall_ring(types, heights, n, X0, Z0, X1, Z1, 2, T_KITCHEN_WALL, WALL_H)

	return _assemble(types, heights, depths, "kitchen")

static func _assemble(types: PackedByteArray, heights: PackedByteArray, depths: PackedByteArray, scene_id: String) -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var v1 := PackedByteArray(); v1.resize(HEADER_BYTES)
	for i in range(4):
		v1[i] = TerrainMap.MLTR_MAGIC.unicode_at(i)
	v1[4] = TerrainMap.MLTR_VERSION_1; v1[5] = n; v1[6] = n
	v1.encode_float(7, WorldGrid.TILE_SIZE)
	v1.append_array(types); v1.append_array(heights); v1.append_array(depths)
	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(v1)
	assert(r["ok"], "%s 地貌自产自销必须可载入: %s" % [scene_id, r.get("error", "")])
	var composed: Dictionary = COMPOSE.compose(scene_id)
	TerrainMap.reset()
	return COMPOSE.build_v2_bytes(types, heights, depths, composed)

static func _dump(path: String, data: Array) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("无法写入 ", path); return
	f.store_string(JSON.stringify(data, "  ")); f.close()
	print("导出 %s：%d 项" % [path, data.size()])

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
## 内部地面不动；外扩环 = 墙 footprint（抬高后成四面围墙，type-aware 侧壁 = 墙贴图）。
static func _wall_ring(types: PackedByteArray, heights: PackedByteArray, n: int, x0: int, z0: int, x1: int, z1: int, thick: int, t: int, h: int) -> void:
	for z in range(z0 - thick, z1 + thick + 1):
		for x in range(x0 - thick, x1 + thick + 1):
			if x >= x0 and x <= x1 and z >= z0 and z <= z1:
				continue
			var i := _idx(n, x, z)
			types[i] = t
			heights[i] = h

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
