extends SceneTree
## 室内场景（home_interior）地形导出/载入回归（室内重做 P2）。
## 室内重做后地貌简化成纯平地板——房间的墙/地几何由客户端 RoomStage 真几何渲染（不再抬地形块
## 假装墙、掏实心躲露地）。故本测试断言：
## - 网格自描述为 50（预设，服务端 PRESET_GRIDS 已含 50）
## - 全格木地板、高度 0、水深 0（纯平地板）
## - 地貌逐字节与 _paint_home_interior() 一致
## - 客户端 load_from_bytes 可载入、grid 自动 configure 到 50
## - 空房：无 POI / 无住户 / 无物品层
## - 类型全合法、非水格水深 0（服务端解码不变量）
## - 确定性：连续两次导出逐字节相同
## 运行: godot --headless --path . --script res://test/test_home_interior.gd
const EX := preload("res://tools/export_terrain.gd")
const HEADER := 11

func _init() -> void:
	var fails := 0
	var buf := EX.build_terrain_bytes("home_interior")
	var n := WorldGrid.GRID_TILES
	var count := n * n

	# ── 网格自描述为 50 ────────────────────────────────────────────────────
	fails += _check("build 后 GRID_TILES = 50", n, 50)
	fails += _check("magic", buf.slice(0, 4).get_string_from_ascii(), "MLTR")
	fails += _check("version = v2", buf[4], TerrainMap.MLTR_VERSION)
	fails += _check("gridW = 50", buf[5], 50)
	fails += _check("gridH = 50", buf[6], 50)
	fails += _check("总长 ≥ 11 + 9×N", buf.size() >= HEADER + 9 * count + 1, true)

	# ── 地貌三平面逐字节对拍 _paint_home_interior() ─────────────────────────
	WorldGrid.configure(50)
	TerrainMap.reset_scene("home_interior")
	var mismatch := 0
	for y in range(n):
		for x in range(n):
			var t := Vector2i(x, y)
			var i := y * n + x
			if buf[HEADER + i] != TerrainMap.tile_type(t):
				mismatch += 1
			if buf[HEADER + count + i] != TerrainMap.tile_height(t):
				mismatch += 1
			if buf[HEADER + 2 * count + i] != TerrainMap.tile_depth(t):
				mismatch += 1
	fails += _check("地貌三平面零失配", mismatch, 0)

	# ── 客户端解析器可载入，grid 自动 configure ─────────────────────────────
	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(buf)
	fails += _check("客户端载入 ok", r["ok"], true)
	fails += _check("载入后 GRID_TILES = 50", WorldGrid.GRID_TILES, 50)

	# ── 纯平地板：全格木地板、高度 0（无抬高墙、无掏实心）──────────────────
	var non_floor := 0
	var non_flat := 0
	for y in range(n):
		for x in range(n):
			var t := Vector2i(x, y)
			if TerrainMap.tile_type(t) != TerrainMap.T_WOOD_FLOOR:
				non_floor += 1
			if TerrainMap.tile_height(t) != 0:
				non_flat += 1
	fails += _check("全格木地板（无墙）", non_floor, 0)
	fails += _check("全格高度 0（无抬高墙）", non_flat, 0)
	fails += _check("房间中心 = 木地板", TerrainMap.tile_type(Vector2i(24, 24)), TerrainMap.T_WOOD_FLOOR)
	fails += _check("旧墙位现在也是地板（不再有墙）", TerrainMap.tile_type(Vector2i(16, 16)), TerrainMap.T_WOOD_FLOOR)

	# ── 空房：无 POI、无住户、无物品 ──────────────────────────────────────
	fails += _check("home_interior 无 POI", EX.build_poi_json("home_interior").size(), 0)
	fails += _check("home_interior 无住户", EX.build_homes_json("home_interior").size(), 0)
	fails += _check("物品层空（palette 为空）", TerrainMap.palette().size(), 0)

	# ── 服务端解码不变量：类型全合法、非水格水深为 0 ──────────────────────
	var bad := 0
	for i in range(count):
		var ty := buf[HEADER + i]
		if not TerrainMap.VALID_TYPES.has(ty):
			bad += 1
		if ty != TerrainMap.T_WATER and buf[HEADER + 2 * count + i] != 0:
			bad += 1
	fails += _check("类型合法且非水格水深为 0", bad, 0)

	# ── 确定性：连续两次导出逐字节相同 ─────────────────────────────────────
	fails += _check("两次导出字节一致（组装是纯函数）", buf == EX.build_terrain_bytes("home_interior"), true)

	TerrainMap.reset()
	print("test_home_interior: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT and typeof(want) == TYPE_FLOAT:
		if is_equal_approx(got, want):
			return 0
	elif got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
