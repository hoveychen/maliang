extends SceneTree
## TerrainMap 确定性地形数据的独立测试。
## 运行: godot --headless --path . --script res://test/test_terrain_map.gd

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES

	# 全图不变量：类型合法、高度 0..MAX、水面必为高度 0 且四邻高度 0（岸边平地）
	var bad_type := 0
	var bad_h := 0
	var bad_water := 0
	for z in range(n):
		for x in range(n):
			var t := Vector2i(x, z)
			var ty := TerrainMap.tile_type(t)
			var h := TerrainMap.tile_height(t)
			if ty < 0 or ty > TerrainMap.T_WATER:
				bad_type += 1
			if h < 0 or h > TerrainMap.MAX_HEIGHT:
				bad_h += 1
			if ty == TerrainMap.T_WATER:
				if h != 0:
					bad_water += 1
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if TerrainMap.tile_height(t + d) != 0:
						bad_water += 1
	fails += _check("types valid", bad_type, 0)
	fails += _check("heights in range", bad_h, 0)
	fails += _check("water flat & flat shore", bad_water, 0)

	# 已知样本点（与 terrain_map.gd 的 _paint 布局对应）
	fails += _check("plaza is path", TerrainMap.tile_type(Vector2i(37, 37)), TerrainMap.T_PATH)
	fails += _check("west road is path", TerrainMap.tile_type(Vector2i(12, 30)), TerrainMap.T_PATH)
	fails += _check("pond is water", TerrainMap.tile_type(Vector2i(24, 24)), TerrainMap.T_WATER)
	fails += _check("knoll is h2", TerrainMap.tile_height(Vector2i(37, 7)), 2)
	fails += _check("plateau is h1", TerrainMap.tile_height(Vector2i(33, 8)), 1)
	fails += _check("far corner grass", TerrainMap.tile_type(Vector2i(2, 70)), TerrainMap.T_GRASS)
	fails += _check("far corner flat", TerrainMap.tile_height(Vector2i(2, 70)), 0)

	# 环面 wrap：越界索引等价
	fails += _check("wrap type", TerrainMap.tile_type(Vector2i(37 + n, 37 - n)), TerrainMap.tile_type(Vector2i(37, 37)))
	fails += _check("wrap height", TerrainMap.tile_height(Vector2i(37 - n, 7 + n)), TerrainMap.tile_height(Vector2i(37, 7)))

	# tile_center 与 to_tile 互逆
	var c := TerrainMap.tile_center(Vector2i(10, 20))
	fails += _check("center roundtrip x", float(WorldGrid.to_tile(c).x), 10.0)
	fails += _check("center roundtrip z", float(WorldGrid.to_tile(c).y), 20.0)

	# 高度台阶不变量：相邻 tile 高度差 ≤1（保证 P6 侧壁只需一级悬崖拼块）
	var bad_step := 0
	for z in range(n):
		for x in range(n):
			var h0 := TerrainMap.tile_height(Vector2i(x, z))
			if absi(h0 - TerrainMap.tile_height(Vector2i(x + 1, z))) > 1:
				bad_step += 1
			if absi(h0 - TerrainMap.tile_height(Vector2i(x, z + 1))) > 1:
				bad_step += 1
	fails += _check("height steps <= 1", bad_step, 0)

	if fails == 0:
		print("terrain_map tests PASS")
	else:
		printerr("terrain_map tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT:
		if is_equal_approx(got, want):
			return 0
	elif got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
