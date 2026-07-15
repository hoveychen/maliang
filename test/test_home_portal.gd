extends SceneTree
## 回家临时门 P2（home-portal-anim）：召唤(埋地下) → 按 rise 从地下升起 → 消散释放。
## SdfProp 禁缩放（sdf_prop.gd 契约），召唤/消散靠 position.y 平移，地面不透明网格裁掉埋下的部分。
## 断言与地形高度解耦：只比较 rise=1 与 rise=0 的门 y 差，应恰等于 HOME_PORTAL_SINK(=3.6)。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 30 \
##       --script res://test/test_home_portal.gd

const SINK := 3.6  ## 须与 world.gd 的 HOME_PORTAL_SINK 一致（无 class_name，无法直接引用）

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
		root.size = Vector2i(640, 480)
		scene.set("online", false)
		return
	match frame:
		10:
			var rec: Dictionary = scene.call("_summon_home_portal", Vector2i(2, 2))
			_check("召唤返回门记录", not rec.is_empty(), true)
			_check("_home_portals 有 1 座", (scene.get("_home_portals") as Array).size(), 1)
			var node: Node3D = rec.get("node") as Node3D
			_check("门节点已入树", is_instance_valid(node) and node.is_inside_tree(), true)
			if not is_instance_valid(node):
				return
			# rise=0：埋地下
			rec["rise"] = 0.0
			scene.call("_update_home_portals")
			var y_sunk := node.position.y
			# rise=1：升到地面
			rec["rise"] = 1.0
			scene.call("_update_home_portals")
			var y_up := node.position.y
			_check("升起后门比埋地下时高", y_up > y_sunk, true)
			_check_near("升起平移量 == HOME_PORTAL_SINK", y_up - y_sunk, SINK, 0.01)
			# rise=0.5：半程恰在中点
			rec["rise"] = 0.5
			scene.call("_update_home_portals")
			_check_near("半程 y 在升起中点", node.position.y - y_sunk, SINK * 0.5, 0.01)
		12:
			scene.call("_dispel_home_portals")
			_check("消散后 _home_portals 清空", (scene.get("_home_portals") as Array).size(), 0)
		14:
			_finish()

func _finish() -> void:
	print("home_portal ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	if is_instance_valid(scene):
		scene.queue_free()
	scene = null
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok ", name)
	else:
		printerr("  ✗ %s: got %s, want %s" % [name, got, want])
		fails += 1

func _check_near(name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) <= tol:
		print("  ok ", name)
	else:
		printerr("  ✗ %s: got %f, want %f (±%f)" % [name, got, want, tol])
		fails += 1
