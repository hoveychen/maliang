extends SceneTree
## 草地装饰散布（Pokopia 化 P6）契约：
## ① pick 只在草 tile 出装饰、确定性（同 tile 两次同结果）、姿态在旋钮范围内；
## ② 三种 mesh 建得出来、顶点预算封顶（老 Mali 顶点吞吐是瓶颈，散布不许悄悄长胖）；
## ③ 大盘密度在预期带宽（旋钮改了测试跟着改——防手滑把 0.14 敲成 1.4 铺满全图）；
## ④ 花只在花畦成片出（畦外草 tile 永远不出花）。
## 运行: godot --headless --script res://test/test_terrain_deco.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

var fails := 0

func _init() -> void:
	_setup_terrain()
	_test_eligibility_and_determinism()
	_test_pose_ranges()
	_test_meshes_budget()
	_test_density_band()
	_test_flower_patchiness()
	TerrainMap.reset()
	print("test_terrain_deco: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## 全图铺草（reset 后清零 = 全草地），再 patch 出几块异类地表做阴性样本
func _setup_terrain() -> void:
	TerrainMap.reset()
	var p := TerrainMap.apply_patch({ "edits": [
		{ "x": 3, "y": 3, "t": TerrainMap.T_PATH },
		{ "x": 4, "y": 3, "t": TerrainMap.T_WATER, "d": 1 },
		{ "x": 5, "y": 3, "t": TerrainMap.T_SAND },
	] })
	_check("阴性样本 patch 应用 ok", p["ok"], true)

func _test_eligibility_and_determinism() -> void:
	_check("路 tile 不长", TerrainDeco.pick(Vector2i(3, 3)).is_empty(), true)
	_check("水 tile 不长", TerrainDeco.pick(Vector2i(4, 3)).is_empty(), true)
	_check("沙 tile 不长", TerrainDeco.pick(Vector2i(5, 3)).is_empty(), true)
	var n := WorldGrid.GRID_TILES
	var same := true
	var any := false
	for z in range(n):
		for x in range(n):
			var gt := Vector2i(x, z)
			var a := TerrainDeco.pick(gt)
			if a != TerrainDeco.pick(gt):
				same = false
			if not a.is_empty():
				any = true
	_check("同 tile 两次决策一致（确定性）", same, true)
	_check("草地世界长得出装饰", any, true)

func _test_pose_ranges() -> void:
	var n := WorldGrid.GRID_TILES
	var ok := true
	for z in range(n):
		for x in range(n):
			var d := TerrainDeco.pick(Vector2i(x, z))
			if d.is_empty():
				continue
			var off: Vector2 = d["off"]
			# Vector2 是 float32：±0.6 存储成 0.60000002，容 1e-4 存储噪声
			if absf(off.x) > TerrainDeco.OFFSET_MAX + 1e-4 or absf(off.y) > TerrainDeco.OFFSET_MAX + 1e-4:
				ok = false
			if d["scale"] < TerrainDeco.SCALE_MIN or d["scale"] > TerrainDeco.SCALE_MAX:
				ok = false
			if not (d["key"] in TerrainDeco.KEYS):
				ok = false
	_check("抖动/缩放/键全在旋钮范围内", ok, true)

func _test_meshes_budget() -> void:
	for key in TerrainDeco.KEYS:
		var m := TerrainDeco.mesh(key)
		_check("%s mesh 建得出来" % key, m != null and m.get_surface_count() > 0, true)
		if m == null or m.get_surface_count() == 0:
			continue
		var vcount: int = (m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		# 预算含叶片双面（内外面各一层）；再要长胖先过 benchmark 再改这里
		_check("%s 顶点预算 ≤ 300（实际 %d）" % [key, vcount], vcount <= 300, true)
		var aabb := m.get_aabb()
		_check("%s 高度 ≤ 1m（贴地装饰，实际 %.2f）" % [key, aabb.size.y], aabb.size.y <= 1.0, true)
		_check("%s 底边贴地（AABB 底 ≥ -0.05，实际 %.2f）" % [key, aabb.position.y], aabb.position.y >= -0.05, true)

## 全草世界的密度大盘：出装饰率应落在旋钮推算带宽内（花畦让局部超出，容差放宽）
func _test_density_band() -> void:
	var n := WorldGrid.GRID_TILES
	var counts := { "deco_tuft_a": 0, "deco_tuft_b": 0, "deco_flower": 0, "": 0 }
	var grass := 0
	for z in range(n):
		for x in range(n):
			var gt := Vector2i(x, z)
			if TerrainMap.tile_type(gt) != TerrainMap.T_GRASS:
				continue
			grass += 1
			var d := TerrainDeco.pick(gt)
			counts[d.get("key", "")] += 1
	var occupied := float(grass - counts[""]) / float(grass)
	# 基线出率 = 大簇 0.14 + 小芽 0.30 ≈ 0.44；花畦替换部分再±些许，带宽取 [0.30, 0.60]
	_check("总出率在带宽 [0.30,0.60]（实际 %.2f）" % occupied, occupied > 0.30 and occupied < 0.60, true)
	_check("三种都出现：大簇", counts["deco_tuft_a"] > 0, true)
	_check("三种都出现：小芽", counts["deco_tuft_b"] > 0, true)
	_check("三种都出现：花丛", counts["deco_flower"] > 0, true)
	_check("小芽比大簇常见", counts["deco_tuft_b"] > counts["deco_tuft_a"], true)

## 花只在花畦：畦外 tile 的 pick 永远不是花
func _test_flower_patchiness() -> void:
	var n := WorldGrid.GRID_TILES
	var leak := 0
	for z in range(n):
		for x in range(n):
			var gt := Vector2i(x, z)
			var d := TerrainDeco.pick(gt)
			if d.get("key", "") == "deco_flower" and not TerrainDeco._in_flower_patch(gt):
				leak += 1
	_check("花不漏出花畦（漏 %d 株）" % leak, leak, 0)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok ", what)
	else:
		fails += 1
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
