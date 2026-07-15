extends CanvasLayer
## iOS 麦克风权限被拒时的全屏引导层（由 MicPermission.block() 实例化，命名 MicPermissionOverlay）。
## 文案 + 「打开设置」按钮 + 回前台自动复查解除（授予后自我移除并解暂停）。
## process_mode=ALWAYS：树被暂停后仍能响应按钮与前台通知。

func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS # 暂停树后仍在最顶层响应

	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.12, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP # 吞掉一切输入，游戏点不动
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 28)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	bg.add_child(box)

	var msg := Label.new()
	msg.name = "Msg"
	msg.text = MicPermission.MSG
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size = Vector2(560, 0)
	box.add_child(msg)

	var btn := Button.new()
	btn.name = "OpenSettings"
	btn.text = "打开设置"
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.custom_minimum_size = Vector2(220, 64)
	btn.pressed.connect(_on_open_settings)
	box.add_child(btn)

func _on_open_settings() -> void:
	# iOS：app-settings: 直接跳到本 App 的系统设置页（UIApplicationOpenSettingsURLString）。
	# 打不开也无妨——文案已指明手动路径。
	OS.shell_open("app-settings:")

func _notification(what: int) -> void:
	# 从设置返回 App（前台/窗口重新聚焦）→ 复查权限；已授予则自我移除并解暂停，
	# 宿主（onboarding._process 等）下一帧重新调用 open() 即会真正开麦，自愈。
	if what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		if MicPermission.query_status() == MicPermission.STATUS_GRANTED:
			MicPermission.clear(get_tree())
