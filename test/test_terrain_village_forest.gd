extends SceneTree
## 第一季合并大场景（village_forest，100 格）导出/载入回归（s1-hood P2）。
## - 网格自描述为 100（gridtiles-presets 地基：地形头是唯一权威）
## - 地貌三平面与 _paint_village_forest() 逐字节一致
## - 客户端 load_from_bytes 可载入、grid 自动 configure 到 100、不崩
## - 分区 tile 落对：广场/小径/跑道 = 路，池塘 = 水，两处林间空地 = 开阔草地
## - 地标落位：村庄水井 + 外婆家小屋
## - 森林深处比村庄近端树更密（散布分区规则生效）
## - 确定性：连续两次导出逐字节相同
## 运行: godot --headless --path . --script res://test/test_terrain_village_forest.gd
## 设计见 docs/s1-merged-scene-layout.md。

const EX := preload("res://tools/export_terrain.gd")
const HEADER := 11

func _init() -> void:
	var fails := 0
	var buf := EX.build_terrain_bytes("village_forest")
	var n := WorldGrid.GRID_TILES
	var count := n * n

	# ── 网格自描述为 100 ──────────────────────────────────────────────────
	fails += _check("build 后 GRID_TILES = 100", n, 100)
	fails += _check("magic", buf.slice(0, 4).get_string_from_ascii(), "MLTR")
	fails += _check("version = v2", buf[4], TerrainMap.MLTR_VERSION)
	fails += _check("gridW = 100", buf[5], 100)
	fails += _check("gridH = 100", buf[6], 100)
	fails += _check("总长 ≥ 11 + 9×N", buf.size() >= HEADER + 9 * count + 1, true)

	# ── 地貌三平面逐字节对拍 _paint_village_forest() ────────────────────────
	WorldGrid.configure(100)
	TerrainMap.reset_scene("village_forest")
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

	# ── 客户端解析器可载入，grid 自动 configure，物品层可读 ──────────────────
	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(buf)
	fails += _check("客户端载入 ok", r["ok"], true)
	fails += _check("载入后 GRID_TILES = 100", WorldGrid.GRID_TILES, 100)
	fails += _check("palette 非空", TerrainMap.palette().size() > 0, true)

	# ── 分区 tile 落对（形状讲故事的骨架）──────────────────────────────────
	fails += _check("广场 = 路", TerrainMap.tile_type(Vector2i(20, 16)), TerrainMap.T_PATH)
	fails += _check("穿林小径 = 路", TerrainMap.tile_type(Vector2i(40, 50)), TerrainMap.T_PATH)
	fails += _check("右缘跑道 = 路", TerrainMap.tile_type(Vector2i(88, 50)), TerrainMap.T_PATH)
	fails += _check("村东池塘 = 水", TerrainMap.tile_type(Vector2i(34, 9)), TerrainMap.T_WATER)
	# 小径终点 (66,64) 本身是路（路通进院子）；空地本体取偏离路的一格验开阔
	fails += _check("外婆家空地 = 草", TerrainMap.tile_type(Vector2i(63, 66)), TerrainMap.T_GRASS)
	fails += _check("七矮人空地 = 草", TerrainMap.tile_type(Vector2i(30, 86)), TerrainMap.T_GRASS)
	fails += _check("出生角 = 草（开阔）", TerrainMap.tile_type(Vector2i(2, 2)), TerrainMap.T_GRASS)

	# ── 地标落位：水井坐镇广场、外婆家小屋在小径尽头 ────────────────────────
	fails += _check("水井坐镇广场", TerrainMap.tile_item_id(Vector2i(20, 16)), "well")
	# 外婆家小屋 search=2，允许被螺旋挪位——按 id 在 (66,60) 邻域计数存在
	var grandma_hut := 0
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			if TerrainMap.tile_item_id(Vector2i(66 + dx, 60 + dy)) == "house_2":
				grandma_hut += 1
	fails += _check("外婆家小屋在小径尽头", grandma_hut >= 1, true)

	# ── 散布：森林深处比村庄近端树更密 ────────────────────────────────────
	var trees_village := _count_trees(0, 38)     # 村庄近端带
	var trees_forest := _count_trees(60, 100)    # 森林深处带
	fails += _check("森林带有大量树", trees_forest > 200, true)
	fails += _check("森林带树多于村庄带", trees_forest > trees_village * 2, true)

	# ── 服务端解码器不变量：类型全合法、非水格水深为 0 ──────────────────────
	var bad := 0
	for i in range(count):
		var ty := buf[HEADER + i]
		if ty != TerrainMap.T_GRASS and ty != TerrainMap.T_PATH and ty != TerrainMap.T_WATER:
			bad += 1
		if ty != TerrainMap.T_WATER and buf[HEADER + 2 * count + i] != 0:
			bad += 1
	fails += _check("类型合法且非水格水深为 0", bad, 0)

	# ── 确定性：连续两次导出逐字节相同 ──────────────────────────────────────
	fails += _check("两次导出字节一致（组装是纯函数）", buf == EX.build_terrain_bytes("village_forest"), true)

	TerrainMap.reset()
	print("test_terrain_village_forest: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## 统计 [z0,z1) 行带内树物品数（树 id 前缀 tree_）。
func _count_trees(z0: int, z1: int) -> int:
	var c := 0
	for y in range(z0, z1):
		for x in range(WorldGrid.GRID_TILES):
			if TerrainMap.tile_item_id(Vector2i(x, y)).begins_with("tree_"):
				c += 1
	return c

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT and typeof(want) == TYPE_FLOAT:
		if is_equal_approx(got, want):
			return 0
	elif got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
