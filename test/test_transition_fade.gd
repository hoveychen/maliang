extends SceneTree
## 换场景过场遮罩不透明度推进 World.fade_advance 的收敛/稳定性回测。
## 复现真机 bug：过场遮罩在 loading 页停留（_fade_a 抵达 _fade_target=1.0）时，若推进公式
## 在抵达目标后仍每帧 ±step，会让 _fade_a 在 1.0↔(1.0-step) 之间逐帧抖动 → 遮罩不透明度
## 每帧脉动 → 画面亮度快速闪烁（30fps 实测 175↔186 每帧，见换场景闪烁定位）。
## 断言：抵达目标后必须钉住目标、零抖动；且从 0 推到 1 单调不过冲。
## 运行: godot --headless --path . --script res://test/test_transition_fade.gd

func _init() -> void:
	var fails := 0
	var W: GDScript = load("res://scripts/world.gd")

	# 30fps 下的典型步长：delta(1/30) / FADE_TIME(0.35) ≈ 0.0952
	var step := (1.0 / 30.0) / 0.35

	# —— 核心回归：抵达目标(1.0)后长时间停留，不得抖动 ——
	# loading 页停在全遮挡态，等区块/内容包铺完，可能持续几十上百帧。
	var cur := 1.0
	var lo := cur
	var hi := cur
	for _i in range(60):
		cur = W.fade_advance(cur, 1.0, step)
		lo = minf(lo, cur)
		hi = maxf(hi, cur)
	fails += _check("停在目标 1.0 无下抖（min≈1.0）", is_equal_approx(lo, 1.0), true)
	fails += _check("停在目标 1.0 无脉动（峰峰值≈0）", (hi - lo) < 1e-5, true)

	# —— 对称：停在 0.0（露出世界后）也不得抖动 ——
	cur = 0.0
	lo = cur
	hi = cur
	for _i in range(60):
		cur = W.fade_advance(cur, 0.0, step)
		lo = minf(lo, cur)
		hi = maxf(hi, cur)
	fails += _check("停在目标 0.0 无脉动（峰峰值≈0）", (hi - lo) < 1e-5, true)

	# —— 收敛：从 0 推到 1，单调不减、最终抵达 1.0、且抵达后不过冲 ——
	cur = 0.0
	var prev := cur
	var arrived_at := -1
	var overshoot := 0.0
	for i in range(40):
		cur = W.fade_advance(cur, 1.0, step)
		if cur + 1e-9 < prev:
			fails += _check("上升途中不得回落（帧 %d）" % i, false, true)
		if arrived_at < 0 and is_equal_approx(cur, 1.0):
			arrived_at = i
		if arrived_at >= 0:
			overshoot = maxf(overshoot, absf(cur - 1.0))
		prev = cur
	fails += _check("有限帧内抵达 1.0", arrived_at >= 0, true)
	fails += _check("抵达后不过冲/不抖（|cur-1|≈0）", overshoot < 1e-5, true)

	# —— 单步推进量不超过 step（不会瞬跳）——
	var one: float = W.fade_advance(0.0, 1.0, step)
	fails += _check("单步推进≈step", is_equal_approx(one, step), true)

	if fails == 0:
		print("test_transition_fade: OK")
	else:
		printerr("test_transition_fade: %d 处失败" % fails)
	quit(fails)

func _check(label: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  [FAIL] %s: 得到 %s，期望 %s" % [label, str(got), str(want)])
	return 1
