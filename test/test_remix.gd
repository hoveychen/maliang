extends SceneTree
## 复用改装的客户端冒烟（B1，docs/kids-thinking-build-from-parts.md §3.1）：
## 物品页点组合物 → 弹「摆到世界 / 拆开改改」二选一 → 拆开改改进拼装台（预填原零件）
## → 兼容零件表到货 → 点某槽 → 换一个零件（预览即时更新）→ 做好了 → 发 create_build
## （编辑后的零件树，换掉的槽变了、没动的槽保持）。也覆盖取消路径（不发 create_build）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --path . \
##       --fixed-fps 10 --quit-after 90 --script res://test/test_remix.gd

var scene: Node
var frame := 0
var fails := 0
var _sent: Array = [] ## backend 出站消息侦听（验 create_build 载荷）

const ITEM_ID := "remix_test_car"

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
		30: _seed_composed_item()
		32: _test_tap_pops_choice()
		34: _test_begin_remix_prefills()
		36: _feed_options()
		38: _test_pick_slot_glows()
		40: _test_swap_updates_tree()
		42: _test_confirm_sends_edited_tree()
		44: _test_cancel_sends_nothing()
		48:
			if fails == 0:
				print("remix PASS")
			else:
				printerr("remix FAILED: %d" % fails)
			quit(fails)

## 造一个组合物（小车四槽全填）塞进目录 + 背包，并把 backend.sent 侦听起来。online=true 让改装可进。
func _seed_composed_item() -> void:
	var def := {
		"id": ITEM_ID, "worldId": "default", "name": "小车", "renderRef": "composed:",
		"spec": { "blueprintId": "car", "parts": [
			{ "slotId": "body", "partId": "body_box", "partRenderRef": "part:body_box" },
			{ "slotId": "wheel_back", "partId": "wheel_round", "partRenderRef": "part:wheel_round" },
			{ "slotId": "wheel_front", "partId": "wheel_round", "partRenderRef": "part:wheel_round" },
			{ "slotId": "handle", "partId": "handle_curve", "partRenderRef": "part:handle_curve" },
		] },
	}
	ItemCatalog.set_defs([def])
	scene.set("bag", { ITEM_ID: 1 })
	scene.set("online", true)
	var backend = scene.get("backend")
	backend.sent.connect(func(obj: Dictionary) -> void: _sent.append(obj))

## 点组合物 → 弹二选一小卡（两张大按钮就位）。
func _test_tap_pops_choice() -> void:
	scene.call("_on_composed_item_tapped", ITEM_ID)
	var choice := scene.get("_remix_choice") as Control
	_check("二选一小卡弹出", choice != null and is_instance_valid(choice), true)
	if choice != null:
		_check("有『摆到世界』按钮", choice.find_child("RemixChoicePlace", true, false) != null, true)
		_check("有『拆开改改』按钮", choice.find_child("RemixChoiceRemix", true, false) != null, true)

## 选「拆开改改」→ 进拼装台，预填原来的四个零件，做好了按钮就位。
func _test_begin_remix_prefills() -> void:
	scene.call("_close_remix_choice")
	scene.call("_begin_remix", ITEM_ID)
	_check("进入改装态", scene.get("_remixing"), true)
	_check("不进 LLM 会话态", scene.get("_in_creation"), false)
	_check("记住蓝图 car", scene.get("_build_blueprint_id"), "car")
	var filled: Dictionary = scene.get("_build_filled")
	_check("预填 4 个槽", filled.size(), 4)
	_check("后轮原为 wheel_round", String((filled.get("wheel_back", {}) as Dictionary).get("partId", "")), "wheel_round")
	_check("创造视图点亮", (scene.get("_creation_view") as Control).visible, true)
	var pv := scene.get("_build_preview") as ComposedProp
	_check("拼装台预览已立", pv != null and is_instance_valid(pv), true)
	if pv != null:
		_check("预览含后轮零件", pv._part_holders.has("wheel_back"), true)
	var cbtn := scene.get("_remix_confirm_btn") as Button
	_check("做好了按钮就位", cbtn != null and cbtn.visible, true)
	_check("槽列表渲出 4 张卡", _live_cards(), 4)

