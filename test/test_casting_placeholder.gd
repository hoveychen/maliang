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
		58:
			_test_placeholder_not_pickable()
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

## 成品从熔炉所在的格子出来：必须先收熔炉腾格子，item_place 指向那个格子
## （万物皆物品：渲染等 terrain_patch 广播，这里只验请求落点与记账）。
func _test_prop_created_replaces_forge() -> void:
	var forge_tile: Vector2i = _placeholders()[FORGE_ID]
	scene.set("online", true) # 离线世界放行 send_item_place（经 sent 信号观测）
	var placed: Array = []
	(scene.get("backend") as Backend).sent.connect(func(m: Dictionary) -> void:
		if String(m.get("type", "")) == "item_place":
			placed.append(m))
	scene.call("_on_item_created", {
		"item": { "id": "item-1", "worldId": "default", "name": "小蛋", "renderRef": "sdf_inline",
			"spec": PlaceholderSpecs.FORGE, "footprintW": 1, "footprintH": 1,
			"blocking": true, "pathOk": true, "wander": 0.0 },
		"bag": { "item-1": 1 },
	})
	scene.set("online", false)
	_check("熔炉已收起", _placeholders().has(FORGE_ID), false)
	_check("实体定义已入目录", ItemCatalog.has_def("item-1"), true)
	_check("背包已同步", int((scene.get("bag") as Dictionary).get("item-1", 0)), 1)
	_check("摆放请求已发出", placed.size(), 1)
	if placed.size() == 1:
		var t := Vector2i(int(placed[0].get("tileX", -1)), int(placed[0].get("tileY", -1)))
		_check("成品摆在熔炉腾出的格子上", t, forge_tile)

## 施法中的占位符不许被拎走：拾起判定只认矩阵物品层（tile_item_id），
## 占位符是 dynamic prop、不在矩阵里，长按候选天然排除（正例见 test_visual_props）。
func _test_placeholder_not_pickable() -> void:
	scene.call("_on_gen_progress", "designing")
	var tile: Vector2i = _placeholders()[PORTAL_ID]
	var id: String = scene.get("chunk_manager").call("dynamic_prop_at", tile)
	_check("传送门确实占着这个格子", id, PORTAL_ID)
	_check("施法占位符所在格不可拾起（矩阵无物品）", scene.call("_is_pickable_item", tile), false)

## 造砸了（gen_failed 并进 failed 信号）：传送门必须收起来。
func _test_gen_failed_clears_portal() -> void:
	_check("传送门立着", _placeholders().has(PORTAL_ID), true)
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
