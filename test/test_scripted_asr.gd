extends SceneTree
## 端侧语音 e2e 注入 harness（docs/voice-e2e-harness-design.md）P1：ScriptedAsr 替身 + 注入开关。
## 验证：
##  1) ScriptedAsr 独立：enqueue → stopSession 按序吐 final_result；空队列吐空转写；pending 计数；
##  2) 注进 VoiceCapture 走【真实链路】：合成 PCM 驱 VAD 断句 → stopSession → 预排文本经 local_final 出来
##     （证明替身能真复现「孩子说一句」的整条下游，不只是单点桩）；
##  3) 回归护栏：无 user://asr_harness 标志时 _setup_local_asr 【不】注 ScriptedAsr（默认行为不变）。
## 运行: godot --headless --path . --script res://test/test_scripted_asr.gd

var _ran := false

func _pcm(ms: int, amp: float) -> PackedByteArray:
	var samples := 16 * ms
	var buf := PackedByteArray()
	buf.resize(samples * 2)
	for i in samples:
		var v := int(amp * 32767.0) * (1 if (i / 8) % 2 == 0 else -1)
		buf.encode_s16(i * 2, v)
	return buf

func _check(name: String, got: Variant, want: Variant) -> int:
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

	print("[ScriptedAsr 独立：按序吐预排文本]")
	var asr := ScriptedAsr.new()
	var out: Array[String] = []
	asr.final_result.connect(func(t: String) -> void: out.append(t))
	var ready := [false]
	asr.asr_ready.connect(func() -> void: ready[0] = true)
	asr.initialize()
	fails += _check("initialize 即就绪", asr.isReady(), true)
	fails += _check("asr_ready 发了", ready[0], true)
	asr.enqueue("爬爬梯")
	asr.enqueue("大风车")
	fails += _check("pending=2", asr.pending(), 2)
	asr.startSession(); asr.stopSession()
	asr.startSession(); asr.stopSession()
	fails += _check("按 FIFO 顺序吐", out, ["爬爬梯", "大风车"])
	asr.startSession(); asr.stopSession() # 空队列
	fails += _check("空队列吐空转写", out, ["爬爬梯", "大风车", ""])

	print("[flag 路径注入 + 合成 PCM 驱真实链路 → local_final 出预排文本]")
	# 走【真实注入路径】：写 user://asr_harness 标志 → VoiceCapture._ready→_setup_local_asr 自动
	# 注 ScriptedAsr 并接好 final_result→_on_local_final（连信号接线一起验，不手动 connect 绕过）。
	var flag := FileAccess.open("user://asr_harness", FileAccess.WRITE)
	if flag != null:
		flag.store_string("1"); flag.close()
	fails += _check("headless 是 debug 构建（flag 路径前提）", OS.is_debug_build(), true)
	var vc := VoiceCapture.new()
	root.add_child(vc) # _ready → _setup_local_asr：debug + flag → 注 ScriptedAsr + 接信号
	fails += _check("flag 路径注入了 ScriptedAsr", vc._asr is ScriptedAsr, true)
	var finals: Array[String] = []
	vc.local_final.connect(func(t: String) -> void: finals.append(t))
	vc.should_capture = func() -> bool: return true
	vc.open()
	vc._asr.enqueue("爬爬梯")
	# 说一句：噪声底 → 说话 600ms → 静音 1200ms 断句 → stopSession → final_result → local_final
	for i in 20: vc._feed(_pcm(30, 0.0))
	for i in 20: vc._feed(_pcm(30, 0.3))
	for i in 40: vc._feed(_pcm(30, 0.0))
	fails += _check("预排文本经真实 VAD→ASR 链路出到 local_final", finals, ["爬爬梯"])
	vc.close(); vc.queue_free()
	DirAccess.remove_absolute("user://asr_harness") # 清标志，别污染下面的回归护栏

	print("[回归护栏：无 harness 标志不注 ScriptedAsr]")
	# 无 user://asr_harness 标志（也无 MaliangAsr 单例）→ _setup_local_asr 应保持 _asr 为 null，
	# 绝不悄悄注入替身（默认路径行为不变）。
	var vc2 := VoiceCapture.new()
	root.add_child(vc2) # _ready 里 _asr==null → 走 _setup_local_asr（无标志分支）
	fails += _check("默认不注入 ScriptedAsr", vc2._asr is ScriptedAsr, false)
	vc2.queue_free()

	if fails == 0:
		print("test_scripted_asr: 全部通过")
	else:
		printerr("test_scripted_asr: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)
