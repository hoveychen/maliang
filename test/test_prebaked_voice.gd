extends SceneTree
## 预制台词的音色契约：fairy/ 与 onboarding/ 的旁白说话人都是小仙子，
## 两份 lines.json 的 voice 必须等于仙子运行期音色（edge_tts.gd 的映射），
## 否则会出现"引导流程一个声音、进世界另一个声音"（onboarding 曾停在 MiniMax lovely_girl）。
## 同时钉住：voice 必须是 edge 原生音色名，gen_voice_lines.mjs 直接把它塞进 SSML，
## 写成 MiniMax/Kokoro 的旧名字会请求微软失败。
## 运行: godot --headless --path . --script res://test/test_prebaked_voice.gd

const VOICE_DIRS := ["res://assets/voice/fairy", "res://assets/voice/onboarding"]
const MIN_LEN_S := 0.3

func _init() -> void:
	var fails := 0

	# 仙子运行期音色：服务端下发 voiceId，客户端 edge_tts.gd 映射后交给微软。
	# 这里用客户端映射表当单一真相源，避免测试里再硬编码一个音色名。
	var fairy_voice: String = EdgeTts.map_voice("mock-voice-cn-fairy")
	fails += _check("fairy runtime voice is edge native", fairy_voice.begins_with("zh-"), true)

	for dir in VOICE_DIRS:
		var path := "%s/lines.json" % dir
		var raw := FileAccess.get_file_as_string(path)
		if raw.is_empty():
			printerr("  FAIL missing %s" % path)
			fails += 1
			continue
		var spec: Dictionary = JSON.parse_string(raw)
		var voice := String(spec.get("voice", ""))

		# 契约一：预制音色 == 仙子运行期音色（说话人是同一个仙子）。
		fails += _check("%s voice == fairy runtime" % dir, voice, fairy_voice)
		# 契约二：必须是 edge 原生名，否则 gen_voice_lines.mjs 重跑会炸。
		fails += _check("%s voice is edge native" % dir, voice.begins_with("zh-"), true)

		# 契约三：每条词条都有可加载、非空的预制 WAV（防加词条忘跑生成器）。
		for line in spec["lines"]:
			var id := String(line["id"])
			var wav := "%s/%s.wav" % [dir, id]
			var stream: AudioStream = load(wav)
			if stream == null:
				printerr("  FAIL cannot load %s" % wav)
				fails += 1
				continue
			if stream.get_length() <= MIN_LEN_S:
				printerr("  FAIL %s too short: %.2fs" % [id, stream.get_length()])
				fails += 1

	if fails == 0:
		print("prebaked_voice tests PASS")
	else:
		printerr("prebaked_voice tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
