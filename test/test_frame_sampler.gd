extends SceneTree
## FrameSampler：warmup 丢弃、p95 取值、窗口封口、reset。
## 纯逻辑（喂构造好的帧时序列），不依赖 GPU——贪心求解的正确性因此可在 headless 下验证。
## 运行: godot --headless --path . --script res://test/test_frame_sampler.gd

func _init() -> void:
	var fails := 0

	# warmup 段的帧一律不计入：喂 1.2s 的「假卡顿」（100ms/帧）后再喂平稳 20ms 帧
	var s := FrameSampler.new(1.2, 2.4)
	for i in 12:
		s.feed(0.1)  # 1.2s 的 100ms 尖峰帧（shader 编译期）——必须被丢掉
	fails += _check("warmup 内无样本", s.sample_count(), 0)
	fails += _check("warmup 内未封口", s.is_done(), false)
	for i in 120:
		s.feed(0.02)  # 2.4s 的 20ms 平稳帧
	fails += _check("窗口采到样本", s.sample_count() > 100, true)
	fails += _check("p95 ≈ 20ms（尖峰已被 warmup 丢掉）", is_equal_approx(s.p95_ms(), 20.0), true)
	fails += _check("窗口满后封口", s.is_done(), true)
	var n := s.sample_count()
	s.feed(0.5)  # 封口后再喂不进
	fails += _check("封口后不再收样本", s.sample_count(), n)

	# p95 抓持续掉帧，均值抓不到：90 帧 10ms + 10 帧 60ms → 均值 15ms（看着远远达标），
	# p95 = 60ms（每 10 帧掉 1 帧，孩子看得见）。这正是不能用均值定档的原因。
	var s2 := FrameSampler.new(0.0, 100.0)
	for i in 90:
		s2.feed(0.01)
	for i in 10:
		s2.feed(0.06)
	var mean := (90.0 * 10.0 + 10.0 * 60.0) / 100.0
	fails += _check("均值会骗人（15ms 看着达标）", is_equal_approx(mean, 15.0), true)
	fails += _check("均值在达标线内", mean < GraphicsSettings.TARGET_FRAME_MS, true)
	fails += _check("p95 抓到 60ms 掉帧", is_equal_approx(s2.p95_ms(), 60.0), true)
	fails += _check("p95 越过 30fps 达标线 → 该降档", s2.p95_ms() > GraphicsSettings.TARGET_FRAME_MS, true)

	# 反过来：偶发单帧尖峰（<5%）被 p95 容忍——那是 GC / 资源流送抖动，不该为它降画质。
	var s4 := FrameSampler.new(0.0, 100.0)
	for i in 97:
		s4.feed(0.01)
	for i in 3:
		s4.feed(0.2)  # 3% 的 200ms 巨型尖峰
	fails += _check("3% 尖峰不影响 p95（仍 10ms）", is_equal_approx(s4.p95_ms(), 10.0), true)

	# reset 复用
	s2.reset()
	fails += _check("reset 后清空", s2.sample_count(), 0)
	fails += _check("reset 后 p95=0", s2.p95_ms(), 0.0)
	fails += _check("reset 后未封口", s2.is_done(), false)

	# 无样本不崩
	var s3 := FrameSampler.new()
	fails += _check("无样本 p95=0", s3.p95_ms(), 0.0)

	if fails == 0:
		print("frame_sampler tests PASS")
	else:
		printerr("frame_sampler tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
