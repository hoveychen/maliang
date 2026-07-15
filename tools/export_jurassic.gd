extends SceneTree
## 程序化生成侏罗纪主题地图并导出 .mltr v2（+ POI/portal json），供 POST /admin/scenes 入库。
## themed-terrain P3 侏罗纪切片：铺满 5 种侏罗纪地表（干裂土底/火山岩/泥沼/蕨类草地/碎石）
## + 一处泥沼水潭，并造「火山岩 mound」与「碎石 dune」两种不同类型的抬高地块——
## 复用 P1「崖壁按被抬高 tile 类型选侧壁层」（火山岩壁 vs 碎石壁）。
##
## 用法：godot --headless --path . --script res://tools/export_jurassic.gd -- --out jurassic.mltr

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11
const T_CRACKED_EARTH := 17  # 干裂土（底）
const T_VOLCANIC := 18       # 火山岩（可抬高）
const T_MUD_BOG := 19        # 泥沼
const T_FERN := 20           # 蕨类草地
const T_RUBBLE := 21         # 碎石（可抬高）
const T_WATER := 2           # 水潭

func _init() -> void:
	var out_path := _arg("--out", "jurassic.mltr")
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

## 侏罗纪 POI：给意图 LLM 的地名（火山 / 泥沼 / 蕨林）。
static func build_poi_json() -> Array:
	return [
		{ "tile": [50, 28], "radius": 6.0, "trigger": "poi_volcano", "name": "火山", "aliases": ["火山", "岩浆", "山"] },
		{ "tile": [37, 40], "radius": 6.0, "trigger": "poi_mudbog", "name": "泥沼", "aliases": ["泥沼", "沼泽", "泥潭", "水"] },
		{ "tile": [18, 18], "radius": 7.0, "trigger": "poi_fernwood", "name": "蕨林", "aliases": ["蕨林", "蕨类", "草丛"] },
	]

## 传送点（scene-portal-graph）：森林/冰雪/海底 各一对双向 portal。落点选边缘干地，
## 避开水潭(37,40) 与 mound(50,28)/(28,50)/(60,58)。与对向场景 build_portal_json() 互指。
static func build_portal_json() -> Array:
	return [
		{ "tile": [12, 12], "radius": 3.0, "toScene": "forest", "toTile": [65, 40] },
		{ "tile": [37, 12], "radius": 3.0, "toScene": "icesnow", "toTile": [12, 12] },
		{ "tile": [65, 12], "radius": 3.0, "toScene": "seafloor", "toTile": [65, 12] },
	]

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_jurassic.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)

	# ── 底：全图干裂土（模态地表 → base_layer = 干裂土）──
	for i in range(count):
		types[i] = T_CRACKED_EARTH

	# ── 地表分区（顶面语义，行主序 wrap）──
	_ellipse_type(types, n, 18.5, 18.5, 14.0, 12.0, T_FERN)      # 西北 蕨类草地（P4 扩大）
	_ellipse_type(types, n, 55.5, 55.5, 13.0, 11.0, T_FERN)      # 东南 蕨类草地（P4 扩大）
	_ellipse_type(types, n, 20.5, 37.5, 4.5, 4.0, T_MUD_BOG)     # 西 泥沼小塘（P4 拼布）
	_ellipse_type(types, n, 37.5, 40.5, 11.0, 10.0, T_MUD_BOG)   # 中央 泥沼盆地
	_ellipse_type(types, n, 55.5, 20.5, 9.0, 8.0, T_RUBBLE)      # 东北 碎石滩
	_ellipse_type(types, n, 20.5, 55.5, 7.0, 6.5, T_RUBBLE)      # 西南 碎石滩

	# ── 火山岩 mound A/B：footprint 涂火山岩，再同心抬高（逐级露火山岩崖壁）──
	_ellipse_type(types, n, 50.5, 28.5, 6.5, 6.0, T_VOLCANIC)
	_ellipse_h(heights, n, 50.5, 28.5, 6.5, 6.0, 1)
	_ellipse_h(heights, n, 50.5, 28.5, 4.2, 3.8, 2)
	_ellipse_h(heights, n, 50.5, 28.5, 2.2, 2.0, 3)
	_ellipse_type(types, n, 28.5, 50.5, 5.5, 5.0, T_VOLCANIC)
	_ellipse_h(heights, n, 28.5, 50.5, 5.5, 5.0, 1)
	_ellipse_h(heights, n, 28.5, 50.5, 3.0, 2.7, 2)

	# ── 碎石 dune：footprint 涂碎石，再抬高——侧壁应为「碎石壁」而非火山岩壁（验证 type-aware）──
	_ellipse_type(types, n, 60.5, 58.5, 5.0, 4.5, T_RUBBLE)
	_ellipse_h(heights, n, 60.5, 58.5, 5.0, 4.5, 1)
	_ellipse_h(heights, n, 60.5, 58.5, 2.8, 2.5, 2)

	# ── 泥沼水潭：中央泥沼盆地一汪浊水（浅水外圈 + 深水中心）──
	_ellipse_type(types, n, 37.5, 40.5, 4.5, 4.0, T_WATER)
	for i in range(count):
		if types[i] == T_WATER:
			depths[i] = 1
			heights[i] = 0
	_ellipse_depth(depths, types, n, 37.5, 40.5, 2.5, 2.2, 2)

	# ── 组装物品层（侏罗纪切片无散布物品）+ 灌回 TerrainMap 自产自销校验 ──
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
	assert(r["ok"], "侏罗纪地貌自产自销必须可载入: %s" % r.get("error", ""))
	var composed: Dictionary = COMPOSE.compose("jurassic")
	TerrainMap.reset() # 不给同进程后续使用者留侏罗纪地形
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