## 服务端兼容零件表到货（模拟 build_options 回执）。
func _feed_options() -> void:
	scene.call("_on_build_options", {
		"blueprintId": "car",
		"options": {
			"body": [
				{ "id": "body_box", "label": "方箱车身", "renderRef": "part:body_box" },
				{ "id": "body_round", "label": "圆滚车身", "renderRef": "part:body_round" },
			],
			"wheel_back": [
				{ "id": "wheel_round", "label": "圆轮子", "renderRef": "part:wheel_round" },
				{ "id": "wheel_star", "label": "星星轮子", "renderRef": "part:wheel_star" },
			],
			"wheel_front": [
				{ "id": "wheel_round", "label": "圆轮子", "renderRef": "part:wheel_round" },
				{ "id": "wheel_star", "label": "星星轮子", "renderRef": "part:wheel_star" },
			],
			"handle": [
				{ "id": "handle_curve", "label": "弯把手", "renderRef": "part:handle_curve" },
				{ "id": "handle_straight", "label": "直把手", "renderRef": "part:handle_straight" },
			],
		},
	})
	_check("仍在槽列表阶段", scene.get("_remix_stage"), "slots")

## 点后轮槽 → 进零件挑选、该槽发光、零件盘弹出（返回卡 + 两个兼容轮子）。
func _test_pick_slot_glows() -> void:
	scene.call("_remix_pick_slot", "wheel_back")
	_check("切到挑零件阶段", scene.get("_remix_stage"), "parts")
	_check("正在改后轮槽", scene.get("_remix_slot"), "wheel_back")
	var pv := scene.get("_build_preview") as ComposedProp
	if pv != null:
		_check("后轮槽发光", pv.has_node("slot_glow"), true)
	# 返回卡 + 2 个轮子 = 3 张（只数活着的：上一屏的槽卡 queue_free 是延迟的，同帧还在）
	_check("零件盘 3 张(返回+2轮子)", _live_cards(), 3)

## 换成星星轮子 → 零件树更新、预览即时坐进新零件、回槽列表。
func _test_swap_updates_tree() -> void:
	scene.call("_remix_swap", "wheel_back", "wheel_star", "part:wheel_star")
	var filled: Dictionary = scene.get("_build_filled")
	_check("后轮换成 wheel_star", String((filled.get("wheel_back", {}) as Dictionary).get("partId", "")), "wheel_star")
	_check("前轮没动仍 wheel_round", String((filled.get("wheel_front", {}) as Dictionary).get("partId", "")), "wheel_round")
	_check("换完回槽列表", scene.get("_remix_stage"), "slots")
	var pv := scene.get("_build_preview") as ComposedProp
	if pv != null:
		_check("预览含后轮零件", pv._part_holders.has("wheel_back"), true)

## 做好了 → 发 create_build，载荷是编辑后的零件树（后轮变星星、其余不变）；改装态收摊。
func _test_confirm_sends_edited_tree() -> void:
	_sent.clear()
	scene.call("_remix_confirm")
	var cb: Dictionary = {}
	for m in _sent:
		if String((m as Dictionary).get("type", "")) == "create_build":
			cb = m
	_check("发出 create_build", not cb.is_empty(), true)
	if not cb.is_empty():
		_check("蓝图 car", String(cb.get("blueprintId", "")), "car")
		var f: Dictionary = cb.get("filled", {})
		_check("后轮送的是 wheel_star", String(f.get("wheel_back", "")), "wheel_star")
		_check("车身没动仍 body_box", String(f.get("body", "")), "body_box")
		_check("载荷是 partId 扁平表(非嵌套)", typeof(f.get("wheel_back")), TYPE_STRING)
	_check("改装态收摊", scene.get("_remixing"), false)
	_check("拼装台已收", scene.get("_build_preview") == null, true)

## 取消路径：再进改装 → 点右上角叉（_on_creation_cancel_pressed）→ 不发 create_build、态收摊。
func _test_cancel_sends_nothing() -> void:
	scene.call("_begin_remix", ITEM_ID)
	_check("再次进入改装态", scene.get("_remixing"), true)
	_sent.clear()
	scene.call("_on_creation_cancel_pressed")
	var any_cb := false
	for m in _sent:
		if String((m as Dictionary).get("type", "")) == "create_build":
			any_cb = true
	_check("取消不发 create_build", any_cb, false)
	_check("取消后改装态收摊", scene.get("_remixing"), false)

## 只数还活着的卡（queue_free 延迟到帧末，同帧重建时旧卡仍在，会误计数）。
func _live_cards() -> int:
	var n := 0
	for c in (scene.get("_creation_cards") as GridContainer).get_children():
		if not c.is_queued_for_deletion():
			n += 1
	return n

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		_fail("%s: got %s want %s" % [name, str(got), str(want)])

func _fail(msg: String) -> void:
	fails += 1
	printerr("  FAIL %s" % msg)
