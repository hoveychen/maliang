extends SceneTree
## onboarding 与 VoiceCapture 的集成：注入合成 PCM 经 ob._vc 走真实编排，验证
##  「静音不开口 → 说话触发录音 → 静音够久断句提交」在 onboarding 侧的观测状态
##  （录音态/提交态/关麦/端侧会话/服务端整段累加）。
## VAD 端点检测本身的数学 + BGM 门控由 test_voice_capture 覆盖，本测试只钉 onboarding 集成。
## 运行: godot --headless --path . --script res://test/test_onboarding_vad.gd

var _ran := false

class FakeAsr:
	extends RefCounted
	var started := false
	var stopped := false
	var fed := 0
	func isReady() -> bool: return true
	func startSession() -> void: started = true
	func stopSession() -> void: stopped = true
	func feedPcm(pcm: PackedByteArray) -> void: fed += pcm.size()

func _pcm(ms: int, amp: float) -> PackedByteArray:
	var samples := 16 * ms
	var buf := PackedByteArray()
	buf.resize(samples * 2)
	for i in samples:
		var v := int(amp * 32767.0) * (1 if (i / 8) % 2 == 0 else -1)
		buf.encode_s16(i * 2, v)
	return buf

func _new_ob() -> Control:
	var ob: Control = load("res://scripts/onboarding.gd").new()
	root.add_child(ob)
	for i in ob.PAGES.size():
		if String(ob.PAGES[i]["kind"]) == "intro":
			ob.page_idx = i
			break
	ob._voice.stop()
	if ob._intro_status == null: # 未 build intro 页时补一个，供状态图标回调落点
		ob._intro_status = TextureRect.new()
		ob.add_child(ob._intro_status)
	return ob

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	# ── 端侧路径（fake 就绪）：说话→录音+端侧会话；静音断句→提交+关麦 ──
	var ob := _new_ob()
	var fake := FakeAsr.new()
	ob._vc._asr = fake
	ob._process(0.016) # 旁白已停：自动开麦
	fails += _check("开麦成功", ob._vc.is_open(), true)

	for i in 20: # 纯静音建噪声底
		ob._vc._feed(_pcm(30, 0.0))
	fails += _check("静音不开口", ob._vc.is_recording(), false)
	fails += _check("静音不开会话", fake.started, false)

	for i in 20: # 说话 600ms
		ob._vc._feed(_pcm(30, 0.3))
	fails += _check("说话触发录音", ob._vc.is_recording(), true)
	fails += _check("开口开端侧会话", fake.started, true)

	for i in 40: # 静音 1200ms → 断句
		ob._vc._feed(_pcm(30, 0.0))
	fails += _check("静音断句 → 退出录音", ob._vc.is_recording(), false)
	fails += _check("断句 → stopSession", fake.stopped, true)
	fails += _check("断句 → 关麦（一次性采集）", ob._vc.is_open(), false)
	fails += _check("断句 → 进入提交态", ob._intro_submitting, true)
	fails += _check("端侧路径喂了 PCM", fake.fed > 0, true)
	ob.free()

	# ── 无可用端侧 ASR（editor/headless 缺模型）：服务端 ASR 已退役，没有回落路径。
	# 录音照跑，但音频不外传（PCM 只可能进插件，插件不在就丢弃）——绝不上传。──
	var ob2 := _new_ob()
	ob2._vc._asr = null
	ob2._process(0.016)
	for i in 20:
		ob2._vc._feed(_pcm(30, 0.0))
	for i in 20:
		ob2._vc._feed(_pcm(30, 0.3))
	fails += _check("无 ASR: 仍进入录音（VAD 不依赖 ASR）", ob2._vc.is_recording(), true)
	fails += _check("无 ASR: 不开端侧会话", ob2._vc.is_ready(), false)
	ob2.free()

	if fails == 0:
		print("onboarding_vad tests PASS")
	else:
		printerr("onboarding_vad tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
