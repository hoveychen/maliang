extends SceneTree
## 积木式造物拼装台的客户端冒烟（B1，docs/kids-thinking-build-from-parts.md §4.2）：
## build_prompt(骨架+槽+零件盘) → 进创造视图、立拼装台预览、当前槽发光、渲零件大卡
## → 点一张零件 → 客户端权威填该槽（拼装台即时显现零件）+ 转「拼上啦」+ 回传 creation_reply
## → 下一轮 build_prompt（新槽发光，已填零件仍在）→ prop_pending(落成) 收拢拼装台。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --path . \
##       --fixed-fps 10 --quit-after 90 --script res://test/test_build_cards.gd

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
		30: _enter_fairy()
		32: _test_first_prompt()
		34: _test_pick_part()
		36: _test_second_prompt_keeps_filled()
		38: _test_landing_clears_table()
		42:
			if fails == 0:
				print("build_cards PASS")
			else:
				printerr("build_cards FAILED: %d" % fails)
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

func _preview() -> ComposedProp:
	return scene.get("_build_preview") as ComposedProp

## 首个 build_prompt：进创造视图（goal=build）、立拼装台、body 槽发光、渲两张零件卡。
func _test_first_prompt() -> void:
	scene.call("_on_build_prompt", {
		"blueprintId": "car",
		"replyText": "小车要坐得住，得有个什么呀？",
		"question": "小车要坐得住，得有个什么呀？",
		"slotId": "body",
		"options": [
			{ "id": "body_box", "label": "方箱车身", "renderRef": "part:body_box" },
			{ "id": "body_round", "label": "圆滚车身", "renderRef": "part:body_round" },
		],
		"ttsAsset": "", "voiceId": "",
	})
	_check("进入引导创造态", scene.get("_in_creation"), true)
	_check("goal=build", scene.get("_creation_goal"), "build")
	_check("记住蓝图 car", scene.get("_build_blueprint_id"), "car")
	_check("当前槽 body", scene.get("_build_slot"), "body")
	_check("创造视图点亮", (scene.get("_creation_view") as Control).visible, true)
	_check("渲出 2 张零件卡", _cards().get_child_count(), 2)
	_check("问题字幕就位", (scene.get("_creation_q") as Label).text, "小车要坐得住，得有个什么呀？")
	var pv := _preview()
	_check("拼装台预览已立", pv != null and is_instance_valid(pv), true)
	if pv != null:
		_check("当前槽 body 发光", pv.has_node("slot_glow"), true)

## 点一张零件卡：客户端权威填 body 槽（拼装台即时显现）、转「拼上啦」、清空零件盘、_build_slot 清空。
func _test_pick_part() -> void:
	scene.call("_on_creation_card", "body_box", null)
	var filled: Dictionary = scene.get("_build_filled")
	_check("body 槽已填 body_box", String((filled.get("body", {}) as Dictionary).get("partId", "")), "body_box")
	_check("填完当前槽清空(施法中不发光)", scene.get("_build_slot"), "")
	_check("转拼上啦字幕", (scene.get("_creation_q") as Label).text, "拼上啦…")
	var pv := _preview()
	if pv != null:
		_check("拼装台显现已填零件 body", pv._part_holders.has("body"), true)

## 下一轮 build_prompt（换 wheel_back 槽）：已填的 body 零件仍在，新槽发光。
func _test_second_prompt_keeps_filled() -> void:
	scene.call("_on_build_prompt", {
		"blueprintId": "car",
		"replyText": "它要能滚起来，得有什么圆圆的？",
		"question": "它要能滚起来，得有什么圆圆的？",
		"slotId": "wheel_back",
		"options": [
			{ "id": "wheel_round", "label": "圆轮子", "renderRef": "part:wheel_round" },
			{ "id": "wheel_star", "label": "星星轮子", "renderRef": "part:wheel_star" },
		],
		"ttsAsset": "", "voiceId": "",
	})
	_check("当前槽切到 wheel_back", scene.get("_build_slot"), "wheel_back")
	var pv := _preview()
	if pv != null:
		_check("已填 body 零件仍在", pv._part_holders.has("body"), true)
		_check("新槽 wheel_back 发光", pv.has_node("slot_glow"), true)

## 落成（prop_pending，goal=build）：拼装台收拢、退出创造态、出「拼好啦」横幅。
func _test_landing_clears_table() -> void:
	scene.call("_on_prop_pending", { "wallet": {} })
	_check("退出引导创造态", scene.get("_in_creation"), false)
	_check("拼装台已收", _preview() == null, true)
	_check("拼好啦横幅", (scene.get("banner") as Label).text, "拼好啦！")

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		_fail("%s: got %s want %s" % [name, str(got), str(want)])

func _fail(msg: String) -> void:
	fails += 1
	printerr("  FAIL %s" % msg)
