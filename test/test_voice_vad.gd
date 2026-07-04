extends SceneTree
## VoiceVad 端点检测单元测试：合成 PCM（静音/正弦语音）按分片喂入，
## 断言 start/speech/end/cancel 事件时序与预录缓冲行为。全程确定性、无节点依赖。
## 运行: godot --headless --path . --script res://test/test_voice_vad.gd

func _initialize() -> void:
	var fails := 0
	fails += _test_silence_no_events()
	fails += _test_normal_utterance()
	fails += _test_short_burst_cancels()
	fails += _test_reset_drops_segment()
	fails += _test_level_exposed()
	if fails == 0:
		print("voice_vad tests PASS")
	else:
		printerr("voice_vad tests FAILED: %d" % fails)
	quit(fails)

## 纯静音：不产生任何事件。
func _test_silence_no_events() -> int:
	var vad := VoiceVad.new()
	var events := _feed_chunked(vad, _silence(1000))
	return _check("silence yields no events", events.size(), 0)

## 正常说话：静音 → 600ms 人声 → 1s 静音。应有且仅有一次 start（带预录，首音节不丢）、
## 若干 speech、最后一个 end（无 cancel）。
func _test_normal_utterance() -> int:
	var vad := VoiceVad.new()
	var fails := 0
	fails += _check("leading silence quiet", _feed_chunked(vad, _silence(500)).size(), 0)
	var events := _feed_chunked(vad, _voice(600))
	events.append_array(_feed_chunked(vad, _silence(1200)))
	var starts := events.filter(func(e: Dictionary) -> bool: return e["type"] == "start")
	var ends := events.filter(func(e: Dictionary) -> bool: return e["type"] == "end")
	var cancels := events.filter(func(e: Dictionary) -> bool: return e["type"] == "cancel")
	fails += _check("one start", starts.size(), 1)
	fails += _check("one end", ends.size(), 1)
	fails += _check("no cancel", cancels.size(), 0)
	if starts.size() == 1:
		var head := starts[0]["pcm"] as PackedByteArray
		# 预录 300ms + 触发帧 90ms：start 携带的头块应覆盖开口前后（>= 300ms 字节量）
		fails += _check("start carries preroll (%d bytes)" % head.size(),
			head.size() >= 300 * VoiceVad.BYTES_PER_MS, true)
		# start 事件应在语音结束前发出（speech 事件跟在其后）
		fails += _check("speech follows start", events.find(starts[0]) < events.size() - 1, true)
	return fails

## 短促噪声（150ms）：会触发开口（>START_MS），但静音判定后有声段 < MIN_SPEECH_MS，
## 应收 cancel 而非 end——上层据此静默丢弃、不打扰角色。
func _test_short_burst_cancels() -> int:
	var vad := VoiceVad.new()
	var fails := 0
	var events := _feed_chunked(vad, _voice(150))
	events.append_array(_feed_chunked(vad, _silence(1200)))
	var starts := events.filter(func(e: Dictionary) -> bool: return e["type"] == "start")
	var ends := events.filter(func(e: Dictionary) -> bool: return e["type"] == "end")
	var cancels := events.filter(func(e: Dictionary) -> bool: return e["type"] == "cancel")
	fails += _check("burst triggers start", starts.size(), 1)
	fails += _check("burst cancels", cancels.size(), 1)
	fails += _check("burst never ends", ends.size(), 0)
	return fails

## reset（闭麦/退出交互）：进行中的段被丢弃，恢复后从干净状态开始，旧段不产生尾事件。
func _test_reset_drops_segment() -> int:
	var vad := VoiceVad.new()
	var fails := 0
	var events := _feed_chunked(vad, _voice(300)) # 说到一半
	fails += _check("segment in progress", events.any(
		func(e: Dictionary) -> bool: return e["type"] == "start"), true)
	vad.reset()
	events = _feed_chunked(vad, _silence(1500))
	fails += _check("reset drops segment (no end/cancel)", events.size(), 0)
	return fails

## level 暴露：说话时 > 0（供耳朵脉动 UI），静音回落到 0。
func _test_level_exposed() -> int:
	var vad := VoiceVad.new()
	var fails := 0
	_feed_chunked(vad, _voice(120))
	fails += _check("level rises with voice", vad.level > 0.2, true)
	_feed_chunked(vad, _silence(120))
	fails += _check("level falls in silence", vad.level < 0.05, true)
	return fails

## ── 合成 PCM 工具 ────────────────────────────────────────────────────────

## 模拟真实采集节奏：按 ~90ms 分片喂入，聚合所有事件。
func _feed_chunked(vad: VoiceVad, pcm: PackedByteArray) -> Array:
	var events: Array = []
	var chunk := 90 * VoiceVad.BYTES_PER_MS
	var at := 0
	while at < pcm.size():
		events.append_array(vad.feed(pcm.slice(at, mini(at + chunk, pcm.size()))))
		at += chunk
	return events

func _silence(ms: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(ms * VoiceVad.BYTES_PER_MS)
	return out

## 440Hz 正弦、幅度 0.5（RMS≈0.35，远超触发阈值）模拟人声。
func _voice(ms: int) -> PackedByteArray:
	var n := ms * VoiceVad.BYTES_PER_MS / 2
	var out := PackedByteArray()
	out.resize(n * 2)
	for i in range(n):
		var s := sin(TAU * 440.0 * float(i) / 16000.0) * 0.5
		var v := int(s * 32767.0)
		if v < 0:
			v += 65536
		out[i * 2] = v & 0xFF
		out[i * 2 + 1] = (v >> 8) & 0xFF
	return out

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ok %s" % name)
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
