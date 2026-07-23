extends SceneTree
## 全量纲化派生公式守护（tile-dimensional-system P1）：PackRegistry.fit_scale 把资产原始 AABB
## 等比缩放到「恰好填满 footprint(W×H tile) 的 fill 比例」。这是 node 类视觉缩放的唯一来源，
## 取代 pack.json 手调裸 scale。严格「视觉=碰撞」：footprint 即尺寸唯一真相。
##
## 只测纯函数（headless 非 editor 下内容包不挂载，raw_aabb 拿不到真实资产 AABB，故真实资产
## 的 fit 靠带窗截图眼验；派生公式本身在此锁死）。
## 运行: godot --headless --path . --script res://test/test_tile_dimensional.gd
##
## 前置事实：WorldGrid.TILE_SIZE 恒为 2.0（每 tile 2 米），fit 默认 0.9（留视觉缝）。

func _init() -> void:
	var fails := 0
	var tile := WorldGrid.TILE_SIZE
	fails += _check_f("TILE_SIZE 恒 2.0", tile, 2.0)

	# 方形资产填满 2×2 footprint：min(2*2/4, 2*2/4)=1.0 ×0.9。
	fails += _check_f("方形 4×4 填 2×2 → 0.9",
		PackRegistry.fit_scale(_ab(4, 3, 4), 2, 2), 0.9)

	# 单位立方填 1×1：min(2/1,2/1)=2.0 ×0.9=1.8。
	fails += _check_f("单位立方填 1×1 → 1.8",
		PackRegistry.fit_scale(_ab(1, 1, 1), 1, 1), 1.8)

	# 长方形床（资产宽2深4）填 1×2 footprint：min(1*2/2, 2*2/4)=1.0 ×0.9=0.9。非方形对齐。
	fails += _check_f("宽2深4 资产填 1×2 → 0.9",
		PackRegistry.fit_scale(_ab(2, 1, 4), 1, 2), 0.9)

	# 取 min 保证不溢出：细长资产（深4）填 1×1，受深轴限制 min(2/1, 2/4)=0.5 ×0.9=0.45。
	fails += _check_f("细长资产填 1×1 取 min 不溢出 → 0.45",
		PackRegistry.fit_scale(_ab(1, 1, 4), 1, 1), 0.45)

	# 城堡大件（原始 AABB 10×10）填 7×7：min(14/10,14/10)=1.4 ×0.9=1.26。地标名副其实占 7×7。
	fails += _check_f("城堡 10×10 资产填 7×7 → 1.26",
		PackRegistry.fit_scale(_ab(10, 20, 10), 7, 7), 1.26)

	# 无效 AABB（size 0，如资源未挂载）→ 降级 1.0，不崩、不除零。
	fails += _check_f("空 AABB 降级 → 1.0",
		PackRegistry.fit_scale(_ab(0, 0, 0), 3, 3), 1.0)

	# visual_tiles：视觉水平占格由 def 派生。缺省回落 footprint；显式 visualTiles 生效；下限 1。
	fails += _check_v("visual_tiles 缺省=footprint",
		PackRegistry.visual_tiles({"footprintW": 2, "footprintH": 3}), Vector2(2, 3))
	fails += _check_v("visual_tiles 显式 > footprint（树冠超地基）",
		PackRegistry.visual_tiles({"footprintW": 1, "footprintH": 1, "visualTilesW": 2, "visualTilesH": 2}), Vector2(2, 2))
	fails += _check_v("visual_tiles 空 def → 下限 1×1",
		PackRegistry.visual_tiles({}), Vector2(1, 1))

	# 视觉外延语义：visualTiles=2 的资产比 footprint=1 视觉更大（fit_scale 按 visualTiles 派生）。
	# 单位立方按 visual 2×2 填 → min(4/1,4/1)=4 ×0.9=3.6，是 footprint 1×1(=1.8) 的 2 倍。
	fails += _check_f("visualTiles 2×2 → 3.6（footprint 1×1 的两倍视觉）",
		PackRegistry.fit_scale(_ab(1, 1, 1), 2, 2), 3.6)

	# P4b：真实 emerald_castle baked mesh 的 SDF tile 计价（守 chunk_manager._spawn_static_sdf 缩放不回归）。
	# 原生水平 ~2.1 tile，footprint/visualTiles 7×7 → fit_scale 等比放大填满 → 视觉 ~6.3 tile 宽（fill0.9）、
	# 高按比例自然延伸 ~12.7 tile 的宏伟高塔（老板 2026-07-23 定「宏伟高塔·仅城堡+造物」）。装饰 1×1 SDF 不缩放。
	var castle_mesh := load("res://assets/sdf_props/baked/emerald_castle.res") as Mesh
	if castle_mesh != null:
		var cab: AABB = castle_mesh.get_aabb()
		var csc := PackRegistry.fit_scale(cab, 7, 7)
		var wtiles := cab.size.x * csc / WorldGrid.TILE_SIZE
		fails += _check_true("emerald_castle 填 7×7 → 视觉 ~6.3 tile 宽（宏伟高塔）", wtiles > 6.0 and wtiles < 6.6)
		# 装饰对照：1×1 footprint 的 sdf_res gate 关闭（visual_tiles=1×1，_spawn_static_sdf 不缩放）。
		var dvt := PackRegistry.visual_tiles({"footprintW": 1, "footprintH": 1})
		fails += _check_true("装饰 1×1 SDF gate 关闭（不 tile 计价）", not (dvt.x > 1.0 or dvt.y > 1.0))
	else:
		printerr("  ✗ emerald_castle baked mesh 缺失（P4b 无法验证）"); fails += 1

	print("test_tile_dimensional: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _ab(sx: float, sy: float, sz: float) -> AABB:
	return AABB(Vector3.ZERO, Vector3(sx, sy, sz))

func _check_f(name: String, got: float, want: float) -> int:
	if absf(got - want) < 1e-4:
		return 0
	printerr("  ✗ %s: got %f, want %f" % [name, got, want])
	return 1

func _check_v(name: String, got: Vector2, want: Vector2) -> int:
	if got.is_equal_approx(want):
		return 0
	printerr("  ✗ %s: got %v, want %v" % [name, got, want])
	return 1

func _check_true(name: String, ok: bool) -> int:
	if ok:
		return 0
	printerr("  ✗ %s: got false, want true" % name)
	return 1
