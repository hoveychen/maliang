extends SceneTree
## TerrainMap 确定性地形数据的独立测试。
## 运行: godot --headless --path . --script res://test/test_terrain_map.gd

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES

	# 全图不变量：类型合法、高度 0..MAX、水面必为高度 0 且四邻高度 0（岸边平地）、
	# 深度只在水面非零（水 1..MAX_DEPTH，陆地恒 0）
	var bad_type := 0
	var bad_h := 0
	var bad_water := 0
	var bad_depth := 0
	for z in range(n):
		for x in range(n):
			var t := Vector2i(x, z)
			var ty := TerrainMap.tile_type(t)
			var h := TerrainMap.tile_height(t)
			var dep := TerrainMap.tile_depth(t)
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
				if dep < 1 or dep > TerrainMap.MAX_DEPTH:
					bad_depth += 1
			elif dep != 0:
				bad_depth += 1
	fails += _check("types valid", bad_type, 0)
	fails += _check("heights in range", bad_h, 0)
	fails += _check("water flat & flat shore", bad_water, 0)
	fails += _check("depth only on water", bad_depth, 0)

	# 水深样本：池塘中心深水 2 级、池塘边缘/溪流/沼泽浅水 1 级、涉水石滩（路）深度 0；
	# 湖床有效级 = 高度 - 深度（池塘中心 -2）
	fails += _check("pond center deep", TerrainMap.tile_depth(Vector2i(24, 24)), 2)
	fails += _check("pond edge shallow", TerrainMap.tile_depth(Vector2i(20, 24)), 1)
	fails += _check("stream shallow", TerrainMap.tile_depth(Vector2i(27, 17)), 1)
	fails += _check("marsh shallow", TerrainMap.tile_depth(Vector2i(13, 50)), 1)
	fails += _check("ford no depth", TerrainMap.tile_depth(Vector2i(21, 37)), 0)
	fails += _check("pond floor level", TerrainMap.tile_floor_level(Vector2i(24, 24)), -2)

	# 已知样本点（与 terrain_map.gd 的 _paint 布局对应）
	fails += _check("plaza is path", TerrainMap.tile_type(Vector2i(37, 37)), TerrainMap.T_PATH)
	fails += _check("north road is path", TerrainMap.tile_type(Vector2i(37, 20)), TerrainMap.T_PATH)
	fails += _check("market square is path", TerrainMap.tile_type(Vector2i(37, 62)), TerrainMap.T_PATH)
	fails += _check("pond is water", TerrainMap.tile_type(Vector2i(24, 24)), TerrainMap.T_WATER)
	fails += _check("spring is water", TerrainMap.tile_type(Vector2i(29, 13)), TerrainMap.T_WATER)
	fails += _check("marsh pool is water", TerrainMap.tile_type(Vector2i(13, 50)), TerrainMap.T_WATER)
	fails += _check("mountain peak h8", TerrainMap.tile_height(Vector2i(37, 6)), 8)
	fails += _check("mountain mid h5", TerrainMap.tile_height(Vector2i(33, 8)), 5)
	fails += _check("shoulder hill h1", TerrainMap.tile_height(Vector2i(51, 8)), 1)
	fails += _check("shoulder hill top h3", TerrainMap.tile_height(Vector2i(56, 8)), 3)
	fails += _check("lookout hill h1", TerrainMap.tile_height(Vector2i(55, 58)), 1)
	fails += _check("far corner grass", TerrainMap.tile_type(Vector2i(2, 70)), TerrainMap.T_GRASS)
	fails += _check("far corner flat", TerrainMap.tile_height(Vector2i(2, 70)), 0)

	# 涉水石滩：西辐路压过出水口——路面处是路，路两侧溪水延续
	fails += _check("ford is path", TerrainMap.tile_type(Vector2i(21, 37)), TerrainMap.T_PATH)
	fails += _check("stream above ford", TerrainMap.tile_type(Vector2i(21, 36)), TerrainMap.T_WATER)
	fails += _check("stream below ford", TerrainMap.tile_type(Vector2i(20, 39)), TerrainMap.T_WATER)

	# 草甸小径穿过环面接缝：南草甸段、接缝另一头的出生空地段都是路
	fails += _check("meadow trail mid", TerrainMap.tile_type(Vector2i(22, 70)), TerrainMap.T_PATH)
	fails += _check("meadow trail past seam", TerrainMap.tile_type(Vector2i(2, 7)), TerrainMap.T_PATH)

	# 风车平台：瞭望丘顶 3×3 全部 h3 草地（放得下风车）
	var bad_plat := 0
	for z in range(53, 56):
		for x in range(58, 61):
			if TerrainMap.tile_height(Vector2i(x, z)) != 3 or TerrainMap.tile_type(Vector2i(x, z)) != TerrainMap.T_GRASS:
				bad_plat += 1
	fails += _check("windmill platform flat h3", bad_plat, 0)

	# 全图最高点 = 主峰 8 级（丘陵都更矮）
	var hmax := 0
	for z in range(n):
		for x in range(n):
			hmax = maxi(hmax, TerrainMap.tile_height(Vector2i(x, z)))
	fails += _check("max height is 8", hmax, 8)

	# 环面 wrap：越界索引等价
	fails += _check("wrap type", TerrainMap.tile_type(Vector2i(37 + n, 37 - n)), TerrainMap.tile_type(Vector2i(37, 37)))
	fails += _check("wrap height", TerrainMap.tile_height(Vector2i(37 - n, 7 + n)), TerrainMap.tile_height(Vector2i(37, 7)))

	# tile_center 与 to_tile 互逆
	var c := TerrainMap.tile_center(Vector2i(10, 20))
	fails += _check("center roundtrip x", float(WorldGrid.to_tile(c).x), 10.0)
	fails += _check("center roundtrip z", float(WorldGrid.to_tile(c).y), 20.0)

	# 主峰西山脊缓坡可逐级爬：沿 z=6 行从西侧山脚到峰顶，高度单调不减且首尾贯通
	# （南北向允许多级陡崖——能否攀爬是移动规则的事，不是地形不变量）
	var prev := 0
	var monotonic := true
	for x in range(26, 38):
		var hx := TerrainMap.tile_height(Vector2i(x, 6))
		if hx < prev:
			monotonic = false
		prev = hx
	fails += _check("west ridge climbs to peak", 1 if (monotonic and prev == 8) else 0, 1)

	# 连通性不变量：从中央广场出发按移动规则（8 向、对角不穿角）BFS，
	# 每一块非水 tile 都可达——保证雕出来的世界没有走不到的死区。
	fails += _check("all land reachable from plaza", _unreachable_land(Vector2i(37, 37)), 0)

	if fails == 0:
		print("terrain_map tests PASS")
	else:
		printerr("terrain_map tests FAILED: %d" % fails)
	quit(fails)

