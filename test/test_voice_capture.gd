extends SceneTree
## VoiceCapture 模块单测：注入合成 PCM 走真实 VAD 链路（_feed），验证
##  1) BGM 静音门控——**聆听窗一开就静音，不必等到 recording**（问题①的回归护栏：
##     旧 onboarding 口径 set_music_muted(_intro_recording) 漏了开麦等待窗）；
##  2) 端侧路径：开口→startSession+feedPcm，说完→stopSession；
##  3) 服务端路径（无端侧单例）：开口→chunk 信号，说完→committed 信号；
##  4) 太短→cancelled，不产生 commit。
## 运行: godot --headless --path . --script res://test/test_voice_capture.gd

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

## 生成 ms 毫秒的 16k PCM16 单声道。amp=0 为静音，amp 大为「说话」。
func _pcm(ms: int, amp: float) -> PackedByteArray:
	var samples := 16 * ms
	var buf := PackedByteArray()
	buf.resize(samples * 2)
	for i in samples:
		var v := int(amp * 32767.0) * (1 if (i / 8) % 2 == 0 else -1)
		buf.encode_s16(i * 2, v)
	return buf

func _check(name: String, got, want) -> int:
	if got == want:
		print("  ✓ %s" % name)
		return 0
	printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0
	fails += _test_bgm_gating()
	fails += _test_local_path()
	fails += _test_server_path()
	fails += _test_short_cancel()
	fails += _test_sfx_guard()
	if fails == 0:
		print("test_voice_capture: 全部通过")
	else:
		printerr("test_voice_capture: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)

## 新建一个已加子树的 VoiceCapture；asr 预注入则跳过单例接线（服务端路径传 null）。
func _make(asr: Object, ga: GameAudio) -> VoiceCapture:
	var vc := VoiceCapture.new()
	vc._asr = asr
	vc.game_audio = ga
	vc.os_name = "Linux" # 桌面口径：无单例不致命
	root.add_child(vc)
	return vc

# ① BGM 门控：这是问题①的核心回归护栏。
func _test_bgm_gating() -> int:
	print("[bgm 门控]")
	var f := 0
	var ga := GameAudio.new()
	root.add_child(ga)
	var vc := _make(null, ga)
	var speaking := [false] # 用 Array 让 lambda 可变捕获
	vc.is_speaking = func() -> bool: return speaking[0]
	vc.should_capture = func() -> bool: return true

	# 未开麦：不该静音
	vc.step(0.016)
	f += _check("闭麦时不静音 BGM", ga.muted, false)

	# 开麦但孩子还没开口（等待窗）：旧口径这里漏静音，新口径必须已静音
	vc.open()
	vc.step(0.016)
	f += _check("开麦等待窗即静音 BGM（问题①）", ga.muted, true)

	# 有角色/旁白在说话：放行 BGM 垫在人声下
	speaking[0] = true
	vc.step(0.016)
	f += _check("有人声时放行 BGM", ga.muted, false)
	speaking[0] = false

	# 关麦后：恢复不静音
	vc.close()
	vc.step(0.016)
	f += _check("关麦后恢复不静音", ga.muted, false)

	vc.queue_free()
	ga.queue_free()
	return f

# ② 端侧路径：fake asr 就绪，走 startSession/feedPcm/stopSession。
func _test_local_path() -> int:
	print("[端侧路径]")
	var f := 0
	var fake := FakeAsr.new()
	var vc := _make(fake, null)
	vc.should_capture = func() -> bool: return true
	vc.open()

	for i in 20: # 静音建噪声底
		vc._feed(_pcm(30, 0.0))
	f += _check("静音不开口", vc.is_recording(), false)
	f += _check("静音不开会话", fake.started, false)

	for i in 20: # 说话 600ms
		vc._feed(_pcm(30, 0.3))
	f += _check("说话触发开口", vc.is_recording(), true)
	f += _check("开口即起端侧会话", fake.started, true)
	f += _check("端侧收到 PCM", fake.fed > 0, true)

	for i in 40: # 静音 1200ms → 断句
		vc._feed(_pcm(30, 0.0))
	f += _check("静音够久断句", vc.is_recording(), false)
	f += _check("断句关端侧会话", fake.stopped, true)

	vc.close()
	vc.queue_free()
	return f

# ③ 服务端路径：无端侧单例，走 chunk / committed 信号。
func _test_server_path() -> int:
	print("[服务端路径]")
	var f := 0
	var vc := _make(null, null)
	vc.should_capture = func() -> bool: return true
	var chunks := []
	var begins := [0]
	var commits := [0]
	vc.chunk.connect(func(pcm: PackedByteArray) -> void: chunks.append(pcm))
	vc.utterance_begin.connect(func(_is_local: bool) -> void: begins[0] += 1)
	vc.committed.connect(func(_is_local: bool) -> void: commits[0] += 1)
	vc.open()

	for i in 20:
		vc._feed(_pcm(30, 0.0))
	for i in 20:
		vc._feed(_pcm(30, 0.3))
	f += _check("开口发 utterance_begin", begins[0], 1)
	f += _check("服务端路径发 chunk", chunks.size() > 0, true)
	f += _check("未走端侧（is_ready 假）", vc.is_ready(), false)

	for i in 40:
		vc._feed(_pcm(30, 0.0))
	f += _check("断句发 committed", commits[0], 1)

	vc.close()
	vc.queue_free()
	return f

# ④ 太短的有声段：cancel 而非 commit。
func _test_short_cancel() -> int:
	print("[太短取消]")
	var f := 0
	var vc := _make(null, null)
	vc.should_capture = func() -> bool: return true
	var commits := [0]
	var cancels := [0]
	vc.committed.connect(func(_is_local: bool) -> void: commits[0] += 1)
	vc.cancelled.connect(func(_is_local: bool) -> void: cancels[0] += 1)
	vc.open()

	for i in 20:
		vc._feed(_pcm(30, 0.0))
	# 只说 200ms（< MIN_SPEECH_MS 400）后立即静音 → cancel
	for i in 7:
		vc._feed(_pcm(30, 0.3))
	for i in 40:
		vc._feed(_pcm(30, 0.0))
	f += _check("太短不 commit", commits[0], 0)
	f += _check("太短走 cancel", cancels[0] >= 1, true)

	vc.close()
	vc.queue_free()
	return f

# ⑤ 自听防护：开麦态自播音效外放（sfx_bleeding）时 step 必须屏蔽 VAD（防被音效顶开开口）。
func _test_sfx_guard() -> int:
	print("[自听防护]")
	var f := 0
	var ga := GameAudio.new()
	root.add_child(ga)
	var vc := _make(null, ga)
	vc.should_capture = func() -> bool: return true
	vc.open()
	ga.play_sfx("confirm") # 290ms > VAD START_MS(90ms)
	f += _check("前提：音效记账为正在出声", ga.sfx_bleeding(), true)
	vc.step(0.0)
	f += _check("开麦态播音效必须屏蔽 VAD（_unmute_t 起）", vc._unmute_t > 0.0, true)
	vc.close()
	vc.queue_free()
	ga.queue_free()
	return f
