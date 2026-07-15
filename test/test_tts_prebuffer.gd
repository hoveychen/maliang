extends SceneTree
## WorldScript._stream_ready_to_play 的纯函数测试：流式 TTS 起播判定。
## 服务端降级流 tts_start 后先攒 PCM，攒够 TTS_PREBUFFER_SEC 秒（或短句 tts_end 早到）才 play()，
## 避免分片慢于播放导致 generator 缓冲欠载（声音出一点就卡再续）。
## 运行: Godot --headless --path . --script res://test/test_tts_prebuffer.gd

const WorldScript := preload("res://scripts/world.gd")

var _fails := 0

func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s: %s" % [name, detail])
		_fails += 1

func _init() -> void:
	# 24kHz PCM16 单声道下 0.4s 的预缓冲阈值 = 24000 * 2 * 0.4 = 19200 字节
	var thr := int(24000.0 * 2.0 * WorldScript.TTS_PREBUFFER_SEC)
	_ok("阈值按采样率算对（0.4s@24k=19200）", thr == 19200, "got %d" % thr)

	# ── 未收尾（ending=false）：纯看攒够没 ──
	_ok("攒得不够 → 先别播（避免欠载）", not WorldScript._stream_ready_to_play(0, thr, false))
	_ok("差一点也别播", not WorldScript._stream_ready_to_play(thr - 1, thr, false))
	_ok("恰好攒够 → 起播", WorldScript._stream_ready_to_play(thr, thr, false))
	_ok("攒超了 → 起播", WorldScript._stream_ready_to_play(thr + 5000, thr, false))

	# ── 短句兜底：tts_end 已到，总量不足阈值也必须立刻播（否则整句被闷死） ──
	_ok("短句 tts_end 到 → 立刻播（哪怕没攒够）", WorldScript._stream_ready_to_play(500, thr, true))
	_ok("tts_end 到且一片没攒 → 也播（空句照样收尾）", WorldScript._stream_ready_to_play(0, thr, true))

	# ── 边界：阈值为 0（极端配置）时任何字节都放行 ──
	_ok("阈值 0 → 有数据即播", WorldScript._stream_ready_to_play(1, 0, false))
	_ok("阈值 0 且无数据 → 也放行（0>=0）", WorldScript._stream_ready_to_play(0, 0, false))

	if _fails == 0:
		print("tts_prebuffer tests PASS")
	else:
		printerr("tts_prebuffer tests FAILED: %d" % _fails)
	quit(_fails)
