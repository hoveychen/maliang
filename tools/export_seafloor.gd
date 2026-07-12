extends SceneTree
## 程序化生成海底主题地图并导出 .mltr v2（+ POI/portal json），供 POST /admin/scenes 入库。
## themed-terrain P2 垂直切片：铺满 6 种海底地表（细沙/粗沙/珊瑚砂/礁岩/海草地/深水床）
## + 一处礁湖水体，并造「礁岩 mound」与「粗沙 dune」两种不同类型的抬高地块——
## 用来验证 P1 的「崖壁按被抬高 tile 类型选侧壁层」（礁岩壁 vs 粗沙壁，不再一堵通用土墙）。
##
## 用法：godot --headless --path . --script res://tools/export_seafloor.gd -- --out seafloor.mltr
## 格式见 server/src/terrain.ts / tools/export_terrain.gd（三处必须同步）。

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_SAND := 5          # 细沙（底）
const T_COARSE_SAND := 8   # 粗沙
const T_CORAL_SAND := 9    # 珊瑚砂
const T_REEF := 10         # 礁岩（可抬高）
const T_SEAGRASS := 11     # 海草地
const T_DEEP_BED := 12     # 深水床（暗）
const T_WATER := 2         # 水体

func _init() -> void:
	var out_path := _arg("--out", "seafloor.mltr")
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

## 海底 POI：给意图 LLM 的地名（礁石群 / 海草丛 / 珊瑚礁湖）。
static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_reef_rocks", "name": "礁石群", "aliases": ["礁石", "石头", "礁岩"] },
		{ "tile": [18, 18], "radius": 6.0, "trigger": "poi_seagrass", "name": "海草丛", "aliases": ["海草", "水草", "草丛"] },
		{ "tile": [37, 40], "radius": 5.0, "trigger": "poi_lagoon", "name": "礁湖", "aliases": ["水潭", "礁湖", "水塘"] },
	]

## 海底切片暂无传送点（独立展示地图，不与村庄/森林互连）。
static func build_portal_json() -> Array:
	return []

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_seafloor.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)

	# ── 底：全图细沙 ──
	for i in range(count):
		types[i] = T_SAND

	# ── 地表分区（顶面语义，行主序 wrap）──
	_ellipse_type(types, n, 18.5, 18.5, 13.0, 11.0, T_SEAGRASS)   # 西北 海草地
	_ellipse_type(types, n, 52.5, 52.5, 12.0, 10.0, T_CORAL_SAND) # 东南 珊瑚砂
	_ellipse_type(types, n, 55.5, 18.5, 8.0, 7.0, T_COARSE_SAND)  # 东北 粗沙滩
	_ellipse_type(types, n, 20.5, 55.5, 7.0, 6.5, T_COARSE_SAND)  # 西南 粗沙滩
	_ellipse_type(types, n, 37.5, 40.5, 10.0, 9.0, T_DEEP_BED)    # 中央 深水床盆地

	# ── 礁岩 mound A/B：footprint 涂礁岩，再同心抬高（缓坡可走上，逐级露礁岩崖壁）──
	_ellipse_type(types, n, 50.5, 28.5, 6.5, 6.0, T_REEF)
	_ellipse_h(heights, n, 50.5, 28.5, 6.5, 6.0, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 4.2, 3.8, 2)
	_ellipse_h(heights, n, 50.5, 28.5, 2.2, 2.0, 3)
	_ellipse_type(types, n, 28.5, 50.5, 5.5, 5.0, T_REEF)
	_ellipse_h(heights, n, 28.5, 50.5, 5.5, 5.0, 1)
	_ellipse_h(heights, n, 28.5, 50.5, 3.0, 2.7, 2)

	# ── 粗沙 dune：footprint 涂粗沙，再抬高——侧壁应为「粗沙壁」而非礁岩壁（验证 type-aware）──
	_ellipse_type(types, n, 60.5, 58.5, 5.0, 4.5, T_COARSE_SAND)
	_ellipse_h(heights, n, 60.5, 58.5, 5.0, 4.5, 1)
	_ellipse_h(heights, n, 60.5, 58.5, 2.8, 2.5, 2)

	# ── 礁湖水体：深水床盆地中央一汪水（浅水外圈 + 深水中心）──
	_ellipse_type(types, n, 37.5, 40.5, 4.5, 4.0, T_WATER)
	for i in range(count):
		if types[i] == T_WATER:
			depths[i] = 1
			heights[i] = 0
	_ellipse_depth(depths, types, n, 37.5, 40.5, 2.5, 2.2, 2)

	# ── 组装物品层（海底切片无散布物品）+ 灌回 TerrainMap 自产自销校验 ──
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
	assert(r["ok"], "海底地貌自产自销必须可载入: %s" % r.get("error", ""))
	var composed: Dictionary = COMPOSE.compose("seafloor")
	TerrainMap.reset() # 不给同进程后续使用者留海底地形
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
