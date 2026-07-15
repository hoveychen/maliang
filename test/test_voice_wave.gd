extends SceneTree
## VoiceWave 控件：电平 → 柱高映射、相位错开的流动波、以及 active=false 落回静息。
## 不碰 VoiceCapture/ASR——直接注入一个可控的 level_source，手动步进 _process 断言柱高。
## 运行: godot --headless --path . --script res://test/test_voice_wave.gd

var _ran := false
var _lvl := 0.0  # 注入给 level_source 的当前电平

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ✓ %s" % name)
		return 0
	printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _check_true(name: String, cond: bool) -> int:
	return _check(name, cond, true)

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0
	fails += _test_level_lifts_bars()
	fails += _test_phase_offset()
	fails += _test_inactive_settles()
	if fails == 0:
		print("test_voice_wave: 全部通过")
	else:
		printerr("test_voice_wave: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)

# 加进树、_ready 建好柱子的控件；给它一块 rect 让 is_visible_in_tree 为真。
func _make_wave() -> VoiceWave:
	var w := VoiceWave.new()
	w.level_source = func() -> float: return _lvl
	root.add_child(w)
	w.size = Vector2(300, 80)  # 有尺寸才可见（否则动画早返回）
	return w

func _avg(hs: PackedFloat32Array) -> float:
	if hs.is_empty():
		return 0.0
	var s := 0.0
	for h in hs:
		s += h
	return s / float(hs.size())

# delta=0.1 → 平滑因子 12*0.1=1.2 clamp 到 1.0，柱高一步到位（可确定断言）。
func _step(w: VoiceWave, n: int) -> void:
	for i in n:
		w._process(0.1)

func _test_level_lifts_bars() -> int:
	print("[电平抬升柱高]")
	var f := 0
	var w := _make_wave()
	f += _check("默认九条柱", w.bar_heights().size(), 9)
	# 静息（电平 0）：仍在 idle_floor 上轻轻滚，但整体矮
	_lvl = 0.0
	_step(w, 20)
	var quiet := _avg(w.bar_heights())
	# 大声（电平满）：整体明显抬高
	_lvl = 1.0
	_step(w, 20)
	var loud := _avg(w.bar_heights())
	f += _check_true("大声时平均柱高 > 静息时（%.1f > %.1f）" % [loud, quiet], loud > quiet + 1.0)
	f += _check_true("柱高不越界（≤ max_h）", _avg(w.bar_heights()) <= w.bar_max_h + 0.01)
	w.queue_free()
	return f

func _test_phase_offset() -> int:
	print("[相位错开成流动波]")
	var f := 0
	var w := _make_wave()
	_lvl = 1.0
	_step(w, 5)  # 推进相位到某一帧
	var hs := w.bar_heights()
	var lo := hs[0]
	var hi := hs[0]
	for h in hs:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	# 相位错开 → 同一帧各柱高低不一（不是齐刷刷一条平线）
	f += _check_true("同帧各柱高低不一（max %.1f − min %.1f > 2）" % [hi, lo], hi - lo > 2.0)
	w.queue_free()
	return f

func _test_inactive_settles() -> int:
	print("[不在听落回静息]")
	var f := 0
	var w := _make_wave()
	_lvl = 1.0
	w.active = true
	_step(w, 10)  # 先跳起来
	f += _check_true("active 时确有起伏", _avg(w.bar_heights()) > w.bar_min_h + 0.5)
	# 关掉 active：哪怕电平仍满，柱子也应平滑落回静息 min_h
	w.active = false
	_step(w, 20)
	var hs := w.bar_heights()
	var all_rest := true
	for h in hs:
		if absf(h - w.bar_min_h) > 0.5:
			all_rest = false
	f += _check_true("active=false 后全部落回 min_h（%.1f）" % w.bar_min_h, all_rest)
	w.queue_free()
	return f
