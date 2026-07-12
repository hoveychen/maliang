extends SceneTree
## 程序化生成中国古代主题地图并导出 .mltr v2（+ POI/portal json），供 POST /admin/scenes 入库。
## themed-terrain P3 中国古代切片：青石板底 + 5 种地表（青石板/夯土/木地板/卵石庭/水墨水塘）
## + 一处水塘，并造「夯土 mound（夯土台）」与「青石板 dune」两种不同类型抬高块——
## 复用 P1 类型化侧壁（夯土壁 vs 石板壁）。青石板复用 T_STONE_SLAB、夯土复用 T_CRACKED_EARTH、
## 卵石庭复用 T_COBBLE。
##
## 用法：godot --headless --path . --script res://tools/export_ancient_china.gd -- --out ancient_china.mltr

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_STONE_SLAB := 23     # 青石板（底，可抬高）
const T_CRACKED_EARTH := 17  # 夯土（可抬高）
const T_WOOD_FLOOR := 27     # 木地板（廊）
const T_COBBLE := 22         # 卵石庭
const T_WATER := 2           # 水墨水塘

func _init() -> void:
	var out_path := _arg("--out", "ancient_china.mltr")
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

## 中国古代 POI：夯土台 / 木廊 / 荷塘。
static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_earthaltar", "name": "夯土台", "aliases": ["夯土台", "土台", "高台"] },
		{ "tile": [22, 20], "radius": 6.0, "trigger": "poi_woodcorridor", "name": "木廊", "aliases": ["木廊", "回廊", "木地板"] },
		{ "tile": [37, 40], "radius": 5.0, "trigger": "poi_lotuspond", "name": "荷塘", "aliases": ["荷塘", "水塘", "池", "水"] },
	]

## 传送点（scene-portal-graph）：中世纪/罗马/冰雪 各一对双向 portal。落点选边缘干地，
## 避开水墨水塘(37,40) 与 mound(50,28)/(60,58)。与对向场景 build_portal_json() 互指。
static func build_portal_json() -> Array:
	return [
		{ "tile": [12, 12], "radius": 3.0, "toScene": "medieval", "toTile": [12, 65] },
		{ "tile": [65, 12], "radius": 3.0, "toScene": "roman", "toTile": [37, 12] },
		{ "tile": [12, 65], "radius": 3.0, "toScene": "icesnow", "toTile": [65, 12] },
	]

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_ancient_china.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)

	# ── 底：全图青石板（模态地表 → base_layer = 石板）──
	for i in range(count):
		types[i] = T_STONE_SLAB

	# ── 地表分区（顶面语义）──
	_ellipse_type(types, n, 22.5, 20.5, 10.0, 9.0, T_WOOD_FLOOR)     # 西北 木廊
	_ellipse_type(types, n, 55.5, 55.5, 9.0, 8.0, T_WOOD_FLOOR)      # 东南 木廊
	_ellipse_type(types, n, 18.5, 55.5, 8.0, 7.0, T_COBBLE)          # 西南 卵石庭
	_ellipse_type(types, n, 55.5, 20.5, 7.0, 6.5, T_COBBLE)          # 东北 卵石庭

	# ── 夯土 mound（夯土台）：footprint 涂夯土，再同心抬高（逐级露夯土崖壁）──
	_ellipse_type(types, n, 50.5, 28.5, 6.5, 6.0, T_CRACKED_EARTH)
	_ellipse_h(heights, n, 50.5, 28.5, 6.5, 6.0, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 4.2, 3.8, 2)
	_ellipse_h(heights, n, 50.5, 28.5, 2.2, 2.0, 3)

	# ── 青石板 dune：footprint 涂青石板，再抬高——侧壁应为「石板壁」而非夯土壁（验证 type-aware）──
	_ellipse_type(types, n, 60.5, 58.5, 5.0, 4.5, T_STONE_SLAB)
	_ellipse_h(heights, n, 60.5, 58.5, 5.0, 4.5, 1)
	_ellipse_h(heights, n, 60.5, 58.5, 2.8, 2.5, 2)

	# ── 水墨水塘（荷塘）：中央一汪水（浅水外圈 + 深水中心）──
	_ellipse_type(types, n, 37.5, 40.5, 4.5, 4.0, T_WATER)
	for i in range(count):
		if types[i] == T_WATER:
			depths[i] = 1
			heights[i] = 0
	_ellipse_depth(depths, types, n, 37.5, 40.5, 2.5, 2.2, 2)

	# ── 组装物品层（中国古代切片无散布物品）+ 灌回 TerrainMap 自产自销校验 ──
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
	assert(r["ok"], "中国古代地貌自产自销必须可载入: %s" % r.get("error", ""))
	var composed: Dictionary = COMPOSE.compose("ancient_china")
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
