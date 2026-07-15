extends CanvasLayer
## iOS 麦克风权限被拒时的全屏引导层（由 MicPermission.block() 实例化，命名 MicPermissionOverlay）。
## 面向学龄前小朋友：暖纸色 + 点点立绘 + 大字 + 点点开口（预烧 Yunxia 音色 TTS，进屏就读、可再听）
## + 醒目「去找大人帮忙」+ 给大人看的小字设置路径 + 大圆角「打开设置」按钮。
## 回前台自动复查解除（授予后自我移除并解暂停）。process_mode=ALWAYS：树暂停后仍能响应。

const VOICE_PATH := "res://assets/voice/system/mic_permission.wav"
const FAIRY_PATH := "res://assets/fairy.png"

var _voice: AudioStreamPlayer

func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS

	# 暖纸色满屏底：吞掉一切输入，盖住游戏。
	var bg := ColorRect.new()
	bg.color = Color(0.953, 0.906, 0.812) # #f3e7cf 暖纸
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 22)
	bg.add_child(box)

	# 点点立绘
	if ResourceLoader.exists(FAIRY_PATH):
		var dot := TextureRect.new()
		dot.texture = load(FAIRY_PATH)
		dot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		dot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		dot.custom_minimum_size = Vector2(0, 180)
		box.add_child(dot)

	_add_label(box, "麦克风被关上啦", 46, Color(0.29, 0.23, 0.16), 800)

	# 点点说的话（与 TTS 同文案）
	var speech := _add_label(box, "“咦？点点听不到你说话了。\n快去找个大人，帮点点把麦克风打开好不好呀？”",
		30, Color(0.36, 0.29, 0.20))
	speech.custom_minimum_size = Vector2(620, 0)

	_add_label(box, "👉 去找大人帮忙", 38, Color(0.78, 0.42, 0.16), 800)
	_add_label(box, "大人请打开：设置 → maliang → 麦克风", 22, Color(0.54, 0.48, 0.39))

	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 18)
	box.add_child(btns)

	var open_btn := _make_button("打开设置", Color(0.949, 0.627, 0.239), Color.WHITE)
	open_btn.pressed.connect(_on_open_settings)
	btns.add_child(open_btn)

	var replay := _make_button("🔊 再听一遍", Color(1, 1, 1, 0.0), Color(0.54, 0.48, 0.39))
	replay.flat = true
	replay.pressed.connect(_play_voice)
	btns.add_child(replay)

	# 点点开口（预烧 Yunxia 音色，进屏就读一遍）
	_voice = AudioStreamPlayer.new()
	_voice.process_mode = Node.PROCESS_MODE_ALWAYS # 树暂停也照播
	add_child(_voice)
	_play_voice()

func _add_label(parent: Node, text: String, size: int, color: Color, weight: int = 400) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl

func _make_button(text: String, bg: Color, fg: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.process_mode = Node.PROCESS_MODE_ALWAYS
	b.custom_minimum_size = Vector2(0, 72)
	b.add_theme_font_size_override("font_size", 28)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	if bg.a > 0.0:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.set_corner_radius_all(36)
		sb.content_margin_left = 40
		sb.content_margin_right = 40
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)
	return b

func _play_voice() -> void:
	if _voice != null and ResourceLoader.exists(VOICE_PATH):
		_voice.stream = load(VOICE_PATH)
		_voice.play()

func _on_open_settings() -> void:
	# iOS：app-settings: 跳到本 App 的系统设置页（UIApplicationOpenSettingsURLString）。
	# 打不开也无妨——文案已指明手动路径。
	OS.shell_open("app-settings:")

func _notification(what: int) -> void:
	# 从设置返回 App（前台/窗口重新聚焦）→ 复查权限；已授予则自我移除并解暂停，
	# 宿主（onboarding._process 等）下一帧重新调用 open() 即会真正开麦，自愈。
	if what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		if MicPermission.query_status() == MicPermission.STATUS_GRANTED:
			MicPermission.clear(get_tree())