## 从 start 按 can_step 做 8 向 BFS（对角要求两正交邻居也可走，防穿角），
## 返回不可达的非水 tile 数。
func _unreachable_land(start: Vector2i) -> int:
	var n := WorldGrid.GRID_TILES
	var seen := PackedByteArray()
	seen.resize(n * n)
	var queue: Array[Vector2i] = [start]
	seen[start.y * n + start.x] = 1
	var head := 0
	while head < queue.size():
		var t := queue[head]
		head += 1
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var q := Vector2i(posmod(t.x + dx, n), posmod(t.y + dz, n))
				if seen[q.y * n + q.x] == 1 or not TerrainMap.can_step(t, q):
					continue
				if dx != 0 and dz != 0:  # 对角：两正交邻居都可走才允许
					if not TerrainMap.can_step(t, Vector2i(posmod(t.x + dx, n), t.y)):
						continue
					if not TerrainMap.can_step(t, Vector2i(t.x, posmod(t.y + dz, n))):
						continue
				seen[q.y * n + q.x] = 1
				queue.append(q)
	var missed := 0
	for z in range(n):
		for x in range(n):
			if seen[z * n + x] == 0 and TerrainMap.tile_type(Vector2i(x, z)) != TerrainMap.T_WATER:
				missed += 1
	return missed

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT:
		if is_equal_approx(got, want):
			return 0
	elif got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
