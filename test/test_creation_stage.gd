extends SceneTree
## 创造引导「舞台化」：引导一开始（首个 creation_prompt）就在仙子身旁立起蛋/炉，
## 孩子的每个回答被扔进去；取消（服务端判语义 / 点右上角叉 / 走开）都要把蛋/炉收走。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --path . \
##       --fixed-fps 10 --quit-after 150 --script res://test/test_creation_stage.gd

## 与 world.gd 的 PLACEHOLDER_*_ID 常量一致（GDScript 常量取不到 get()，只能对着抄）
const PORTAL_ID := "__casting_portal"
const FORGE_ID := "__casting_forge"

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
			_test_prompt_raises_egg()
		34:
			_test_second_prompt_keeps_same_egg()
		36:
			_test_card_flies_into_egg()
		38:
			_test_cancel_button_clears_stage()
		39:
			_enter_fairy() # 取消已退出对话：重新走过去，验下一条路径
		40:
			_test_prop_goal_lights_forge()
		42:
			_test_voice_answer_flies_in()
		44:
			_test_cancelled_clears_stage()
		45:
			_enter_fairy()
		46:
			_prompt("prop") # 再开一次，验走开路径
		48:
			_test_walk_away_clears_stage()
		52:
			if fails == 0:
				print("creation_stage PASS")
			else:
				printerr("creation_stage FAILED: %d" % fails)
			quit(fails)

func _placeholders() -> Dictionary:
	return scene.get("_placeholders") as Dictionary

func _view() -> Control:
	return scene.get("_creation_view") as Control

func _fairy() -> Dictionary:
	return scene.call("_find_fairy")

func _enter_fairy() -> void:
	var fairy := _fairy()
	if fairy.is_empty():
		_fail("没有小仙子")
		return
	scene.call("_enter_interaction", fairy["node"])
	_check("已进入与仙子的交互", scene.get("selected") == fairy["node"], true)

func _prompt(goal: String) -> void:
	scene.call("_on_creation_prompt", {
		"goal": goal,
		"replyText": "你想要什么样的小伙伴呀？",
		"question": "你想要什么样的小伙伴呀？",
		"category": "kind",
		"options": [
			{ "id": "cat", "label": "小猫", "iconAsset": "" },
			{ "id": "dog", "label": "小狗", "iconAsset": "" },
		],
		"ttsAsset": "", "voiceId": "",
	})

## 首轮追问就把降生蛋立起来（不再等到服务端开造），且它就在仙子身旁——与她同框，孩子看得见。
func _test_prompt_raises_egg() -> void:
	_prompt("character")
	_check("进入引导创造态", scene.get("_in_creation"), true)
	_check("降生蛋已立起（引导一开始，不等开造）", _placeholders().has(PORTAL_ID), true)
	_check("造角色不烧熔炉", _placeholders().has(FORGE_ID), false)
	if not _placeholders().has(PORTAL_ID):
		return
	var tile: Vector2i = _placeholders()[PORTAL_ID]
	var at := Vector2(tile) * float(WorldGrid.TILE_SIZE)
	var d := WorldGrid.shortest_delta(at, _fairy().get("logical", Vector2.ZERO)).length()
	_check("蛋就立在仙子身旁 (d=%.2f)" % d, d <= 6.0, true)

## 后续每轮追问都会调 _raise_creation_placeholder：必须幂等，不许再立一个。
func _test_second_prompt_keeps_same_egg() -> void:
	var tile: Vector2i = _placeholders()[PORTAL_ID]
	_prompt("character")
	_check("第二轮追问不重复立蛋", _placeholders()[PORTAL_ID], tile)

## 飞行特效节点（挂 HUD 层，名字以 ThrowFx 开头；同名重复 Godot 会加后缀）。
func _throw_fx() -> Array:
	var found: Array = []
	var hud := scene.get("_hud_layer") as CanvasLayer
	if hud == null:
		return found
	for c in hud.get_children():
		if String(c.name).begins_with("ThrowFx"):
			found.append(c)
	return found

