extends SceneTree
## B3 语音起名（reuse-name §3.2）VoiceCapture.last_pcm() 契约：
## 起名要把孩子那句录音上传当名字，宿主在 local_final 里取 _vc.last_pcm()。
## accept() 前 _end_confirm 会清 _utt_pcm，所以 last_pcm 必须在采纳的那一刻快照。
## 验证：
##  1) 确认模式 accept 后 last_pcm() 非空 = 采纳那段完整录音（可 base64 上传）；
##  2) 非确认模式 last_pcm() 恒空（_utt_pcm 只在确认模式累积）；
##  3) retry 不快照（拒绝的那段不该被当成名字上传）。
## 运行: godot --headless --path . --script res://test/test_name_voice.gd

var _ran := false

class FakeAsr:
	extends RefCounted
	func isReady() -> bool: return true
	func startSession() -> void: pass
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

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ✓ %s" % name)
		return 0
	printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _make(confirm: bool) -> VoiceCapture:
	var vc := VoiceCapture.new()
	vc._asr = FakeAsr.new()
	vc.confirm_mode = confirm
	root.add_child(vc)
	vc.should_capture = func() -> bool: return true
	vc.open()
	return vc

## 说一句：噪声底 → 说话 600ms → 静音 1200ms 断句。
func _say(vc: VoiceCapture) -> void:
	for i in 20:
		vc._feed(_pcm(30, 0.0))
	for i in 20:
		vc._feed(_pcm(30, 0.3))
	for i in 40:
		vc._feed(_pcm(30, 0.0))

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	print("[确认模式 accept：last_pcm 快照到那段录音]")
	var vc := _make(true)
	_say(vc)
	vc._on_local_final("爬爬梯")
	fails += _check("采纳前进入确认态", vc.is_confirming(), true)
	vc.accept()
	var pcm := vc.last_pcm()
	fails += _check("accept 后 last_pcm 非空（有可上传的录音）", pcm.size() > 0, true)
	# 能被 base64 编码走 send_name_creation
	fails += _check("last_pcm 可 base64 编码", Marshalls.raw_to_base64(pcm).length() > 0, true)
	vc.close(); vc.queue_free()

	print("[非确认模式：last_pcm 恒空]")
	var vc2 := _make(false)
	_say(vc2)
	vc2._on_local_final("梯子")
	fails += _check("非确认模式没累积录音 → last_pcm 空", vc2.last_pcm().size(), 0)
	vc2.close(); vc2.queue_free()

	print("[retry 不快照：被拒的那段不当名字]")
	var vc3 := _make(true)
	_say(vc3)
	vc3._on_local_final("不要")
	vc3.retry()
	fails += _check("retry 后 last_pcm 仍空（没采纳就没有名字录音）", vc3.last_pcm().size(), 0)
	vc3.close(); vc3.queue_free()

	if fails == 0:
		print("test_name_voice: 全部通过")
	else:
		printerr("test_name_voice: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)
