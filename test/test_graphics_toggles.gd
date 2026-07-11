extends SceneTree
## 画质设置页断言：设置 app 里有画质分区 6 个 toggle；切一个开关即时应用到场景
## （chunk_manager 记忆态）+ 存进 profile（has_saved 变真、值往返）。
## 备份并恢复真实档案（不污染开发机 user://profile.json）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_graphics_toggles.gd

var scene: Node
var frame := 0
var fails := 0
var _backup: Dictionary

func _initialize() -> void:
	_backup = PlayerProfile.load_profile()
	PlayerProfile.clear()  # 干净起步：无 graphics 档 → 默认全开
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _gfx() -> Dictionary:
	return scene.get("_gfx_buttons") as Dictionary

func _tick() -> void:
	frame += 1
	match frame:
		1:
			root.size = Vector2i(1280, 720)
		8:
			scene.call("_open_app", "settings")
			var g := _gfx()
			_check("画质按钮 6 个", g.size(), 6)
			var all_toggle := true
			for k: String in g:
				if not (g[k] as Button).toggle_mode:
					all_toggle = false
			_check("都是 toggle 模式", all_toggle, true)
			_check("默认全开：角色阴影 pressed", (g["actor_shadows"] as Button).button_pressed, true)
		12:
			# 关「地面阴影」→ 程序化改 button_pressed 会 emit toggled → 应用 + 存档
			(_gfx()["ground_shadows"] as Button).button_pressed = false
		14:
			var cm: Object = scene.get("chunk_manager")
			_check("地面阴影关→chunk 记忆态 false", cm.get("_ground_shadows"), false)
			_check("存档 ground_shadows=false", GraphicsSettings.load_all()["ground_shadows"], false)
			_check("其余项仍存为开(actor_shadows)", GraphicsSettings.load_all()["actor_shadows"], true)
			_check("has_saved 变真", GraphicsSettings.has_saved(), true)
		18:
			if _backup.is_empty():
				PlayerProfile.clear()
			else:
				PlayerProfile.save_profile(_backup)
			if fails == 0:
				print("graphics_toggles PASS")
			else:
				printerr("graphics_toggles FAILED: %d" % fails)
		20:
			quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
