extends SceneTree
## Android 上端侧模型未就绪时,onboarding 必须拒绝开麦——绝不回落服务端上传 PCM。
## initialize() 是异步的(~秒级),此窗口期孩子开口过去会静默走 /onboarding/intro。
## 桌面无 MaliangAsr 单例,走服务端识别合法,门禁不得误伤。
##
## 重构后编排在 VoiceCapture（ob._vc）里：门禁体现为 onboarding._process 是否调用 _vc.open()
## （must_wait_for_ready 时不开），以及开口后是否走端侧会话/不攒服务端 PCM。
## 运行: godot --headless --path . --script res://test/test_onboarding_asr_gate.gd

var _ran := false

class FakeAsr:
	extends RefCounted
	var ready := false
	var started := false
	func isReady() -> bool: return ready
	func startSession() -> void: started = true
	func stopSession() -> void: pass
	func feedPcm(_pcm: PackedByteArray) -> void: pass

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
	for i in ob.PAGES.size(): # 定位 intro 页，_process 才会驱动开麦
		if String(ob.PAGES[i]["kind"]) == "intro":
			ob.page_idx = i
			break
	ob._voice.stop()
	return ob

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0
	var ob := _new_ob()
	var fake := FakeAsr.new()
	ob._vc._asr = fake
	ob._vc.os_name = "Android"

	# ── Android + 模型未就绪 → _process 拒绝开麦（不建 VAD、不采集） ──
	fake.ready = false
	ob._process(0.016)
	fails += _check("android/未就绪: 不开麦", ob._vc.is_open(), false)

	# ── Android + 模型就绪 → 开麦，但尚未开口 ──
	fake.ready = true
	ob._process(0.016)
	fails += _check("android/已就绪: 开麦", ob._vc.is_open(), true)
	fails += _check("android/已就绪: 未开口前不录音", ob._vc.is_recording(), false)
	fails += _check("android/已就绪: 未开口前不开会话", fake.started, false)

	# ── VAD 判定开口 → 开本地会话，不攒服务端 PCM ──
	for i in 20: # 噪声底
		ob._vc._feed(_pcm(30, 0.0))
	for i in 20: # 说话
		ob._vc._feed(_pcm(30, 0.3))
	fails += _check("开口: 进入录音", ob._vc.is_recording(), true)
	fails += _check("开口: 走端侧会话", fake.started, true)
	fails += _check("开口: 端侧不攒服务端 PCM", ob._intro_pcm.is_empty(), true)

	# ── 误触(说太短) → 取消，麦克风继续开着 ──
	ob._vc._cancel_utterance()
	fails += _check("误触取消: 退出录音", ob._vc.is_recording(), false)
	fails += _check("误触取消: 麦克风仍开着", ob._vc.is_open(), true)
	ob.free()

	# ── 桌面 + 无端侧单例 → 门禁不得误伤，允许开麦(走服务端) ──
	var ob2 := _new_ob()
	ob2._vc._asr = null
	ob2._vc.os_name = "macOS"
	ob2._process(0.016)
	fails += _check("macOS/无单例: 仍可开麦(服务端合法)", ob2._vc.is_open(), true)
	ob2.free()

	if fails == 0:
		print("onboarding_asr_gate tests PASS")
	else:
		printerr("onboarding_asr_gate tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _initialize() -> void:
	process_frame.connect(_run_once)
