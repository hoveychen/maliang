extends SceneTree
## Android 上端侧模型未就绪时,onboarding 必须拒绝开麦——绝不回落服务端上传 PCM。
## initialize() 是异步的(~秒级),此窗口期孩子开口过去会静默走 /onboarding/intro。
## 桌面无 MaliangAsr 单例,走服务端识别合法,门禁不得误伤。
## 运行: godot --headless --path . --script res://test/test_onboarding_asr_gate.gd

var ob: Control
var _ran := false

## 假端侧 ASR：isReady 可控,记录是否被 startSession
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
	# _intro_status 由 intro 页构建；测试直接跑 _intro_start,先补一个占位
	if ob._intro_status == null:
		ob._intro_status = TextureRect.new()
		ob.add_child(ob._intro_status)

	# ── Android + 模型未就绪 → 拒绝开麦 ──
	ob._os_name = "Android"
	fake.ready = false
	ob._intro_start()
	fails += _check("android/未就绪: 不进入录音", ob._intro_recording, false)
	fails += _check("android/未就绪: 不开本地会话", fake.started, false)

	# ── Android + 模型就绪 → 正常开麦走端侧 ──
	fake.ready = true
	ob._intro_start()
	fails += _check("android/已就绪: 进入录音", ob._intro_recording, true)
	fails += _check("android/已就绪: 开本地会话", fake.started, true)
	ob._intro_recording = false # 收尾,别让 _process 继续 drain

	# ── 桌面 + 无端侧单例 → 门禁不得误伤,允许开麦(走服务端) ──
	ob._os_name = "macOS"
	ob._asr_local = null
	ob._intro_start()
	fails += _check("macOS/无单例: 仍可开麦(服务端合法)", ob._intro_recording, true)
	ob._intro_recording = false

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
