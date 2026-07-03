extends SceneTree
## 主菜单验证：渲染出标题+出发按钮（无档案时无继续按钮），按下出发切到世界场景。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie screenshots/menu/f.png \
##       --fixed-fps 10 --quit-after 50 --script res://test/test_visual_menu.gd

var frame := 0
var fails := 0
var menu: Node

func _initialize() -> void:
	menu = load("res://menu.tscn").instantiate()
	root.add_child(menu)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	match frame:
		15:
			var buttons: Array[Node] = menu.find_children("*", "Button", true, false)
			_check("one big button (no profile)", buttons.size(), 1)
			var labels: Array[Node] = menu.find_children("*", "Label", true, false)
			var has_title := false
			for l in labels:
				if (l as Label).text.contains("马良"):
					has_title = true
			_check("title present", has_title, true)
			if not buttons.is_empty():
				(buttons[0] as Button).emit_signal("pressed")
		40:
			# change_scene_to_file 挂到当前场景；World 场景根名为 "World"
			var cur := current_scene
			_check("switched to world", cur != null and cur.name == "World", true)
			if fails == 0:
				print("visual_menu PASS")
			else:
				printerr("visual_menu FAILED: %d" % fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
