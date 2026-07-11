extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：收集册齿轮设置页截帧。
## 编排（--fixed-fps 8）：1s 打开收集册（贴纸页+tab 行末尾小齿轮）→ 3s 切设置页
## （重新捏角色按钮）→ 5s 点它弹 ？✓✗ 确认行 → 8s 点 ✓ 回童话书 onboarding → 11s 结束。
## 运行: godot --write-movie <目录>/f.png --fixed-fps 8 --quit-after 90 \
##       --script res://test/test_visual_settings_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	match frame:
		8:
			(scene.get("album_button") as Button).emit_signal("pressed")
		24:
			scene.call("_open_app", "settings")
		40:
			var page := ((scene.get("phone_ui") as PhoneUi).get("_album_pages") as Dictionary)["settings"] as Control
			(page.get_child(0) as Button).emit_signal("pressed")
		64:
			(((scene.get("phone_ui") as PhoneUi).get("_reroll_confirm") as HBoxContainer).get_child(1) as Button).emit_signal("pressed")
			# 真实游戏里世界是 current_scene，change_scene 会整棵释放；
			# 本脚本手动挂的树要自己拆，否则世界 HUD 残留叠在童话书上
			scene.queue_free()
			scene = null

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)
