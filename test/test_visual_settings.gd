extends SceneTree
## 设置入口断言：收集册 tab 行末尾藏小齿轮设置页——"重新捏角色"需 ？✓✗ 确认防误触，
## ✗ 收起确认行，✓ 切回童话书 onboarding（onboarding 合并保存档案，贴纸/物品不丢）。
## 主菜单单入口化后这里是唯一的重新捏角色入口。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 80 --script res://test/test_visual_settings.gd

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _pui() -> PhoneUi:
	return scene.get("phone_ui") as PhoneUi

func _reroll_button() -> Button:
	return _pui().get("_reroll_btn") as Button

func _confirm_row() -> HBoxContainer:
	return _pui().get("_reroll_confirm") as HBoxContainer

func _avatar_button() -> Button:
	return _pui().get("_avatar_btn") as Button

func _avatar_preview() -> Control:
	return _pui().get("_avatar_preview") as Control

func _tick() -> void:
	frame += 1
	match frame:
		1:
			root.size = Vector2i(1280, 720)
		5:
			# 打开手机：设置 app 存在，默认停在主屏（各 app 页面都收着）
			(scene.get("album_button") as Button).emit_signal("pressed")
			_check("phone open", (scene.get("paper_phone") as PaperPhone).state == PaperPhone.State.FRONT, true)
			_check("settings app present", (_pui().get("_album_pages") as Dictionary).has("settings"), true)
			_check("settings page hidden on home",
				((_pui().get("_album_pages") as Dictionary)["settings"] as Control).visible, false)
		10:
			# 打开设置 app：重新捏角色按钮可见，确认行还收着
			scene.call("_open_app", "settings")
			var page := (_pui().get("_album_pages") as Dictionary)["settings"] as Control
			_check("settings page visible", page.visible, true)
			_check("reroll button present", _reroll_button().text, "重新捏角色")
			_check("confirm hidden before ask", _confirm_row().visible, false)
		15:
			# 点重新捏角色 → 弹 ？✓✗ 确认行；点 ✗ 收回
			_reroll_button().emit_signal("pressed")
			_check("confirm shown after ask", _confirm_row().visible, true)
			(_confirm_row().get_child(2) as Button).emit_signal("pressed") # ✗
			_check("confirm dismissed by no", _confirm_row().visible, false)
		17:
			# 换形象按钮在场且预览收着；点击→按钮禁用（请求飞行中，假 API 会失败恢复）
			_check("avatar button present", _avatar_button().text, "换形象")
			_check("avatar preview hidden", _avatar_preview().visible, false)
			_avatar_button().emit_signal("pressed")
			_check("avatar busy while pending", _avatar_button().disabled, true)
		35:
			# 假 API（MALIANG_API_BASE=…:1）请求落败：按钮恢复可再试，预览仍收着
			_check("avatar btn recovered after fail", _avatar_button().disabled, false)
			_check("avatar preview still hidden", _avatar_preview().visible, false)
		40:
			# 再问一遍点 ✓ → 回童话书
			_reroll_button().emit_signal("pressed")
			(_confirm_row().get_child(1) as Button).emit_signal("pressed") # ✓
			scene = null # 场景即将被释放，后续只看 current_scene
		65:
			var cur := current_scene
			_check("switched to Onboarding", cur != null and cur.name == "Onboarding", true)
			if fails == 0:
				print("visual_settings PASS")
			else:
				printerr("visual_settings FAILED: %d" % fails)
		70:
			quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
