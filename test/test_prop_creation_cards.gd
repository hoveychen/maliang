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
		37:
			_test_after_click_cleared() # queue_free 隔帧才生效，下一帧再验
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

func _cards() -> GridContainer:
	return scene.get("_creation_cards") as GridContainer

func _view() -> Control:
	return scene.get("_creation_view") as Control

## 物品追问 creation_prompt：进专门创造视图（暗底显现、退出普通对话构图），中央渲 3 张大卡。
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
	_check("创造视图点亮", _view().visible, true)
	_check("相机进特写态", scene.get("_creation_cam"), true)
	_check("退出普通对话构图（横幅隐）", (scene.get("banner") as Label).visible, false)
	_check("居中渲出 3 张大卡", _cards().get_child_count(), 3)
	_check("2×2 网格布局（columns=2）", _cards().columns, 2)
	_check("问题字幕就位", (scene.get("_creation_q") as Label).text, "你想变出什么呀？")
	_check("进度点亮一颗", (scene.get("_creation_dots") as HBoxContainer).get_child_count(), 1)

## 点一张卡：转「施法中…」，视图仍留着等下一轮/成品（不整屏收起）。
func _test_click_card_replies() -> void:
	scene.call("_on_creation_card", "prop_pinwheel")
	_check("点卡后视图仍在（等下一轮）", _view().visible, true)
	_check("转施法中字幕", (scene.get("_creation_q") as Label).text, "施法中…")

## queue_free 隔帧生效后：大卡已清空；再验造好/退出整屏收起 + 复位相机。
func _test_after_click_cleared() -> void:
	_check("点卡后清空大卡", _cards().get_child_count(), 0)
	scene.call("_hide_creation_cards")
	_check("收起后视图隐藏", _view().visible, false)
	_check("收起后相机复位", scene.get("_creation_cam"), false)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		_fail("%s: got %s want %s" % [name, str(got), str(want)])

func _fail(msg: String) -> void:
	fails += 1
	printerr("  FAIL %s" % msg)
