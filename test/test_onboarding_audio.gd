extends SceneTree
## Onboarding 录音期必须静音 BGM,不能只 duck。
## onboarding.gd:80 起了 BGM,而自我介绍是按住大话筒说名字——外放 BGM 会被无 AEC 的
## 麦克风回灌,污染端侧 ASR 的识别结果。world.gd:1720 早就 set_music_muted(_recording)
## 了(771eb21),onboarding 当时漏改,本测试钉住二者行为一致。
## 运行: godot --headless --path . --script res://test/test_onboarding_audio.gd

var ob: Control
var _ran := false

func _initialize() -> void:
	ob = load("res://scripts/onboarding.gd").new()
	root.add_child(ob)
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	# 未录音：BGM 不静音（只可能被 duck）
	ob._intro_recording = false
	ob._process(0.001)
	fails += _check("idle: bgm not muted", ob.game_audio.muted, false)

	# 录音中：BGM 必须静音，且 duck 也应当同时生效
	ob._intro_recording = true
	ob._process(0.001)
	fails += _check("recording: bgm muted", ob.game_audio.muted, true)
	fails += _check("recording: bgm ducked too", ob.game_audio.ducked, true)

	# 录完恢复
	ob._intro_recording = false
	ob._process(0.001)
	fails += _check("after recording: unmuted", ob.game_audio.muted, false)

	if fails == 0:
		print("onboarding_audio tests PASS")
	else:
		printerr("onboarding_audio tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
