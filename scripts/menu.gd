extends Control
## 主菜单：3 岁小朋友友好——零文字零选择，全屏任点即进（press-anywhere）。
## 按档案分流：无档案 → 童话书 onboarding；有档案 → 直接进世界。
## 唯一提示是中央脉动的大箭头贴纸；重新捏角色的入口藏在游戏内设置里，菜单不摆第二个选项。


var _fairy: TextureRect
var _hint: TextureRect
var _t := 0.0
var _fairy_base_y := 0.0
var game_audio: GameAudio
var _leaving := false

func _ready() -> void:
	# 移动端全局限帧（Engine.max_fps 跨场景持久，menu 是主场景入口一次设够）：
	# 长期运行不发热是硬诉求，30fps 单帧功耗近乎减半。桌面不限。
	if OS.has_feature("mobile"):
		Engine.max_fps = GraphicsSettings.FPS_CAP
	_setup_background()
	_setup_fairy()
	_setup_title()
	_setup_tap_entry()
	_setup_credits()
	game_audio = GameAudio.new()
	game_audio.name = "GameAudio"
	add_child(game_audio)
	game_audio.start_bgm([GameAudio.BGM_STEPS[0]]) # 菜单只垫最安静的第一段

func _setup_background() -> void:
	# 水彩草甸村庄插画铺满（AIGC bg_menu：远处小屋+风车，与世界观一脉相承）
	var bg := TextureRect.new()
	bg.texture = UiAssets.tex("bg_menu")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
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

func _setup_tap_entry() -> void:
	# 全屏透明按钮：点哪里都触发（乱拍也能进），键盘任意键同效（_unhandled_input）
	var tap := Button.new()
	tap.flat = true
	tap.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	tap.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	tap.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	tap.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	tap.set_anchors_preset(Control.PRESET_FULL_RECT)
	tap.pressed.connect(_on_tap)
	add_child(tap)

	# 中央脉动大箭头：不识字也懂的唯一提示（缩放呼吸见 _process）
	_hint = UiAssets.icon_rect("ic_next", 180.0)
	_hint.set_anchors_preset(Control.PRESET_CENTER)
	_hint.offset_left = -90.0
	_hint.offset_right = 90.0
	_hint.offset_top = 40.0
	_hint.offset_bottom = 220.0
	_hint.pivot_offset = Vector2(90.0, 90.0)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE # 别挡全屏按钮
	add_child(_hint)

## BGM 用了 Kevin MacLeod 的 CC-BY 4.0 曲、中国古代主题用了 poly.pizza 上几件 CC-BY 3.0
## 3D 模型，两者许可都要求可见署名。菜单没有 credits 屏（3 岁娃零文字设计），就在底部
## 垫两行小号半透明署名——满足 CC-BY 合规又不打扰娃（CC0 资产无需署名，此处不列）。
## mouse_filter=IGNORE：不挡全屏「任点即进」按钮。完整清单见 docs/asset-credits.md，
## 曲目细节见 assets/audio/bgm/LICENSE.txt。
func _setup_credits() -> void:
	# 底行：音乐署名（CC BY 4.0）
	_add_credit_line("音乐 Music by Kevin MacLeod (incompetech.com) · CC BY 4.0", -34.0, -8.0)
	# 上行：美术署名（中国古代主题的 CC BY 3.0 模型作者）
	_add_credit_line("美术 Art: Poly by Google · Jacques Fourie · Aidan K McLaughlin · CC BY 3.0", -58.0, -34.0)

func _add_credit_line(text: String, top: float, bottom: float) -> void:
	var credit := Label.new()
	credit.text = text
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	credit.offset_top = top
	credit.offset_bottom = bottom
	credit.add_theme_font_size_override("font_size", 18)
	credit.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	credit.add_theme_color_override("font_outline_color", Color(0.2, 0.3, 0.4, 0.5))
	credit.add_theme_constant_override("outline_size", 4)
	credit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(credit)

## 入口分流：建过真角色才直接进世界，否则先走童话书 onboarding。
## 用 has_character() 而非 exists()：profile.json 是共享袋子（device_id/graphics/play_budget 等
## 也写在里面），文件存在 ≠ 建过角色。历史上用 exists() 导致画质档/设备档一落盘就永久跳过创建，
## 小朋友被无档丢进世界、后台留一堆「无立绘」空玩家（见 test/test_menu_gate.gd）。
static func target_scene() -> String:
	return "res://main.tscn" if PlayerProfile.has_character() else "res://onboarding.tscn"

func _process(delta: float) -> void:
	# 小仙子轻轻上下飘
	_t += delta
	if _fairy != null:
		var off := sin(_t * 1.6) * 12.0
		_fairy.offset_top = _fairy_base_y + off
		_fairy.offset_bottom = _fairy_base_y + 178.0 + off
	if _hint != null:
		# 箭头缩放呼吸脉动，招呼小朋友来拍
		var s := 1.0 + sin(_t * 2.4) * 0.08
		_hint.scale = Vector2(s, s)

func _unhandled_input(event: InputEvent) -> void:
	# press-any-key：键盘任意键也能进（桌面端）
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		_on_tap()

func _on_tap() -> void:
	_go_to(target_scene())

## 点按音效放完再切场景（本节点一切走音就断了）。
## 进世界(main.tscn)经加载过场遮住首屏铺设/网络弹入；进绘本 onboarding 轻量，直切。
func _go_to(scene_path: String) -> void:
	if _leaving:
		return
	_leaving = true
	game_audio.play_sfx("click")
	await get_tree().create_timer(0.15).timeout
	if scene_path == "res://main.tscn":
		# 有档案直接进世界：无画质档（新 GPU）仍要跑「建造小世界」intro 定档段（should_run 判定）。
		IntroDirector.pending = IntroDirector.should_run()
		Loading.next_scene = scene_path
		get_tree().change_scene_to_file("res://loading.tscn")
	else:
		get_tree().change_scene_to_file(scene_path)
