extends SceneTree
## 引导式造物的客户端冒烟：creation_prompt(物品图标选项) → 渲染选项卡 → 点一张 → 收起 + 进思考态。
## 客户端渲染是 goal-agnostic 的（造角色/造物同一路径），这里用物品形状的选项做回归锚。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --path . \
##       --fixed-fps 10 --quit-after 90 --script res://test/test_prop_creation_cards.gd

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
	match frame:
		30:
			_enter_fairy()
		32:
			_test_prompt_renders_cards()
		34:
			_test_click_card_replies()
		40:
			if fails == 0:
				print("prop_creation_cards PASS")
			else:
				printerr("prop_creation_cards FAILED: %d" % fails)
			quit(fails)

func _enter_fairy() -> void:
	var fairy: Dictionary = scene.call("_find_fairy")
	if fairy.is_empty():
		_fail("没有小仙子")
		return
	scene.call("_enter_interaction", fairy["node"])
	_check("已进入与仙子的交互", scene.get("selected") == fairy["node"], true)

func _cards() -> HBoxContainer:
	return scene.get("_creation_cards") as HBoxContainer

## 物品追问 creation_prompt：3 张物品种类卡应渲染出来，会话进入 _in_creation。
func _test_prompt_renders_cards() -> void:
	scene.call("_on_creation_prompt", {
		"replyText": "你想变出什么呀？",
		"question": "你想变出什么呀？",
		"category": "kind",
		"options": [
			{ "id": "prop_flower", "label": "小花", "iconAsset": "" },
			{ "id": "prop_pinwheel", "label": "风车", "iconAsset": "" },
			{ "id": "prop_house", "label": "小房子", "iconAsset": "" },
		],
		"ttsAsset": "", "voiceId": "",
	})
	_check("进入引导创造态", scene.get("_in_creation"), true)
	_check("渲染出 3 张选项卡", _cards().get_child_count(), 3)
	_check("选项卡可见", _cards().visible, true)

## 点一张卡：收起卡片、转「施法中…」思考态（答复经 send_creation_reply 发出，离线下静默）。
func _test_click_card_replies() -> void:
	scene.call("_on_creation_card", "prop_pinwheel")
	_check("点卡后收起选项卡", _cards().visible, false)
	_check("点卡后进入思考态", (scene.get("thinking_label") as Label).visible, true)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		_fail("%s: got %s want %s" % [name, str(got), str(want)])

func _fail(msg: String) -> void:
	fails += 1
	printerr("  FAIL %s" % msg)
