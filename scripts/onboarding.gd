extends Control
## 童话书 onboarding：翻页绘本讲故事 + 图标问题 + 自我介绍 + 形象生成。
## 面向 3 岁小朋友：不依赖文字——大图标演出 + 预制 TTS 旁白（assets/voice/onboarding/）。
## 页面由 PAGES 声明式驱动；answers 收集到 PlayerProfile。
## kind: story(讲故事,点击/旁白结束后翻页) | question(图标选项) | intro(ASR 自我介绍,P5)
##       | generate(形象生成确认,P6)

const VOICE_DIR := "res://assets/voice/onboarding"
const FLIP_TIME := 0.35

## 问题选项 value 直接入档案；icon 为超大演出图标（Android 需真机验 emoji 渲染，见 P8）。
const PAGES := [
	{ "id": "story_1", "kind": "story", "icons": "🌲🌷🌈", "voice": "ob_story_1" },
	{ "id": "story_2", "kind": "story", "icons": "🧚🖌️✨", "voice": "ob_story_2", "fairy": true },
	{ "id": "story_3", "kind": "story", "icons": "🚪🌟🎈", "voice": "ob_story_3" },
	{ "id": "q_gender", "kind": "question", "field": "gender", "voice": "ob_q_gender", "options": [
		{ "icon": "👦", "value": "boy", "voice": "ob_opt_boy" },
		{ "icon": "👧", "value": "girl", "voice": "ob_opt_girl" },
	] },
	{ "id": "q_color", "kind": "question", "field": "color", "voice": "ob_q_color", "options": [
		{ "icon": "", "value": "红色", "voice": "ob_opt_red", "color": Color(0.94, 0.35, 0.35) },
		{ "icon": "", "value": "蓝色", "voice": "ob_opt_blue", "color": Color(0.35, 0.55, 0.94) },
		{ "icon": "", "value": "黄色", "voice": "ob_opt_yellow", "color": Color(0.98, 0.83, 0.3) },
		{ "icon": "", "value": "绿色", "voice": "ob_opt_green", "color": Color(0.42, 0.82, 0.45) },
	] },
	{ "id": "q_likes", "kind": "question", "field": "likes", "voice": "ob_q_likes", "options": [
		{ "icon": "🐰", "value": "小兔子", "voice": "ob_opt_rabbit" },
		{ "icon": "🐱", "value": "小猫", "voice": "ob_opt_cat" },
		{ "icon": "🐶", "value": "小狗", "voice": "ob_opt_dog" },
		{ "icon": "🦖", "value": "小恐龙", "voice": "ob_opt_dino" },
	] },
	{ "id": "q_interest", "kind": "question", "field": "interest", "voice": "ob_q_interest", "options": [
		{ "icon": "🎨", "value": "画画", "voice": "ob_opt_draw" },
		{ "icon": "⚽", "value": "踢球", "voice": "ob_opt_ball" },
		{ "icon": "🎵", "value": "唱歌", "voice": "ob_opt_sing" },
		{ "icon": "📚", "value": "听故事", "voice": "ob_opt_story" },
	] },
	{ "id": "intro", "kind": "intro", "voice": "ob_intro_ask" },
	{ "id": "generate", "kind": "generate", "voice": "ob_generating" },
]

var answers: Dictionary = {}
var page_idx := -1
var _page: Control = null          ## 当前页容器（翻页时旧页被收走）
var _book: PanelContainer
var _voice: AudioStreamPlayer
var _flipping := false
var _story_auto_t := 0.0           ## story 页自动翻页倒计时（旁白结束后）

func _ready() -> void:
	_setup_background()
	_setup_book()
	_voice = AudioStreamPlayer.new()
	add_child(_voice)
	_setup_skip()
	_next_page()

func _setup_background() -> void:
	var bg := TextureRect.new()
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0.55, 0.72, 0.92), Color(0.92, 0.88, 0.78)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	bg.texture = tex
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

func _setup_book() -> void:
	_book = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.98, 0.92) # 米色书页
	style.set_corner_radius_all(28)
	style.set_content_margin_all(28.0)
	style.shadow_color = Color(0.2, 0.25, 0.3, 0.35)
	style.shadow_size = 18
	_book.add_theme_stylebox_override("panel", style)
	_book.set_anchors_preset(Control.PRESET_CENTER)
	_book.offset_left = -520.0
	_book.offset_right = 520.0
	_book.offset_top = -300.0
	_book.offset_bottom = 300.0
	add_child(_book)

func _setup_skip() -> void:
	# 家长用的小跳过按钮（右上角，半透明不抢戏）
	var skip := Button.new()
	skip.text = "跳过 ▸"
	skip.add_theme_font_size_override("font_size", 22)
	skip.modulate = Color(1, 1, 1, 0.55)
	skip.flat = true
	skip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	skip.offset_left = -140.0
	skip.offset_top = 16.0
	skip.offset_bottom = 56.0
	skip.pressed.connect(_finish)
	add_child(skip)

# ── 翻页与页面渲染 ─────────────────────────────────────────────────────────

func _next_page() -> void:
	if _flipping:
		return
	if page_idx + 1 >= PAGES.size():
		_finish()
		return
	page_idx += 1
	_flip_to(_build_page(PAGES[page_idx]))

