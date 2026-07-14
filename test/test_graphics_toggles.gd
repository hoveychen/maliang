extends SceneTree
## 画质设置页断言（分级模型）：设置 app 里有画质分区 9 个旋钮；点一下升一档/到顶回最省；
## 改档即时应用到场景（chunk_manager 记忆态、viewport 缩放、SdfProp/PaperCharacter 静态态）
## + 存进 profile（source=user、值往返）。新暴露的三个旋钮（prop_detail/terrain_detail/xray）
## 与 hi_res 三级是本轮重点。备份并恢复真实档案（不污染开发机 user://profile.json）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_graphics_toggles.gd

var scene: Node
var frame := 0
var fails := 0
var _backup: Dictionary

func _initialize() -> void:
	_backup = PlayerProfile.load_profile()
	PlayerProfile.clear()  # 干净起步：无 graphics 档 → 默认全最高档
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _gfx() -> Dictionary:
	return (scene.get("phone_ui") as PhoneUi).get("_gfx_buttons") as Dictionary

func _tick() -> void:
	frame += 1
	match frame:
		1:
			root.size = Vector2i(1280, 720)
		8:
			scene.call("_open_app", "settings")
			var g := _gfx()
			_check("画质旋钮 = 全键数(9性能+1样式)", g.size(), GraphicsSettings.all_keys().size())
			for k: String in GraphicsSettings.all_keys():
				if not g.has(k):
					_check("缺旋钮 %s" % k, false, true)
			_check("默认全最高：角色阴影按下", (g["actor_shadows"] as Button).button_pressed, true)
			_check("按钮只显示档名", (g["hi_res"] as Button).text, "高清")
			_check("每个旋钮卡片带 subtitle 说明", _subtitles_present(), true)
		12:
			# 关「地面阴影」（2 级：点一下 1→0）
			(_gfx()["ground_shadows"] as Button).button_pressed = false
		14:
			var cm: Object = scene.get("chunk_manager")
			_check("地面阴影关→chunk 记忆态 false", cm.get("_ground_shadows"), false)
			_check("存档 ground_shadows=0", GraphicsSettings.load_all()["ground_shadows"], 0)
			_check("其余项仍最高(actor_shadows)", GraphicsSettings.load_all()["actor_shadows"], 1)
			_check("has_saved 变真", GraphicsSettings.has_saved(), true)
			_check("设置页改动 = user override", GraphicsSettings.is_user_override(), true)
			# hi_res 三级循环：高清(2) 点一下 →(2+1)%3=0 省电
			(_gfx()["hi_res"] as Button).button_pressed = false
		16:
			_check("hi_res 2→0 存档", GraphicsSettings.load_all()["hi_res"], 0)
			_check("hi_res=0 → 缩放 0.6", is_equal_approx(scene.get_viewport().scaling_3d_scale, 0.6), true)
			_check("按钮文案跟到省电", (_gfx()["hi_res"] as Button).text, "省电")
			_check("0 档按钮非按下态", (_gfx()["hi_res"] as Button).button_pressed, false)
			# 新暴露的三个旋钮：各关一次，断言真的落到底层静态态
			(_gfx()["xray"] as Button).button_pressed = false
			(_gfx()["prop_detail"] as Button).button_pressed = false
			(_gfx()["terrain_detail"] as Button).button_pressed = false
		18:
			_check("xray 关 → PaperCharacter 静态态 false", PaperCharacter._xray_enabled, false)
			_check("prop_detail 粗略 → 吸附迭代 2", SdfProp._snap_iters_main, 2)
			_check("terrain_detail 简单 → chunk 低细节 true", scene.get("chunk_manager").get("_terrain_low_detail"), true)
			_check("三项都存档为 0", [
				GraphicsSettings.load_all()["xray"],
				GraphicsSettings.load_all()["prop_detail"],
				GraphicsSettings.load_all()["terrain_detail"],
			], [0, 0, 0])
			# 再点一次 xray：0→1 升回开（验证循环回绕）
			(_gfx()["xray"] as Button).button_pressed = true
		19:
			# 样式键：纸艺风开 → BendMat/chunk 记忆态 + 存档；bench 重定档不冲掉画风
			(_gfx()["papercraft"] as Button).button_pressed = true
		20:
			_check("xray 回绕开 → 静态态 true", PaperCharacter._xray_enabled, true)
			_check("xray 存档回 1", GraphicsSettings.load_all()["xray"], 1)
			_check("纸艺风开 → BendMat 态 true", BendMat.papercraft_on(), true)
			_check("纸艺风开 → chunk 记忆态 true", scene.get("chunk_manager").get("_papercraft"), true)
			_check("纸艺风存档 papercraft=1", GraphicsSettings.load_all()["papercraft"], 1)
			GraphicsSettings.save_all(GraphicsSettings.all_max(), "bench")  # 模拟 benchmark 重定档
			_check("bench 重定档保留纸艺风", GraphicsSettings.load_all()["papercraft"], 1)
			scene.call("_on_gfx_restore_auto")  # 恢复自动：清掉 user override
		21:
			_check("恢复自动 → 不再是 user override", GraphicsSettings.is_user_override(), false)
			_check("恢复自动 → 无存档（交回 benchmark/backend）", GraphicsSettings.has_saved(), false)
			_check("恢复自动 → 场景回默认(地面阴影重开)", scene.get("chunk_manager").get("_ground_shadows"), true)
			_check("恢复自动 → 按钮跟着回最高档", (_gfx()["hi_res"] as Button).text, "高清")
			_check("恢复自动 → 样式键回默认关", BendMat.papercraft_on(), false)
		22:
			if _backup.is_empty():
				PlayerProfile.clear()
			else:
				PlayerProfile.save_profile(_backup)
			if fails == 0:
				print("graphics_toggles PASS")
			else:
				printerr("graphics_toggles FAILED: %d" % fails)
		24:
			quit(fails)

## 每个旋钮的卡片里都要有一行 subtitle（Label 文本 = GraphicsSettings.SUBTITLES[key]）。
func _subtitles_present() -> bool:
	var found := {}
	for n in scene.find_children("*", "Label", true, false):
		found[(n as Label).text] = true
	for k: String in GraphicsSettings.all_keys():
		if not found.has(String(GraphicsSettings.SUBTITLES[k])):
			printerr("  缺 subtitle: %s" % k)
			return false
	return true

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
