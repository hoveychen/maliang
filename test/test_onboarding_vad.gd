extends SceneTree
## onboarding 开放麦:注入合成 PCM 走真实 VAD 链路(_feed_intro_pcm),
## 验证「静音不开口 → 说话触发 → 静音够久断句提交」,以及旁白播放期间闭麦。
## 替代原先的按住说话:不再有 hold 按钮,VAD 判定开口/说完。
## 运行: godot --headless --path . --script res://test/test_onboarding_vad.gd

var ob: Control
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

## 生成 ms 毫秒的 16k PCM16 单声道。amp=0 为静音,amp 大为「说话」。
func _pcm(ms: int, amp: float) -> PackedByteArray:
	var samples := 16 * ms
	var buf := PackedByteArray()
	buf.resize(samples * 2)
	for i in samples:
		# 方波,能量稳定,避免正弦过零点让 RMS 抖动
		var v := int(amp * 32767.0) * (1 if (i / 8) % 2 == 0 else -1)
		buf.encode_s16(i * 2, v)
	return buf

func _initialize() -> void:
	ob = load("res://scripts/onboarding.gd").new()
	root.add_child(ob)
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0
	var fake := FakeAsr.new()
	ob._asr_local = fake
	ob._os_name = "Android"
	if ob._intro_status == null:
		ob._intro_status = TextureRect.new()
		ob.add_child(ob._intro_status)

	ob._intro_open_mic()
	fails += _check("开麦成功", ob._vad != null, true)

	# ── 纯静音:建立噪声底,不应判定开口 ──
	for i in 20:
		ob._feed_intro_pcm(_pcm(30, 0.0))
	fails += _check("静音不开口", ob._intro_recording, false)
	fails += _check("静音不开会话", fake.started, false)

	# ── 持续说话 600ms:应判定开口并走端侧会话 ──
	for i in 20:
		ob._feed_intro_pcm(_pcm(30, 0.3))
	fails += _check("说话触发开口", ob._intro_recording, true)
	fails += _check("开口开端侧会话", fake.started, true)

	# ── 静音 900ms 以上:应判定说完,提交并关麦 ──
	for i in 40:
		ob._feed_intro_pcm(_pcm(30, 0.0))
	fails += _check("静音断句 → 退出录音", ob._intro_recording, false)
	fails += _check("断句 → stopSession", fake.stopped, true)
	fails += _check("断句 → 关麦", ob._vad == null, true)
	fails += _check("端侧路径喂了 PCM", fake.fed > 0, true)
	fails += _check("端侧路径不攒服务端 PCM", ob._intro_pcm.is_empty(), true)
	fails += _check("提交中不再自动开麦", ob._intro_submitting, true)

	# ── 误触:极短促声(<400ms)应 cancel 而非 commit ──
	var fake2 := FakeAsr.new()
	ob._asr_local = fake2
	ob._intro_submitting = false
	ob._intro_open_mic()
	for i in 20:
		ob._feed_intro_pcm(_pcm(30, 0.0)) # 噪声底
	for i in 4:
		ob._feed_intro_pcm(_pcm(30, 0.3)) # 仅 ~120ms 有声
	for i in 40:
		ob._feed_intro_pcm(_pcm(30, 0.0))
	fails += _check("误触不提交", fake2.stopped, false)
	fails += _check("误触后麦克风仍开着", ob._vad != null, true)
	fails += _check("误触后不在录音", ob._intro_recording, false)

	fails += _test_sfx_guard()

	ob._intro_close_mic()

	if fails == 0:
		print("onboarding_vad tests PASS")
	else:
		printerr("onboarding_vad tests FAILED: %d" % fails)
	quit(fails)

## 自播音效外放会被无 AEC 的麦克风收回去（world.gd 同源，见 test_sfx_mic_guard）。
## 绘本目前的开麦时刻恰好都在旁白播完之后（_step_intro 要求 not _voice.playing），
## 那一刻没有音效在响——所以这是**对称加固**，不是现存缺陷的修复。这条断言把加固钉住：
## 一旦有人在开麦态加音效（world.gd 就踩过 enter/bell），守卫兜住而不是误判开口。
##
## 注意必须驱动 _step_intro：既有断言都直接调 _feed_intro_pcm，绕过了所有门禁。
func _test_sfx_guard() -> int:
	var fails := 0
	ob._intro_submitting = false
	ob._intro_open_mic()
	if ob._vad == null:
		printerr("  FAIL sfx guard: 开麦失败")
		return 1
	ob._intro_recording = false # 未开口的聆听态（RECORDING 态不该屏蔽，会吃掉孩子的话）
	ob._unmute_t = 0.0
	fails += _check("前提:旁白没在播(否则屏蔽来自旁白,假绿)", ob._voice.playing, false)
	ob.game_audio.play_sfx("confirm") # 290ms > VAD START_MS(90ms)
	fails += _check("前提:音效记账为正在出声", ob.game_audio.sfx_bleeding(), true)
	ob._step_intro(0.0)
	fails += _check("开麦态播音效必须屏蔽 VAD", ob._unmute_t > 0.0, true)
	return fails

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
