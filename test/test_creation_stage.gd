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
			_test_cancelled_clears_stage()
		40:
			_test_prop_goal_lights_forge()
		42:
			_test_walk_away_clears_stage()
		46:
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

## 服务端判「算了/不要了」→ creation_cancelled：收视图 + 收蛋，但不退出对话（孩子还能接着跟仙子说话）。
func _test_cancelled_clears_stage() -> void:
	scene.call("_on_creation_cancelled", { "replyText": "好呀，那我们不造啦", "ttsAsset": "", "voiceId": "" })
	_check("退出引导创造态", scene.get("_in_creation"), false)
	_check("创造视图收起", _view().visible, false)
	_check("相机特写复位", scene.get("_creation_cam"), false)
	_check("降生蛋已收走", _placeholders().has(PORTAL_ID), false)
	_check("取消的是创造、不是对话（仍在仙子面前）", scene.get("selected") != null, true)

## goal=prop 的引导：立的是魔法熔炉，不是蛋。
func _test_prop_goal_lights_forge() -> void:
	_prompt("prop")
	_check("造物烧起魔法熔炉", _placeholders().has(FORGE_ID), true)
	_check("造物不立降生蛋", _placeholders().has(PORTAL_ID), false)

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
