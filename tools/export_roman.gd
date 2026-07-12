extends SceneTree
## 程序化生成罗马主题地图并导出 .mltr v2（+ POI/portal json），供 POST /admin/scenes 入库。
## themed-terrain P3 罗马切片：罗马石板底 + 5 种地表（罗马石板/大理石/碎石/马赛克/斗兽场沙土）
## + 一处喷泉水，并造「大理石 mound（神庙台）」与「碎石 dune」两种不同类型抬高块——
## 复用 P1 类型化侧壁（大理石壁 vs 碎石壁）。罗马石板复用中世纪 T_STONE_SLAB、
## 碎石复用侏罗纪 T_RUBBLE、斗兽场沙土复用侏罗纪 T_CRACKED_EARTH。
##
## 用法：godot --headless --path . --script res://tools/export_roman.gd -- --out roman.mltr

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_STONE_SLAB := 23     # 罗马石板（底，可抬高）
const T_MARBLE := 25         # 大理石（可抬高）
const T_RUBBLE := 21         # 碎石
const T_MOSAIC := 26         # 马赛克地
const T_CRACKED_EARTH := 17  # 斗兽场沙土
const T_WATER := 2           # 喷泉水

func _init() -> void:
	var out_path := _arg("--out", "roman.mltr")
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

## 罗马 POI：神庙 / 斗兽场 / 喷泉。
static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_temple", "name": "神庙", "aliases": ["神庙", "神殿", "大理石台"] },
		{ "tile": [22, 52], "radius": 7.0, "trigger": "poi_colosseum", "name": "斗兽场", "aliases": ["斗兽场", "竞技场", "沙场"] },
		{ "tile": [37, 40], "radius": 4.0, "trigger": "poi_fountain", "name": "喷泉", "aliases": ["喷泉", "水池", "水"] },
	]

## 传送点（scene-portal-graph）：中世纪/中国/现代城市 各一对双向 portal。落点选边缘干地，
## 避开喷泉水(37,40) 与 mound(50,28)/(60,58)。与对向场景 build_portal_json() 互指。
static func build_portal_json() -> Array:
	return [
		{ "tile": [12, 12], "radius": 3.0, "toScene": "medieval", "toTile": [37, 12] },
		{ "tile": [37, 12], "radius": 3.0, "toScene": "ancient_china", "toTile": [65, 12] },
		{ "tile": [65, 12], "radius": 3.0, "toScene": "modern_city", "toTile": [37, 12] },
	]

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_roman.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)

	# ── 底：全图罗马石板（模态地表 → base_layer = 石板）──
	for i in range(count):
		types[i] = T_STONE_SLAB

	# ── 地表分区（顶面语义）──
	_ellipse_type(types, n, 22.5, 52.5, 13.0, 12.0, T_CRACKED_EARTH) # 西南 斗兽场沙土
	_ellipse_type(types, n, 18.5, 18.5, 10.0, 9.0, T_MOSAIC)         # 西北 马赛克庭
	_ellipse_type(types, n, 55.5, 55.5, 9.0, 8.0, T_MOSAIC)          # 东南 马赛克庭
	_ellipse_type(types, n, 55.5, 18.5, 8.0, 7.0, T_RUBBLE)          # 东北 碎石堆

	# ── 大理石 mound（神庙台）：footprint 涂大理石，再同心抬高（逐级露大理石崖壁）──
	_ellipse_type(types, n, 50.5, 28.5, 6.5, 6.0, T_MARBLE)
	_ellipse_h(heights, n, 50.5, 28.5, 6.5, 6.0, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 4.2, 3.8, 2)
	_ellipse_h(heights, n, 50.5, 28.5, 2.2, 2.0, 3)

	# ── 碎石 dune：footprint 涂碎石，再抬高——侧壁应为「碎石壁」而非大理石壁（验证 type-aware）──
	_ellipse_type(types, n, 60.5, 58.5, 5.0, 4.5, T_RUBBLE)
	_ellipse_h(heights, n, 60.5, 58.5, 5.0, 4.5, 1)
	_ellipse_h(heights, n, 60.5, 58.5, 2.8, 2.5, 2)

	# ── 喷泉水：中央广场一汪水（浅水外圈 + 深水中心）──
	_ellipse_type(types, n, 37.5, 40.5, 4.0, 3.6, T_WATER)
	for i in range(count):
		if types[i] == T_WATER:
			depths[i] = 1
			heights[i] = 0
	_ellipse_depth(depths, types, n, 37.5, 40.5, 2.2, 2.0, 2)

	# ── 组装物品层（罗马切片无散布物品）+ 灌回 TerrainMap 自产自销校验 ──
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
	assert(r["ok"], "罗马地貌自产自销必须可载入: %s" % r.get("error", ""))
	var composed: Dictionary = COMPOSE.compose("roman")
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
