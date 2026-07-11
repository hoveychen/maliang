extends SceneTree
## 地形导出（scene-items P2 起为 .mltr v2）：
## - 地貌三平面必须与 TerrainMap._paint() 逐字节一致（上线地图与本地一致的验收标准）
## - 物品层/palette/边缘平面结构合法：客户端解析器可载入、边缘一期全零
## - 地标锚点落位正确（水井/风车/8 民居按表落位，泉石钉死原位）
## - 确定性：连续两次导出逐字节相同
## 运行: godot --headless --path . --script res://test/test_terrain_export.gd

const EX := preload("res://tools/export_terrain.gd")
const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER := 11

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var buf := EX.build_terrain_bytes()

	# ── 头部 ──────────────────────────────────────────────────────────────
	fails += _check("总长 ≥ 11 + 9×N + palette count 字节", buf.size() >= HEADER + 9 * count + 1, true)
	fails += _check("magic", buf.slice(0, 4).get_string_from_ascii(), "MLTR")
	fails += _check("version = v2", buf[4], TerrainMap.MLTR_VERSION)
	fails += _check("gridW", buf[5], n)
	fails += _check("gridH", buf[6], n)
	fails += _check("tileSize(f32 LE)", buf.decode_float(7), WorldGrid.TILE_SIZE)

	# ── 地貌三平面逐字节对拍 _paint()（这是本测试的核心）────────────────────
	TerrainMap.reset()
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

	# ── 边缘平面一期恒 0（数据位）───────────────────────────────────────────
	var edge_nonzero := 0
	for i in range(5 * count, 9 * count):
		if buf[HEADER + i] != 0:
			edge_nonzero += 1
	fails += _check("边缘平面全零", edge_nonzero, 0)

	# ── 客户端解析器可载入，物品层可读 ───────────────────────────────────────
	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(buf)
	fails += _check("客户端载入 ok", r["ok"], true)
	fails += _check("含物品层 → 相对 _paint changed=true", r["changed"], true)
	fails += _check("palette 非空", TerrainMap.palette().size() > 0, true)

	# 地标锚点：水井/风车/民居按表落位（锚点无冲突，不该被螺旋挪走）
	fails += _check("水井坐镇广场", TerrainMap.tile_item_id(Vector2i(37, 37)), "well")
	fails += _check("风车立瞭望丘", TerrainMap.tile_item_id(Vector2i(59, 54)), "windmill")
	for lm in [[31, 31, "house_0"], [44, 31, "house_1"], [31, 44, "house_2"], [44, 44, "house_3"],
			[27, 40, "house_1"], [47, 35, "house_0"], [34, 58, "house_2"], [33, 23, "house_3"]]:
		fails += _check("民居@(%d,%d)" % [lm[0], lm[1]], TerrainMap.tile_item_id(Vector2i(lm[0], lm[1])), lm[2])
	fails += _check("泉石甲钉死原位", TerrainMap.tile_item_id(Vector2i(30, 12)), "rock_2")
	fails += _check("泉石乙钉死原位", TerrainMap.tile_item_id(Vector2i(28, 12)), "rock_0")
	fails += _check("风车朝向 180°", absf(TerrainMap.tile_item_yaw_deg(Vector2i(59, 54)) - 180.0) < 1.0, true)

	# SDF 物件每个恰好出现一次（锚点可能被螺旋挪位，按 id 计数）
	var sdf_counts := {}
	for y in range(n):
		for x in range(n):
			var id := TerrainMap.tile_item_id(Vector2i(x, y))
			if id in ["walking_hut", "hop_mailbox", "nodding_flower", "pinwheel", "paper_note", "crayon", "village_sign"]:
				sdf_counts[id] = sdf_counts.get(id, 0) + 1
	for sp in COMPOSE.SDF_PROPS:
		fails += _check("SDF 物件 %s 恰一个" % sp["item"], sdf_counts.get(sp["item"], 0), 1)

	# 散布密度：村庄应有大量散布物（回归防呆，别导出个空物品层）
	var scatter := 0
	for i in range(count):
		if buf[HEADER + 3 * count + i] != 0:
			scatter += 1
	fails += _check("物品总数 > 500（含散布）", scatter > 500, true)

	# ── 服务端解码器的不变量：非水格水深必须为 0、类型全合法 ────────────────
	var bad := 0
	for i in range(count):
		var ty := buf[HEADER + i]
		if ty != TerrainMap.T_GRASS and ty != TerrainMap.T_PATH and ty != TerrainMap.T_WATER:
			bad += 1
		if ty != TerrainMap.T_WATER and buf[HEADER + 2 * count + i] != 0:
			bad += 1
	fails += _check("类型合法且非水格水深为 0", bad, 0)

	# ── 确定性：连续两次导出必须逐字节相同 ──────────────────────────────
	fails += _check("两次导出字节一致（组装是纯函数）", buf == EX.build_terrain_bytes(), true)

	TerrainMap.reset()
	print("test_terrain_export: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT and typeof(want) == TYPE_FLOAT:
		if is_equal_approx(got, want):
			return 0
	elif got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
