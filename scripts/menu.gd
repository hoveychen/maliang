extends Control
## 主菜单：3 岁小朋友友好——零文字零选择，全屏任点即进（press-anywhere）。
## 版式（menu-dynamic）：全屏「游戏内相册」打底（assets/menu_album 精选截图，轮播见
## _setup_album/P3），左侧盖一张撕纸白卡（assets/ui/menu_card.png，tools/gen_torn_card.py
## 程序化生成）当菜单区——点点立绘+标题+开始大箭头+CC-BY 署名都在卡上。卡片现阶段纯观感，
## 竖向留白是给将来的长按钮（换形象/相册…）预留的位置；重新捏角色的入口仍藏在游戏内设置里。
## 按档案分流：无档案 → 童话书 onboarding；有档案 → 直接进世界。

const CARD_W := 0.42          ## 撕纸卡占屏宽比例（老板拍板的左侧竖卡版式）
const CARD_CX := 0.415        ## 卡上内容的水平中心锚点：撕边占贴图右侧 ~17%，视觉中心偏左
const CARD_BLEED := 44.0      ## 卡四周出血（含 -0.6° 微倾造成的角部内缩）

var _fairy: TextureRect
var _hint: TextureRect
var _t := 0.0
var _fairy_base_y := 0.0
var game_audio: GameAudio
var _leaving := false
var _ui := 1.0                ## UI 缩放：project 的 stretch 配置是死键(落在[editor_plugins]段)，
                              ## canvas 实为 1:1 像素——菜单元素按 720 设计稿乘此系数放大

func _s(v: float) -> float:
	return v * _ui

func _ready() -> void:
	# 移动端全局限帧（Engine.max_fps 跨场景持久，menu 是主场景入口一次设够）：
	# 长期运行不发热是硬诉求，30fps 单帧功耗近乎减半。桌面不限。
	if OS.has_feature("mobile"):
		Engine.max_fps = GraphicsSettings.FPS_CAP
	_ui = clampf(get_viewport_rect().size.y / 720.0, 1.0, 2.4)
	_setup_background()
	_setup_album()
	var card := _setup_card()
	_setup_fairy(card)
	_setup_title(card)
	_setup_credits(card)
	_setup_tap_entry(card)
	game_audio = GameAudio.new()
	game_audio.name = "GameAudio"
	add_child(game_audio)
	game_audio.start_bgm([GameAudio.BGM_STEPS[0]]) # 菜单只垫最安静的第一段

func _setup_background() -> void:
	# 水彩草甸插画兜底：相册照片没加载出来（资产被裁）时不至于黑屏。
	var bg := TextureRect.new()
	bg.texture = UiAssets.tex("bg_menu")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

## 相册照片清单。导出包里 res:// 列目录看到的是 .import/.remap 包装名——剥掉再去重，
## 否则真机上一张照片都数不出来（headless/编辑器下是裸文件名，两种形态都要认）。
static func album_paths() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open("res://assets/menu_album")
	if dir == null:
		return out
	for f in dir.get_files():
		var fname := f.trim_suffix(".remap").trim_suffix(".import")
		if not (fname.ends_with(".jpg") or fname.ends_with(".png")):
			continue
		var p := "res://assets/menu_album/" + fname
		if not out.has(p):
			out.append(p)
	out.sort()
	return out

func _setup_album() -> void:
	# 游戏内画面打底：真实截图（村庄互动/街景/森林河谷），比插画更能说明这是个什么游戏。
	var paths := album_paths()
	if paths.is_empty():
		return
	var photo := TextureRect.new()
	photo.name = "AlbumPhoto"
	photo.texture = load(paths[0])
	photo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	photo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	photo.set_anchors_preset(Control.PRESET_FULL_RECT)
	photo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(photo)

func _setup_card() -> TextureRect:
	# 撕纸白卡：左 42% 竖卡，四周出血 + 微倾 0.6°（手工贴上去的纸片感）。
	var card := TextureRect.new()
	card.name = "MenuCard"
	card.texture = load("res://assets/ui/menu_card.png")
	card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	card.stretch_mode = TextureRect.STRETCH_SCALE
	card.anchor_left = 0.0
	card.anchor_right = CARD_W
	card.anchor_top = 0.0
	card.anchor_bottom = 1.0
	card.offset_left = -CARD_BLEED
	card.offset_top = -CARD_BLEED
	card.offset_bottom = CARD_BLEED
	card.offset_right = 0.0
	card.rotation_degrees = -0.6
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 微倾绕卡中心转（pivot 依赖实际尺寸，等布局定了再设）
	card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)
	add_child(card)
	return card

