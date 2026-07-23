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

	print("test_tile_dimensional: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _ab(sx: float, sy: float, sz: float) -> AABB:
	return AABB(Vector3.ZERO, Vector3(sx, sy, sz))

func _check_f(name: String, got: float, want: float) -> int:
	if absf(got - want) < 1e-4:
		return 0
	printerr("  ✗ %s: got %f, want %f" % [name, got, want])
	return 1
