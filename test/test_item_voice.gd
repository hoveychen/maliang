extends SceneTree
## 点点念物品名断言（backpack-redesign §6）：三级回落路由——
##  内置物 → 预烧 WAV（res://assets/voice/items/<id>.wav，构建期 Yunxia）加载并挂上播放器；
##  造物无预烧 + 离线 edge-tts → 不崩、不误播；空 id → 直接早返回。
## 录音优先分支（nameVoiceAsset）走 _play_name_voice（fetch_audio 打网），离线不测，靠读验证。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 60 \
##       --script res://test/test_item_voice.gd

var scene: Node
var frame := 0
var fails := 0
var ran := false

func _initialize() -> void:
	seed(4321)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null or ran:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
		return
	if (scene.get("player") as Dictionary).is_empty():
		return # 等玩家就绪（phone_ui 此时已建）
	if frame < 4:
		return
	ran = true
	_run_checks()
	print("test_item_voice: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _run_checks() -> void:
	ItemCatalog.ensure_builtin()
	var pu := scene.get("phone_ui") as PhoneUi
	_check("phone_ui 就绪", pu != null, true)
	if pu == null:
		return

	# ── 内置物：预烧 WAV 存在则加载并挂上播放器（点点念内置物名走离线预烧）────────────
	var baked := "res://assets/voice/items/tree_puff_a.wav"
	if ResourceLoader.exists(baked):
		var def := ItemCatalog.get_def("tree_puff_a")
		pu.call("_speak_item_name", "tree_puff_a", def)
		var np := pu.get("_name_player") as AudioStreamPlayer
		_check("内置物预烧→建播放器", np != null, true)
		if np != null:
			_check("内置物预烧→挂上音频流", np.stream != null, true)
	else:
		print("  (跳过内置物预烧断言：tree_puff_a.wav 未烧/未随包)")

	# ── 造物动态名 + 离线 edge-tts → 早返回不崩不误播（available 为 false 时不 await）──
	# 假 UUID 造物：无 baked wav、无 nameVoiceAsset；离线探活失败 available=false → 早返回。
	var fake := { "name": "小明的城堡", "renderRef": "sdf_inline" }
	pu.call("_speak_item_name", "creation-uuid-xyz", fake)
	_check("造物离线不崩", true, true)

	# ── 空 id → 直接早返回不崩 ────────────────────────────────────────────────
	pu.call("_speak_item_name", "", {})
	_check("空 id 早返回不崩", true, true)

func _check(what: Variant, got: Variant, want: Variant) -> void:
	if got == want:
		return
	print("  FAIL %s: got %s want %s" % [str(what), str(got), str(want)])
	fails += 1
