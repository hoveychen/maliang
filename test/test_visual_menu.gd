extends SceneTree
## 主菜单验证：全屏任点单入口——渲染出标题+脉动提示箭头+全屏透明按钮（永远只有 1 个），
## 点击后按档案分流：无档案 → onboarding（根名 "Onboarding"），有档案 → 世界（根名 "World"）。
## 期望值按测试机当下 PlayerProfile.exists() 动态计算，不动真实档案文件。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie screenshots/menu/f.png \
##       --fixed-fps 10 --quit-after 50 --script res://test/test_visual_menu.gd

var frame := 0
var fails := 0
var menu: Node
var expect_root := ""

func _initialize() -> void:
	expect_root = "World" if PlayerProfile.exists() else "Onboarding"
	menu = load("res://menu.tscn").instantiate()
	root.add_child(menu)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	match frame:
		15:
			var buttons: Array[Node] = menu.find_children("*", "Button", true, false)
			_check("single full-screen tap button", buttons.size(), 1)
			if not buttons.is_empty():
				var tap := buttons[0] as Button
				_check("tap covers full rect", tap.size, (menu as Control).size)
				_check("tap button textless", tap.text, "")
			var labels: Array[Node] = menu.find_children("*", "Label", true, false)
			var has_title := false
			for l in labels:
				if (l as Label).text.contains("马良"):
					has_title = true
			_check("title present", has_title, true)
			var hints: Array[Node] = menu.find_children("*", "TextureRect", true, false)
			var has_hint := false
			for h in hints:
				if (h as TextureRect).texture == UiAssets.tex("ic_next"):
					has_hint = true
			_check("pulsing hint arrow present", has_hint, true)
			if not buttons.is_empty():
				(buttons[0] as Button).emit_signal("pressed")
		40:
			# 任点 → 按档案分流（无档案走童话书，有档案直进世界）
			var cur := current_scene
			_check("switched to %s" % expect_root, cur != null and cur.name == expect_root, true)
			if fails == 0:
				print("visual_menu PASS")
			else:
				printerr("visual_menu FAILED: %d" % fails)
		45:
			quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
