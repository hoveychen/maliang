extends SceneTree
## VoiceCapture 确认模式单测（小龄玩家：说完先听一遍自己的话，点「就是这样」才算数）。
## 注入合成 PCM 走真实 VAD 链路（_feed）+ 手动触发端侧识别结果（_on_local_final），验证：
##  1) confirm_mode 关：行为一字不变（committed + local_final 直接发）——不确认模式的回归护栏；
##  2) confirm_mode 开：识别成功 → 不发 committed/local_final，改发 confirm_ready，进 confirming 态；
##  3) accept()：补发 committed + local_final（顺序与非确认模式一致，宿主逻辑无需改动）；
##  4) retry()：宿主什么都收不到（不发 committed/local_final），麦继续开着等重说；
##  5) 确认期间 VAD 全程屏蔽——回放的是孩子自己的声音，无 AEC 的麦会原样收回去，
##     不屏蔽就会在确认条还亮着时套娃出新一段（本模式最容易踩的坑）；
##  6) 识别失败（空转写）不进确认：本来就得重说，直接走宿主既有的「没听清」分支；
##  7) close()（退对话）时还挂着确认条：本段作废，宿主收不到任何东西。
## 运行: godot --headless --path . --script res://test/test_voice_confirm.gd

var _ran := false

class FakeAsr:
	extends RefCounted
	var started := false
	var stopped := false
	func isReady() -> bool: return true
	func startSession() -> void: started = true
	func stopSession() -> void: stopped = true
	func feedPcm(_pcm: PackedByteArray) -> void: pass

## 生成 ms 毫秒的 16k PCM16 单声道。amp=0 为静音，amp 大为「说话」。
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

## 建一个开着麦、已注入就绪端侧 ASR 的 VoiceCapture；events 记录宿主侧收到的信号顺序。
func _make(confirm: bool, events: Array) -> VoiceCapture:
	var vc := VoiceCapture.new()
	vc._asr = FakeAsr.new()
	vc.confirm_mode = confirm
	root.add_child(vc)
	vc.should_capture = func() -> bool: return true
	vc.committed.connect(func() -> void: events.append("committed"))
	vc.local_final.connect(func(t: String) -> void: events.append("final:" + t))
	vc.confirm_ready.connect(func(t: String) -> void: events.append("confirm:" + t))
	vc.open()
	return vc

## 说一句话：噪声底 → 说话 600ms → 静音 1200ms 断句。断句后端侧会话已 stop，等 _on_local_final。
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
	fails += _test_off_unchanged()
	fails += _test_on_holds_back()
	fails += _test_accept()
	fails += _test_retry()
	fails += _test_vad_muted_while_confirming()
	fails += _test_empty_skips_confirm()
	fails += _test_close_discards()
	if fails == 0:
		print("test_voice_confirm: 全部通过")
	else:
		printerr("test_voice_confirm: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)

# ① 确认模式关：行为与从前一字不差（回归护栏——别让新功能改坏默认路径）。
func _test_off_unchanged() -> int:
	print("[确认模式关：行为不变]")
	var f := 0
	var ev := []
	var vc := _make(false, ev)
	_say(vc)
	f += _check("断句即发 committed", ev, ["committed"])
	vc._on_local_final("去公园")
	f += _check("识别结果直接给宿主", ev, ["committed", "final:去公园"])
	f += _check("不进确认态", vc.is_confirming(), false)
	vc.close(); vc.queue_free()
	return f

# ② 确认模式开：识别成功后先扣住，只发 confirm_ready。
func _test_on_holds_back() -> int:
	print("[确认模式开：先扣住不发]")
	var f := 0
	var ev := []
	var vc := _make(true, ev)
	_say(vc)
	f += _check("断句后【不】发 committed（说完≠采纳）", ev, [])
	vc._on_local_final("去公园")
	f += _check("只发 confirm_ready，宿主拿不到转写", ev, ["confirm:去公园"])
	f += _check("进入确认态", vc.is_confirming(), true)
	vc.close(); vc.queue_free()
	return f

# ③ accept：补发 committed + local_final，顺序与非确认模式一致。
func _test_accept() -> int:
	print("[accept：就是这样]")
	var f := 0
	var ev := []
	var vc := _make(true, ev)
	_say(vc)
	vc._on_local_final("去公园")
	ev.clear()
	vc.accept()
	f += _check("补发 committed 在前、local_final 在后", ev, ["committed", "final:去公园"])
	f += _check("退出确认态", vc.is_confirming(), false)
	f += _check("麦继续开着（可以说下一句）", vc.is_open(), true)
	vc.close(); vc.queue_free()
	return f

# ④ retry：宿主什么都收不到，麦继续开着等重说。
func _test_retry() -> int:
	print("[retry：再说一次]")
	var f := 0
	var ev := []
	var vc := _make(true, ev)
	_say(vc)
	vc._on_local_final("去公园")
	ev.clear()
	vc.retry()
	f += _check("重录：宿主收不到任何信号", ev, [])
	f += _check("退出确认态", vc.is_confirming(), false)
	f += _check("麦仍开着等重说", vc.is_open(), true)
	# 重说一句，应能正常走到下一次确认
	_say(vc)
	vc._on_local_final("去河边")
	f += _check("重说后能再次进确认", ev, ["confirm:去河边"])
	vc.close(); vc.queue_free()
	return f

# ⑤ 确认期间必须屏蔽 VAD：回放的是孩子自己的声音，麦会原样收回去。
# 不屏蔽的话，确认条还亮着就已经套娃录出新一段了。
func _test_vad_muted_while_confirming() -> int:
	print("[确认期间屏蔽 VAD]")
	var f := 0
	var ev := []
	var vc := _make(true, ev)
	_say(vc)
	vc._on_local_final("去公园")
	f += _check("前提：正在等确认", vc.is_confirming(), true)
	# 确认条亮着时，麦里灌进「回放的自己的声音」——step 必须一律不喂 VAD
	for i in 40:
		vc.step(0.016)
	f += _check("回放声没被听成新的开口", vc.is_recording(), false)
	f += _check("没有套娃出第二次确认", ev, ["confirm:去公园"])
	vc.close(); vc.queue_free()
	return f

# ⑥ 识别失败（空转写）不进确认——本来就要重说，直接走宿主既有的「没听清」分支。
func _test_empty_skips_confirm() -> int:
	print("[识别失败不进确认]")
	var f := 0
	var ev := []
	var vc := _make(true, ev)
	_say(vc)
	vc._on_local_final("   ")
	f += _check("空转写直接给宿主（走「没听清」重录）", ev, ["committed", "final:   "])
	f += _check("不进确认态（没什么可确认的）", vc.is_confirming(), false)
	vc.close(); vc.queue_free()
	return f

# ⑦ 退对话时确认条还挂着：本段作废，宿主收不到任何东西。
func _test_close_discards() -> int:
	print("[退出时作废]")
	var f := 0
	var ev := []
	var vc := _make(true, ev)
	_say(vc)
	vc._on_local_final("去公园")
	ev.clear()
	vc.close()
	f += _check("关麦即作废：不补发 committed/local_final", ev, [])
	f += _check("确认态已清", vc.is_confirming(), false)
	vc.queue_free()
	return f
