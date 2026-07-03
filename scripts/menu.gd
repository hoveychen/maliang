extends Control
## 主菜单：3 岁小朋友友好——不依赖文字，超大按钮 + 小仙子飘动。
## ▶ 开始 → 童话书 onboarding（P7 接入前暂进世界）；📖 继续 → 直接进世界（有档案时才显示）。


var _fairy: TextureRect
var _t := 0.0
var _fairy_base_y := 0.0

func _ready() -> void:
	_setup_background()
	_setup_fairy()
	_setup_title()
	_setup_buttons()

func _setup_background() -> void:
	# 柔和天空渐变（与世界的天空色一脉相承）
	var bg := TextureRect.new()
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0.62, 0.82, 0.97), Color(0.86, 0.95, 0.86)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	bg.texture = tex
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

func _setup_fairy() -> void:
	_fairy = TextureRect.new()
	_fairy.texture = load("res://assets/fairy.png")
	_fairy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fairy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fairy.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_fairy.custom_minimum_size = Vector2(260.0, 178.0)
	_fairy.offset_left = -130.0
	_fairy.offset_right = 130.0
	_fairy.offset_top = 96.0
	_fairy.offset_bottom = 274.0
	add_child(_fairy)
	_fairy_base_y = _fairy.offset_top

func _setup_title() -> void:
	var title := Label.new()
	title.text = "马良小世界"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.offset_top = 290.0
	title.offset_bottom = 380.0
	title.offset_left = -400.0
	title.offset_right = 400.0
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	title.add_theme_color_override("font_outline_color", Color(0.35, 0.55, 0.75))
	title.add_theme_constant_override("outline_size", 16)
	add_child(title)

func _setup_buttons() -> void:
	var start := _big_button("▶  出发！", Color(1.0, 0.72, 0.35))
	start.set_anchors_preset(Control.PRESET_CENTER)
	start.offset_left = -220.0
	start.offset_right = 220.0
	start.offset_top = 60.0
	start.offset_bottom = 170.0
	start.pressed.connect(_on_start)
	add_child(start)

	if PlayerProfile.exists():
		var cont := _big_button("📖  继续玩", Color(0.62, 0.85, 0.62))
		cont.set_anchors_preset(Control.PRESET_CENTER)
		cont.offset_left = -220.0
		cont.offset_right = 220.0
		cont.offset_top = 200.0
		cont.offset_bottom = 300.0
		cont.pressed.connect(_on_continue)
		add_child(cont)

## 儿童友好的大按钮：超大字号 + 圆角撞色底。
func _big_button(text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 52)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_outline_color", color.darkened(0.4))
	b.add_theme_constant_override("outline_size", 8)
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(40)
	style.set_content_margin_all(18.0)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = color.lightened(0.15)
	b.add_theme_stylebox_override("hover", hover)
	var pressed := style.duplicate() as StyleBoxFlat
	pressed.bg_color = color.darkened(0.15)
	b.add_theme_stylebox_override("pressed", pressed)
	return b

func _process(delta: float) -> void:
	# 小仙子轻轻上下飘
	_t += delta
	if _fairy != null:
		var off := sin(_t * 1.6) * 12.0
		_fairy.offset_top = _fairy_base_y + off
		_fairy.offset_bottom = _fairy_base_y + 178.0 + off

func _on_start() -> void:
	# TODO(P7)：接入童话书 onboarding 后改为 res://onboarding.tscn
	get_tree().change_scene_to_file("res://main.tscn")

func _on_continue() -> void:
	get_tree().change_scene_to_file("res://main.tscn")