func _setup_fairy(card: Control) -> void:
	_fairy = TextureRect.new()
	_fairy.texture = load("res://assets/fairy.png")
	_fairy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fairy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fairy.anchor_left = CARD_CX
	_fairy.anchor_right = CARD_CX
	_fairy.anchor_top = 0.0
	_fairy.anchor_bottom = 0.0
	_fairy.offset_left = _s(-130.0)
	_fairy.offset_right = _s(130.0)
	_fairy.offset_top = _s(110.0)
	_fairy.offset_bottom = _s(288.0)
	_fairy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(_fairy)
	_fairy_base_y = _fairy.offset_top

func _setup_title(card: Control) -> void:
	var title := Label.new()
	title.text = "马良小世界"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = CARD_CX
	title.anchor_right = CARD_CX
	title.anchor_top = 0.0
	title.anchor_bottom = 0.0
	title.offset_left = _s(-400.0)
	title.offset_right = _s(400.0)
	title.offset_top = _s(300.0)
	title.offset_bottom = _s(390.0)
	title.add_theme_font_size_override("font_size", int(_s(72.0)))
	# 纸上用墨蓝直书，不再描边（白字描边是给照片底用的老样式）
	title.add_theme_color_override("font_color", Color(0.29, 0.44, 0.65))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(title)

func _setup_tap_entry(card: Control) -> void:
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

	# 卡上脉动大箭头：不识字也懂的唯一提示（缩放呼吸见 _process）
	_hint = UiAssets.icon_rect("ic_next", _s(180.0))
	_hint.anchor_left = CARD_CX
	_hint.anchor_right = CARD_CX
	_hint.anchor_top = 0.5
	_hint.anchor_bottom = 0.5
	_hint.offset_left = _s(-90.0)
	_hint.offset_right = _s(90.0)
	_hint.offset_top = _s(-30.0)
	_hint.offset_bottom = _s(150.0)
	_hint.pivot_offset = Vector2(_s(90.0), _s(90.0))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE # 别挡全屏按钮
	card.add_child(_hint)

## BGM 用了 Kevin MacLeod 的 CC-BY 4.0 曲、中国古代主题用了 poly.pizza 上几件 CC-BY 3.0
## 3D 模型，两者许可都要求可见署名。菜单没有 credits 屏（3 岁娃零文字设计），就在纸卡底部
## 垫两行小号署名——满足 CC-BY 合规又不打扰娃（CC0 资产无需署名，此处不列）。
## mouse_filter=IGNORE：不挡全屏「任点即进」按钮。完整清单见 docs/asset-credits.md，
## 曲目细节见 assets/audio/bgm/LICENSE.txt。
func _setup_credits(_card: Control) -> void:
	# 署名太长塞不进卡宽（会戳破撕边），放照片区右下角（老样式白字半透明）。
	_add_credit_line("音乐 Music by Kevin MacLeod (incompetech.com) · CC BY 4.0", _s(-34.0), _s(-8.0))
	_add_credit_line("美术 Art: Poly by Google · Jacques Fourie · Aidan K McLaughlin · CC BY 3.0", _s(-60.0), _s(-34.0))

func _add_credit_line(text: String, top: float, bottom: float) -> void:
	var credit := Label.new()
	credit.text = text
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit.anchor_left = CARD_W
	credit.anchor_right = 1.0
	credit.anchor_top = 1.0
	credit.anchor_bottom = 1.0
	credit.offset_top = top
	credit.offset_bottom = bottom
	credit.add_theme_font_size_override("font_size", int(_s(14.0)))
	credit.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	credit.add_theme_color_override("font_outline_color", Color(0.2, 0.3, 0.4, 0.5))
	credit.add_theme_constant_override("outline_size", int(_s(3.0)))
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
		var off := sin(_t * 1.6) * _s(12.0)
		_fairy.offset_top = _fairy_base_y + off
		_fairy.offset_bottom = _fairy_base_y + _s(178.0) + off
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
