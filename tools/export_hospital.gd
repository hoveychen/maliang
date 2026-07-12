extends SceneTree
## 程序化生成医院主题地图并导出 .mltr v2（themed-terrain P3）。
## 医用地胶浅绿底 + 5 种地表（医用地胶浅绿/白瓷砖/防滑走廊/手术室地/医用地胶浅蓝）
## +「瓷砖 mound（诊台）」与「混凝土 dune（设备台）」两种不同类型抬高块——复用 P1 类型化侧壁。室内无水。
## 用法：godot --headless --path . --script res://tools/export_hospital.gd -- --out hospital.mltr

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_MED_VINYL_GREEN := 38  # 医用地胶浅绿（底）
const T_TILE := 7              # 白瓷砖（可抬高）
const T_ANTISLIP := 37         # 防滑走廊
const T_CONCRETE := 31         # 手术室地（可抬高）
const T_MED_VINYL_BLUE := 39   # 医用地胶浅蓝

func _init() -> void:
	var out_path := _arg("--out", "hospital.mltr")
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

static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_clinic", "name": "诊台", "aliases": ["诊台", "看诊", "瓷砖台"] },
		{ "tile": [28, 50], "radius": 5.0, "trigger": "poi_or", "name": "手术室", "aliases": ["手术室", "手术台", "设备台"] },
		{ "tile": [20, 20], "radius": 6.0, "trigger": "poi_ward", "name": "病房", "aliases": ["病房", "浅蓝区", "蓝地胶"] },
	]

static func build_portal_json() -> Array:
	return []

static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray(); types.resize(count)
	var heights := PackedByteArray(); heights.resize(count)
	var depths := PackedByteArray(); depths.resize(count)

	for i in range(count):
		types[i] = T_MED_VINYL_GREEN  # 底：浅绿地胶（模态 → base_layer = 浅绿地胶）

	_ellipse_type(types, n, 20.5, 20.5, 11.0, 10.0, T_MED_VINYL_BLUE)  # 西北 浅蓝病房
	_ellipse_type(types, n, 55.5, 55.5, 9.0, 8.0, T_MED_VINYL_BLUE)    # 东南 浅蓝病房
	_rect_type(types, n, 30, 8, 33, 66, T_ANTISLIP)                   # 竖向防滑走廊
	_rect_type(types, n, 8, 36, 66, 39, T_ANTISLIP)                   # 横向防滑走廊

	# 瓷砖 mound（诊台）
	_ellipse_type(types, n, 50.5, 28.5, 6.0, 5.5, T_TILE)
	_ellipse_h(heights, n, 50.5, 28.5, 6.0, 5.5, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 3.8, 3.4, 2)
	# 混凝土 dune（手术室设备台）——侧壁应为混凝土壁（验证 type-aware）
	_ellipse_type(types, n, 28.5, 50.5, 4.5, 4.0, T_CONCRETE)
	_ellipse_h(heights, n, 28.5, 50.5, 4.5, 4.0, 1)
	_ellipse_h(heights, n, 28.5, 50.5, 2.4, 2.2, 2)

	return _assemble(types, heights, depths, "hospital")

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

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
