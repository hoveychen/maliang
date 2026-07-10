extends SceneTree
## Android 上端侧模型未就绪时,onboarding 必须拒绝开麦——绝不回落服务端上传 PCM。
## initialize() 是异步的(~秒级),此窗口期孩子开口过去会静默走 /onboarding/intro。
## 桌面无 MaliangAsr 单例,走服务端识别合法,门禁不得误伤。
## 运行: godot --headless --path . --script res://test/test_onboarding_asr_gate.gd

var ob: Control
var _ran := false

## 假端侧 ASR:isReady 可控,记录是否被 startSession
class FakeAsr:
	extends RefCounted
	var ready := false
	var started := false
	func isReady() -> bool: return ready
	func startSession() -> void: started = true
	func stopSession() -> void: pass
	func feedPcm(_pcm: PackedByteArray) -> void: pass

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
	if ob._intro_status == null:
		ob._intro_status = TextureRect.new()
		ob.add_child(ob._intro_status)

	# ── Android + 模型未就绪 → 拒绝开麦(不建 VAD、不采集) ──
	ob._os_name = "Android"
	fake.ready = false
	ob._intro_open_mic()
	fails += _check("android/未就绪: 不开麦", ob._vad == null, true)
	fails += _check("android/未就绪: 不进入录音", ob._intro_recording, false)

	# ── Android + 模型就绪 → 开麦(建 VAD),但尚未开口 ──
	fake.ready = true
	ob._intro_open_mic()
	fails += _check("android/已就绪: 开麦", ob._vad != null, true)
	fails += _check("android/已就绪: 未开口前不录音", ob._intro_recording, false)
	fails += _check("android/已就绪: 未开口前不开会话", fake.started, false)

	# ── VAD 判定开口 → 开本地会话,不上传 ──
	ob._intro_begin(PackedByteArray())
	fails += _check("开口: 进入录音", ob._intro_recording, true)
	fails += _check("开口: 走端侧会话", fake.started, true)
	fails += _check("开口: 端侧不攒服务端 PCM", ob._intro_pcm.is_empty(), true)

	# ── 误触(说太短) → 取消,麦克风继续开着 ──
	ob._intro_cancel()
	fails += _check("误触取消: 退出录音", ob._intro_recording, false)
	fails += _check("误触取消: 麦克风仍开着", ob._vad != null, true)

	# ── 关麦 → VAD 置空 ──
	ob._intro_close_mic()
	fails += _check("关麦: VAD 置空", ob._vad == null, true)

	# ── 桌面 + 无端侧单例 → 门禁不得误伤,允许开麦(走服务端) ──
	ob._os_name = "macOS"
	ob._asr_local = null
	ob._intro_open_mic()
	fails += _check("macOS/无单例: 仍可开麦(服务端合法)", ob._vad != null, true)
	ob._intro_close_mic()

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
