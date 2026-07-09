extends SceneTree
## EdgeTts 协议纯函数单测：Sec-MS-GEC 对照 Python edge-tts 7.x 参考值 / 二进制帧解析 /
## SSML 转义 / HTTP Date 解析。全部离线；真网合成冒烟须 MALIANG_EDGE_TTS_NET=1 才跑
## （本回测默认离线，网络冒烟见文件尾注释）。
## 运行: godot --headless --path . --script res://test/test_edge_tts.gd

var _ran := false

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	# ── Sec-MS-GEC：对照 Python edge_tts.drm.DRM.generate_sec_ms_gec 固定时间戳输出 ──
	fails += _check("gec@1752000000",
		EdgeTts.gen_sec_ms_gec(1752000000.0),
		"3E89AD0C90D5D3645C2BC144E74F8125B061B3AD0581F65A550A7962A2561197")
	# 同一 5 分钟窗口内取整一致
	fails += _check("gec@1752000123 same window",
		EdgeTts.gen_sec_ms_gec(1752000123.0),
		"3E89AD0C90D5D3645C2BC144E74F8125B061B3AD0581F65A550A7962A2561197")
	# 非整秒 + 另一窗口
	fails += _check("gec@1699999999.5",
		EdgeTts.gen_sec_ms_gec(1699999999.5),
		"42301B335578FEFDAE2637DED1ABD614505D432559EC08032B82048483726AFF")

	# ── 二进制帧解析：2 字节大端 header 长度 + 头块(Path:audio) + mp3 载荷 ──
	var header := "X-RequestId:abc\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n".to_utf8_buffer()
	var payload := PackedByteArray([0xff, 0xf3, 0x01, 0x02])
	var frame := PackedByteArray([header.size() >> 8, header.size() & 0xff])
	frame.append_array(header)
	frame.append_array(payload)
	fails += _check("audio frame payload", EdgeTts.parse_audio_frame(frame), payload)

	# 非 audio 路径（turn.start 之类的二进制形状）→ 空
	var h2 := "Path:other\r\n".to_utf8_buffer()
	var f2 := PackedByteArray([h2.size() >> 8, h2.size() & 0xff])
	f2.append_array(h2)
	f2.append_array(payload)
	fails += _check("non-audio frame empty", EdgeTts.parse_audio_frame(f2), PackedByteArray())
	# 残帧（header 长度越界）→ 空，不越界崩溃
	fails += _check("truncated frame empty",
		EdgeTts.parse_audio_frame(PackedByteArray([0xff, 0xff, 0x00])), PackedByteArray())
	fails += _check("tiny frame empty", EdgeTts.parse_audio_frame(PackedByteArray([0x01])), PackedByteArray())

	# ── SSML：xml_escape 后的文本安全嵌入，音色名落位 ──
	var ssml := EdgeTts.build_ssml("小猫 & <朋友>".xml_escape(), "zh-CN-XiaoyiNeural")
	fails += _check("ssml voice", ssml.contains("name='zh-CN-XiaoyiNeural'"), true)
	fails += _check("ssml escaped", ssml.contains("小猫 &amp; &lt;朋友&gt;"), true)
	fails += _check("ssml no raw angle", ssml.contains("<朋友>"), false)

	# ── 音色映射：edge 原生名直通、legacy 映射、未知稳定哈希 ──
	fails += _check("map passthrough", EdgeTts.map_voice("zh-CN-YunjianNeural"), "zh-CN-YunjianNeural")
	fails += _check("map tw passthrough", EdgeTts.map_voice("zh-TW-HsiaoChenNeural"), "zh-TW-HsiaoChenNeural")
	fails += _check("map fairy legacy", EdgeTts.map_voice("mock-voice-cn-fairy"), "zh-CN-XiaoyiNeural")
	fails += _check("map unknown stable", EdgeTts.map_voice("weird-id"), EdgeTts.map_voice("weird-id"))

	# ── HTTP Date（RFC 2616）→ unix 秒 ──
	fails += _check("http date", EdgeTts.parse_http_date("Thu, 09 Jul 2026 08:14:00 GMT"), 1783584840)
	fails += _check("http date with prefix space", EdgeTts.parse_http_date(" Thu, 09 Jul 2026 08:14:00 GMT"), 1783584840)
	fails += _check("bad date", EdgeTts.parse_http_date("nonsense"), -1)

	# ── 真网冒烟（可选）：MALIANG_EDGE_TTS_NET=1 时探活+合成一句，校验 mp3 magic ──
	if OS.get_environment("MALIANG_EDGE_TTS_NET") == "1":
		var tts := EdgeTts.new()
		root.add_child(tts)
		var alive: bool = await tts.probe()
		fails += _check("net probe", alive, true)
		if alive:
			var mp3: PackedByteArray = await tts.synthesize("你好呀，小朋友！", "zh-CN-XiaoyiNeural")
			fails += _check("net mp3 nonempty", mp3.size() > 1000, true)
			# mp3 帧同步字 0xFFEx 或 ID3 头
			var magic_ok: bool = mp3.size() > 2 and ((mp3[0] == 0xff and (mp3[1] & 0xe0) == 0xe0) \
				or (mp3[0] == 0x49 and mp3[1] == 0x44 and mp3[2] == 0x33))
			fails += _check("net mp3 magic", magic_ok, true)
			print("net synth bytes=", mp3.size())

	if fails == 0:
		print("test_edge_tts: ALL PASS")
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("FAIL %s: got %s want %s" % [name, got, want])
	return 1