## 书页翻转：旧页横向压扁（绕左脊）→ 新页展开。
func _flip_to(next_page: Control) -> void:
	_flipping = true
	var old := _page
	_page = next_page
	if old != null:
		var tw := create_tween()
		tw.tween_property(old, "scale:x", 0.0, FLIP_TIME).set_ease(Tween.EASE_IN)
		tw.tween_callback(old.queue_free)
	next_page.scale.x = 0.0
	_book.add_child(next_page)
	var tw2 := create_tween()
	tw2.tween_interval(FLIP_TIME if old != null else 0.0)
	tw2.tween_property(next_page, "scale:x", 1.0, FLIP_TIME).set_ease(Tween.EASE_OUT)
	tw2.tween_callback(func() -> void:
		_flipping = false
		_on_page_shown(PAGES[page_idx]))

func _build_page(p: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 30)
	box.pivot_offset = Vector2(0.0, 300.0) # 绕左脊翻
	match String(p["kind"]):
		"story": _build_story(box, p)
		"question": _build_question(box, p)
		"intro": _build_intro(box, p)
		"generate": _build_generate(box, p)
	return box

func _build_story(box: VBoxContainer, p: Dictionary) -> void:
	if p.get("fairy", false):
		var img := TextureRect.new()
		img.texture = load("res://assets/fairy.png")
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.custom_minimum_size = Vector2(300.0, 205.0)
		img.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(img)
	var icons := Label.new()
	icons.text = String(p.get("icons", "✨"))
	icons.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icons.add_theme_font_size_override("font_size", 120 if not p.get("fairy", false) else 72)
	box.add_child(icons)
	var hint := Button.new()
	hint.text = "▶"
	hint.add_theme_font_size_override("font_size", 44)
	hint.flat = true
	hint.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	hint.pressed.connect(_next_page)
	box.add_child(hint)

func _build_question(box: VBoxContainer, p: Dictionary) -> void:
	var q := Label.new()
	q.text = "❓"
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	q.add_theme_font_size_override("font_size", 64)
	box.add_child(q)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 36)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	for opt in (p["options"] as Array):
		row.add_child(_option_button(p, opt as Dictionary))
	box.add_child(row)

## 图标大按钮：emoji 或纯色圆角块（颜色题用色块，不依赖 emoji 渲染）。
func _option_button(p: Dictionary, opt: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(170.0, 170.0)
	b.text = String(opt.get("icon", ""))
	b.add_theme_font_size_override("font_size", 96)
	var style := StyleBoxFlat.new()
	style.bg_color = opt.get("color", Color(0.96, 0.93, 0.85))
	style.set_corner_radius_all(32)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = (style.bg_color as Color).lightened(0.12)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.pressed.connect(func() -> void: _on_option(p, opt, b))
	return b

func _on_option(p: Dictionary, opt: Dictionary, btn: Button) -> void:
	if _flipping:
		return
	answers[String(p["field"])] = String(opt["value"])
	_play(String(opt.get("voice", "")))
	# 选中反馈：弹一下再翻页
	btn.pivot_offset = btn.size * 0.5
	var tw := create_tween()
	tw.tween_property(btn, "scale", Vector2(1.18, 1.18), 0.12)
	tw.tween_property(btn, "scale", Vector2.ONE, 0.12)
	tw.tween_interval(0.5)
	tw.tween_callback(_next_page)

## P5 接入 ASR 自我介绍；框架阶段直接提供跳过点继续。
func _build_intro(box: VBoxContainer, _p: Dictionary) -> void:
	var mic := Label.new()
	mic.text = "🎤"
	mic.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mic.add_theme_font_size_override("font_size", 120)
	box.add_child(mic)
	var next := Button.new()
	next.text = "▶"
	next.add_theme_font_size_override("font_size", 44)
	next.flat = true
	next.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	next.pressed.connect(_next_page)
	box.add_child(next)

## P6 接入形象生成确认；框架阶段直接提供跳过点继续。
func _build_generate(box: VBoxContainer, _p: Dictionary) -> void:
	var wand := Label.new()
	wand.text = "🪄✨"
	wand.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wand.add_theme_font_size_override("font_size", 120)
	box.add_child(wand)
	var next := Button.new()
	next.text = "▶"
	next.add_theme_font_size_override("font_size", 44)
	next.flat = true
	next.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	next.pressed.connect(_next_page)
	box.add_child(next)

# ── 旁白与推进 ────────────────────────────────────────────────────────────

func _on_page_shown(p: Dictionary) -> void:
	var dur := _play(String(p.get("voice", "")))
	if String(p["kind"]) == "story":
		_story_auto_t = maxf(dur, 0.5) + 1.2 # 旁白讲完停 1.2s 自动翻页

func _process(delta: float) -> void:
	if _story_auto_t > 0.0 and not _flipping:
		_story_auto_t -= delta
		if _story_auto_t <= 0.0 and page_idx >= 0 and String(PAGES[page_idx]["kind"]) == "story":
			_next_page()

## 播预制旁白，返回音频时长（缺文件返回 0，静默继续——音频由 P4 批量生成）。
func _play(id: String) -> float:
	if id.is_empty():
		return 0.0
	if not ResourceLoader.exists("%s/%s.wav" % [VOICE_DIR, id]):
		return 0.0
	var stream: AudioStream = load("%s/%s.wav" % [VOICE_DIR, id])
	if stream == null:
		return 0.0
	_voice.stop()
	_voice.stream = stream
	_voice.play()
	return stream.get_length()

func _finish() -> void:
	# 保存已收集的答案（名字/形象由 P5/P6 补全）
	var profile := PlayerProfile.load_profile()
	for k in answers:
		profile[k] = answers[k]
	profile["created_at"] = Time.get_datetime_string_from_system()
	PlayerProfile.save_profile(profile)
	get_tree().change_scene_to_file("res://main.tscn")
