extends SceneTree
## 程序化生成冰雪世界主题地图并导出 .mltr v2（+ POI/portal json），供 POST /admin/scenes 入库。
## themed-terrain P3 冰雪切片：铺满 5 种冰雪地表（压实雪底/雪原/冰面/雪泥/裸岩积雪）
## + 一处未冻开阔水，并造「裸岩 mound」与「压实雪 dune」两种不同类型的抬高地块——
## 复用 P1 的「崖壁按被抬高 tile 类型选侧壁层」（裸岩壁 vs 压实雪壁，不再一堵通用土墙）。
##
## 用法：godot --headless --path . --script res://tools/export_icesnow.gd -- --out icesnow.mltr
## 格式见 server/src/terrain.ts / tools/export_terrain.gd（三处必须同步）。

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_PACKED_SNOW := 13   # 压实雪（底）
const T_SNOW := 6           # 雪原
const T_ICE := 14           # 冰面（结冰水）
const T_SLUSH := 15         # 雪泥
const T_ROCK_SNOW := 16     # 裸岩积雪（可抬高）
const T_WATER := 2          # 开阔水（未冻）

func _init() -> void:
	var out_path := _arg("--out", "icesnow.mltr")
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

## 冰雪 POI：给意图 LLM 的地名（雪山 / 冰湖 / 雪原）。
static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_snow_peak", "name": "雪山", "aliases": ["雪山", "山", "山峰"] },
		{ "tile": [37, 40], "radius": 6.0, "trigger": "poi_ice_lake", "name": "冰湖", "aliases": ["冰湖", "湖", "冰面", "溜冰"] },
		{ "tile": [18, 18], "radius": 7.0, "trigger": "poi_snowfield", "name": "雪原", "aliases": ["雪原", "雪地", "雪"] },
	]

## 冰雪切片暂无传送点（独立展示地图）。
## 传送点（scene-portal-graph）：侏罗/海底/中国 各一对双向 portal。落点选边缘干地，
## 避开开阔水(14,30) 与 mound(50,28)/(28,50)/(60,58)。与对向场景 build_portal_json() 互指。
static func build_portal_json() -> Array:
	return [
		{ "tile": [12, 12], "radius": 3.0, "toScene": "jurassic", "toTile": [37, 12] },
		{ "tile": [37, 12], "radius": 3.0, "toScene": "seafloor", "toTile": [37, 12] },
		{ "tile": [65, 12], "radius": 3.0, "toScene": "ancient_china", "toTile": [12, 65] },
	]

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_icesnow.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)

	# ── 底：全图压实雪（模态地表 → base_layer = 压实雪）──
	for i in range(count):
		types[i] = T_PACKED_SNOW

	# ── 地表分区（顶面语义，行主序 wrap）──
	_ellipse_type(types, n, 18.5, 18.5, 13.0, 11.0, T_SNOW)     # 西北 雪原
	_ellipse_type(types, n, 55.5, 55.5, 12.0, 10.0, T_SNOW)     # 东南 雪原
	_ellipse_type(types, n, 55.5, 18.5, 9.0, 8.0, T_SLUSH)      # 东北 融雪泥泞（P4 扩大）
	_ellipse_type(types, n, 20.5, 37.5, 4.0, 3.6, T_ICE)        # 西 小冰塘（P4 拼布）
	_ellipse_type(types, n, 20.5, 55.5, 7.0, 6.5, T_SLUSH)      # 西南 融雪泥泞
	_ellipse_type(types, n, 37.5, 40.5, 10.0, 9.0, T_ICE)       # 中央 冰湖（结冰面，可走）

	# ── 裸岩 mound A/B：footprint 涂裸岩积雪，再同心抬高（缓坡可走上，逐级露裸岩崖壁）──
	_ellipse_type(types, n, 50.5, 28.5, 6.5, 6.0, T_ROCK_SNOW)
	_ellipse_h(heights, n, 50.5, 28.5, 6.5, 6.0, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 4.2, 3.8, 2)
	_ellipse_h(heights, n, 50.5, 28.5, 2.2, 2.0, 3)
	_ellipse_type(types, n, 28.5, 50.5, 5.5, 5.0, T_ROCK_SNOW)
	_ellipse_h(heights, n, 28.5, 50.5, 5.5, 5.0, 1)
	_ellipse_h(heights, n, 28.5, 50.5, 3.0, 2.7, 2)

	# ── 压实雪 dune：footprint 涂压实雪，再抬高——侧壁应为「压实雪壁」而非裸岩壁（验证 type-aware）──
	_ellipse_type(types, n, 60.5, 58.5, 5.0, 4.5, T_PACKED_SNOW)
	_ellipse_h(heights, n, 60.5, 58.5, 5.0, 4.5, 1)
	_ellipse_h(heights, n, 60.5, 58.5, 2.8, 2.5, 2)

	# ── 开阔水（未冻）：西北雪原一角一汪水（浅水外圈 + 深水中心）──
	_ellipse_type(types, n, 14.5, 30.5, 4.5, 4.0, T_WATER)
	for i in range(count):
		if types[i] == T_WATER:
			depths[i] = 1
			heights[i] = 0
	_ellipse_depth(depths, types, n, 14.5, 30.5, 2.5, 2.2, 2)

	# ── 组装物品层（冰雪切片无散布物品）+ 灌回 TerrainMap 自产自销校验 ──
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
	assert(r["ok"], "冰雪地貌自产自销必须可载入: %s" % r.get("error", ""))
	var composed: Dictionary = COMPOSE.compose("icesnow")
	TerrainMap.reset() # 不给同进程后续使用者留冰雪地形
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
