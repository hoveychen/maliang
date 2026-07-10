extends SceneTree
## 程序化生成第二张地图「森林」并导出 .mltr（+ POI json），供 POST /admin/scenes 入库。
## 森林地形本身：林地草铺底 + 一条蜿蜒小河（浅水，一处深潭）+ 几处高地空地（knoll，可缓坡走上去）。
## 树木不进地形（tile 只有草/路/水）——森林郁闭林冠由客户端 chunk_manager._deco_kind_forest 在
## scene_id=forest 时铺满树表达；河岸苇、高地留白也都在那里。地形字节只负责草/水/高度骨架。
##
## 用法：godot --headless --path . --script res://tools/export_forest.gd -- --out forest.mltr
## 格式见 server/src/terrain.ts / tools/export_terrain.gd（三处必须同步）。

const MAGIC := "MLTR"
const VERSION := 1
const HEADER_BYTES := 11
const T_GRASS := 0
const T_WATER := 2

func _init() -> void:
	var out_path := _arg("--out", "forest.mltr")
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

## 森林 POI：给意图 LLM 的地名（小河深潭 / 林间空地）。trigger 目前客户端无专属台词，仅供归一。
static func build_poi_json() -> Array:
	return [
		{ "tile": [41, 33], "radius": 5.0, "trigger": "poi_forest_pond", "name": "小河深潭", "aliases": ["深潭", "小河", "河边"] },
		{ "tile": [20, 18], "radius": 5.0, "trigger": "poi_forest_clearing", "name": "林间空地", "aliases": ["空地", "草地", "林中空地"] },
		{ "tile": [55, 30], "radius": 5.0, "trigger": "poi_forest_knoll", "name": "小山丘", "aliases": ["山丘", "高地", "土坡"] },
	]

## 森林侧传送点：林间空地（20,18）中央，走进半径就穿回村庄西南小树林（18,52）。
## radius 单位是世界坐标（TILE_SIZE=2.0），3.0 ≈ 1.5 格：玩家还没踩到中心就已触发。
## 与 export_terrain.gd 的 build_portal_json() 必须互指（test_portal.gd 对拍两边）。
static func build_portal_json() -> Array:
	return [
		{ "tile": [20, 18], "radius": 3.0, "toScene": "village", "toTile": [18, 52] },
	]

## 构建森林 .mltr 字节流。抽成静态供回测直接调用（test_forest_scene.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)   # 清零 = 全草地
	var heights := PackedByteArray()
	heights.resize(count) # 清零 = 高度 0
	var depths := PackedByteArray()
	depths.resize(count)  # 清零 = 无水深

	# ── 高地空地（knoll）：几处同心椭圆缓坡（每环 +1 级可逐级走上去），顶面留白便于活动 ──
	# 与小河/深潭错开，避免抬高的水面。
	_ellipse_h(heights, n, 20.5, 18.5, 6.5, 5.5, 1)
	_ellipse_h(heights, n, 20.5, 18.5, 3.8, 3.2, 2)
	_ellipse_h(heights, n, 55.5, 30.5, 5.5, 4.8, 1)
	_ellipse_h(heights, n, 40.5, 60.5, 6.0, 5.0, 1)
	_ellipse_h(heights, n, 40.5, 60.5, 3.2, 2.6, 2)

	# ── 小河：自北蜿蜒到南穿过整张地图（浅水）；折线顶点取 tile 中心保证顶点 tile 必为水 ──
	_polyline_water(types, n, [
		Vector2(48.5, 2.5), Vector2(45.5, 12.5), Vector2(40.5, 22.5),
		Vector2(43.5, 33.5), Vector2(38.5, 46.5), Vector2(41.5, 58.5), Vector2(36.5, 72.5)], 1.2)
	# 河中一处深潭
	_ellipse_type(types, n, 41.5, 33.5, 3.8, 3.2, T_WATER)

	# ── 水深：所有水面基础浅水 1；深潭中心同心加深到 2 ──
	# 水面一律压回高度 0（河不该被 knoll 抬起来）。
	for i in range(count):
		if types[i] == T_WATER:
			depths[i] = 1
			heights[i] = 0
	_ellipse_depth(depths, types, n, 41.5, 33.5, 2.4, 2.0, 2)

	# ── 组装（行主序，与服务端 _idx = y*W + x 一致）──
	var buf := PackedByteArray()
	buf.resize(HEADER_BYTES + 3 * count)
	for i in range(4):
		buf[i] = MAGIC.unicode_at(i)
	buf[4] = VERSION
	buf[5] = n
	buf[6] = n
	buf.encode_float(7, WorldGrid.TILE_SIZE)
	for i in range(count):
		buf[HEADER_BYTES + i] = types[i]
		buf[HEADER_BYTES + count + i] = heights[i]
		buf[HEADER_BYTES + 2 * count + i] = depths[i]
	return buf

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

## 沿折线涂水：tile 中心到任一线段距离 ≤ radius（tile 单位）者涂水。顶点可越界，_idx 环面 wrap。
static func _polyline_water(types: PackedByteArray, n: int, pts: Array, radius: float) -> void:
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		for z in range(int(minf(a.y, b.y) - radius) - 1, int(maxf(a.y, b.y) + radius) + 2):
			for x in range(int(minf(a.x, b.x) - radius) - 1, int(maxf(a.x, b.x) + radius) + 2):
				var c := Vector2(float(x) + 0.5, float(z) + 0.5)
				var q := Geometry2D.get_closest_point_to_segment(c, a, b)
				if c.distance_to(q) <= radius:
					types[_idx(n, x, z)] = T_WATER

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
