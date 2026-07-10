extends SceneTree
## 异步施法占位符的行为断言：开工即退出对话 + 立起占位符，成品从占位符所在的位置出来，
## 造砸了占位符要收起来（否则孩子会等一个永远不来的新朋友）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --path . \
##       --fixed-fps 10 --quit-after 120 --script res://test/test_casting_placeholder.gd

## 与 world.gd 的 PLACEHOLDER_*_ID 常量一致（GDScript 常量取不到 get()，只能对着抄）
const PORTAL_ID := "__casting_portal"
const FORGE_ID := "__casting_forge"

var scene: Node
var frame := 0
var fails := 0
var npc_node: Node = null

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
			_enter_dialog()
		32:
			_test_gen_opens_portal()
		34:
			_fire_gen_complete()
		46:
			_test_gen_complete_spawned_at_portal()
		50:
			_test_prop_pending_lights_forge()
		52:
			_test_prop_created_replaces_forge()
		60:
			_test_gen_failed_clears_portal()
		66:
			if fails == 0:
				print("casting_placeholder PASS")
			else:
				printerr("casting_placeholder FAILED: %d" % fails)
			quit(fails)

func _enter_dialog() -> void:
	var npcs: Array = scene.get("npcs")
	if npcs.is_empty():
		_fail("no npc")
		return
	npc_node = (npcs[0] as Dictionary)["node"]
	scene.call("_enter_interaction", npc_node)
	_check("先进对话", scene.get("selected") == npc_node, true)

func _placeholders() -> Dictionary:
	return scene.get("_placeholders") as Dictionary

## 造角色开工（gen_progress）：退出对话 + 立起传送门。多次 gen_progress 只立一座。
func _test_gen_opens_portal() -> void:
	scene.call("_on_gen_progress", "designing")
	_check("开工即退出对话（不把孩子钉在里面干等）", scene.get("selected"), null)
	_check("传送门已立起", _placeholders().has(PORTAL_ID), true)
	var tile: Vector2i = _placeholders()[PORTAL_ID]
	scene.call("_on_gen_progress", "rendering") # 逐阶段会来好几次
	_check("重复开工不重复立门", _placeholders()[PORTAL_ID], tile)

var _portal_want := Vector2.ZERO
var _npcs_before := 0

## 触发造角色完成（内部 await 立绘加载 + 降生，隔几帧再验）。
func _fire_gen_complete() -> void:
	var portal_tile: Vector2i = _placeholders()[PORTAL_ID]
	_portal_want = Vector2(portal_tile) * float(WorldGrid.TILE_SIZE)
	_npcs_before = (scene.get("npcs") as Array).size()
	scene.call("_on_gen_complete", {
		"character": { "id": "new-1", "name": "小紫", "isFairy": false,
			"appearance": { "spriteAsset": "", "scale": 1.0 } },
	})

## 新伙伴从传送门所在的位置降生，传送门随之收起。
func _test_gen_complete_spawned_at_portal() -> void:
	_check("传送门已收起", _placeholders().has(PORTAL_ID), false)
	var npcs: Array = scene.get("npcs")
	_check("新伙伴已降生", npcs.size(), _npcs_before + 1)
	if npcs.size() <= _npcs_before:
		return
	var born: Dictionary = npcs[npcs.size() - 1]
	var d := WorldGrid.shortest_delta(born["logical"], _portal_want).length()
	_check("新伙伴就在传送门那儿 (d=%.2f)" % d, d <= 2.0, true)

## 造物开工（prop_pending）：立起魔法熔炉。
func _test_prop_pending_lights_forge() -> void:
	scene.call("_enter_interaction", npc_node)
	scene.call("_on_prop_pending", {})
	_check("造物开工也退出对话", scene.get("selected"), null)
	_check("魔法熔炉已烧起", _placeholders().has(FORGE_ID), true)

## 成品从熔炉所在的格子出来：必须先收熔炉腾格子，否则落位失败。
func _test_prop_created_replaces_forge() -> void:
	var forge_tile: Vector2i = _placeholders()[FORGE_ID]
	scene.call("_on_prop_created", {
		"prop": { "id": "prop-1", "spec": PlaceholderSpecs.FORGE },
	})
	_check("熔炉已收起", _placeholders().has(FORGE_ID), false)
	var props: Dictionary = scene.get("world_props")
	_check("成品已入册", props.has("prop-1"), true)
	if props.has("prop-1"):
		var t: Array = (props["prop-1"] as Dictionary)["tile"]
		_check("成品落在熔炉腾出的格子上", Vector2i(int(t[0]), int(t[1])), forge_tile)

## 造砸了（gen_failed 并进 failed 信号）：传送门必须收起来。
func _test_gen_failed_clears_portal() -> void:
	scene.call("_on_gen_progress", "designing")
	_check("传送门重新立起", _placeholders().has(PORTAL_ID), true)
	scene.call("_on_failed", "moderation blocked")
	_check("造砸了传送门收起", _placeholders().has(PORTAL_ID), false)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		_fail("%s: got %s want %s" % [name, str(got), str(want)])

func _fail(msg: String) -> void:
	fails += 1
	printerr("  FAIL %s" % msg)
