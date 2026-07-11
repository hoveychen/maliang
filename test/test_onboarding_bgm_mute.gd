extends SceneTree
## 问题①的回归护栏：onboarding「问名字」步骤，旁白说完→开麦→等孩子开口这段**聆听窗**，
## 无 AEC 的麦会把满音量 BGM 收进去顶开 VAD。正确口径应「开麦窗一开就静音 BGM」，
## 而不是只在 _intro_recording（已判定开口、正在录）时才静音。
##
## 旧口径 set_music_muted(_intro_recording) 在此场景下 muted 停在 false → 本测试红灯；
## 接入 VoiceCapture 后（开麦窗即静音）→ 绿灯。
## 运行: godot --headless --path . --script res://test/test_onboarding_bgm_mute.gd

var _ran := false

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
	var ob: Control = load("res://scripts/onboarding.gd").new()
	root.add_child(ob)

	# 定位到 intro 页：_process 会在此页旁白说完后自动开麦（走真实集成路径，不戳内部）。
	for i in ob.PAGES.size():
		if String(ob.PAGES[i]["kind"]) == "intro":
			ob.page_idx = i
			break
	# 进入聆听窗：无旁白/人声在放。
	ob._voice.stop()
	fails += _check("前置：无人声在放", ob._voice.playing, false)

	# 驱动两帧：第一帧 _process 自动 _vc.open()（聆听窗打开），step 内 BGM 门控应把 Music 静音
	# ——聆听窗一开即静音，不必等孩子真开口（旧口径 set_music_muted(_intro_recording) 漏此窗）。
	ob._process(0.016)
	ob._process(0.016)
	fails += _check("开麦等待窗即静音 BGM（问题①）", ob.game_audio.muted, true)

	# 反证：有旁白/人声在放时不静音，让 BGM 垫在人声下（避免误伤正常演出）。
	# 用 _voice 播一段静音流冒充「正在说话」。
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 16000
	wav.data = _silence(500)
	ob._voice.stream = wav
	ob._voice.play()
	ob._process(0.016)
	fails += _check("有人声时放行 BGM", ob.game_audio.muted, false)

	if fails == 0:
		print("test_onboarding_bgm_mute: 全部通过")
	else:
		printerr("test_onboarding_bgm_mute: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)

func _silence(ms: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(16 * ms * 2)
	return buf