## 点一张卡：卡片被「扔」进蛋——起飞的是一张同款卡，落点是蛋的屏幕投影（孩子看见回答被吃进去）。
func _test_card_flies_into_egg() -> void:
	var cards := scene.get("_creation_cards") as GridContainer
	if cards.get_child_count() == 0:
		_fail("没有选项卡可点")
		return
	var card := cards.get_child(0) as Button
	var target: Vector2 = scene.call("_placeholder_screen_pos")
	_check("蛋在屏幕上有落点（不在镜头外）", target != Vector2.INF, true)
	scene.call("_on_creation_card", "cat", card)
	var fx := _throw_fx()
	_check("答案卡已起飞（ThrowFx 在 HUD 层）", fx.size(), 1)
	if fx.size() == 1:
		var d := (fx[0] as Control).global_position.distance_to(target)
		_check("起飞点在卡片处、还没到蛋 (d=%.0f)" % d, d > 40.0, true)

## 右上角圆叉：随时退出创造——蛋收走、视图收起，并退出对话回到自由跑动。
func _test_cancel_button_clears_stage() -> void:
	var btn := scene.get("_creation_cancel_btn") as Button
	_check("创造视图上有取消按钮", btn != null, true)
	if btn == null:
		return
	btn.emit_signal("pressed")
	_check("退出引导创造态", scene.get("_in_creation"), false)
	_check("创造视图收起", _view().visible, false)
	_check("降生蛋已收走", _placeholders().has(PORTAL_ID), false)
	_check("取消即退出对话", scene.get("selected"), null)

## goal=prop 的引导：立的是魔法熔炉，不是蛋。
func _test_prop_goal_lights_forge() -> void:
	_prompt("prop")
	_check("造物烧起魔法熔炉", _placeholders().has(FORGE_ID), true)
	_check("造物不立降生蛋", _placeholders().has(PORTAL_ID), false)

## 语音答复（没点卡，直接说）：断句提交时也飞一个气泡进炉——两条答复路径视觉一致。
func _test_voice_answer_flies_in() -> void:
	# 模拟「开口→说完断句」：走 VoiceCapture 一轮，committed 触发 world 的 _throw_voice_answer。
	var vc: Object = scene.get("_vc")
	vc.call("_utterance_begin", PackedByteArray())
	vc.call("_utterance_commit")
	_check("语音答复也起飞了气泡", _throw_fx().size() >= 1, true)

## 服务端判「算了/不要了」→ creation_cancelled：收视图 + 收炉 + 退出对话（老板拍板：取消=退出这个状态）。
func _test_cancelled_clears_stage() -> void:
	scene.call("_on_creation_cancelled", { "replyText": "好呀，那我们不造啦", "ttsAsset": "", "voiceId": "" })
	_check("退出引导创造态", scene.get("_in_creation"), false)
	_check("创造视图收起", _view().visible, false)
	_check("相机特写复位", scene.get("_creation_cam"), false)
	_check("魔法熔炉已收走", _placeholders().has(FORGE_ID), false)
	_check("取消即退出对话", scene.get("selected"), null)

## 孩子直接走开（退出对话）：会话取消上报服务端，地上的熔炉也要收走，不留空烧的炉子。
func _test_walk_away_clears_stage() -> void:
	var cancels: Array = []
	(scene.get("backend") as Backend).sent.connect(func(m: Dictionary) -> void:
		if String(m.get("type", "")) == "creation_cancel":
			cancels.append(m))
	scene.set("online", true) # 离线世界不发消息，这里要观测上报
	scene.call("_exit_interaction")
	scene.set("online", false)
	_check("走开=取消会话（已上报服务端）", cancels.size(), 1)
	_check("熔炉跟着收走", _placeholders().has(FORGE_ID), false)
	_check("已退出对话", scene.get("selected"), null)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		_fail("%s: got %s want %s" % [name, str(got), str(want)])

func _fail(msg: String) -> void:
	fails += 1
	printerr("  FAIL %s" % msg)
