class_name PhoneUi
extends RefCounted
## 手机屏幕内容（UI 层）：正面主屏 + 背面跨页 app 界面，住在 PaperPhone 的两块 SubViewport 里。
## 只管 Control 树与展示刷新；业务（钱包/背包/画质应用/换形象落档/摆物品）通过持有的
## world 引用回调。从 world.gd 原样迁出（paper-phone P3，临时布局），纸糊风重设计见 P5。
##
## 布局分工：正面视口=状态栏+桌面 widget+图标分页（常驻主屏）；跨页视口=返回条+app 页面
## （flowers/items/settings，同一时刻只显示一页）。开 app/返回的翻转动画由 world 监听
## app_opened/back_pressed 驱动 PaperPhone。

signal app_opened(id: String)   ## 点了主屏图标（world 翻到跨页）
signal back_pressed             ## 点了返回（world 翻回正面）

const FRONT_PX := Vector2i(420, 920)    ## 正面屏视口（≈屏幕 quad 宽高比 0.456）
const SPREAD_PX := Vector2i(960, 1008)  ## 跨页视口（=双面板 2W:H≈0.952）
const HAND_FONT := "res://assets/fonts/patrick_hand/PatrickHand-Regular.ttf" ## 手写体（OFL，时钟数字用）

## 屏幕上的 app：[id, 短名, 图标资产]。图标资产缺失回退现有图标占位。
const PHONE_APPS := [
	["home", "回家", "app_home"],
	["flowers", "小红花", "app_flowers"],
	["items", "物品", "app_items"],
	["settings", "设置", "app_settings"],
]
const PHONE_APP_FALLBACK := { "home": "ic_pin", "flowers": "reward_flower", "items": "ic_gift", "settings": "ic_gear" }
## 小红花经济常量（与 server/src/types.ts 对齐）。
const MAX_FLOWERS := 9              ## 小红花上限（3×3 格）
const STAMPS_PER_FLOWER := 3        ## 每满 3 章换 1 朵花
const PHONE_GRID_COLS := 3          ## 主屏图标网格列数（3x3）
const PHONE_PAGE_SLOTS := 9         ## 每页图标格数（3x3）

var _w                              ## world（业务回调；动态访问，别 typed）

# —— 正面主屏 ——
var _phone_clock: Label             ## 状态栏时钟（实时，手写体数字）
var _phone_signal: Control          ## 状态栏信号格（绿=WS 在线、灰=离线）
var _phone_playpie: PlayTimePie     ## 桌面 widget 可玩时间饼图
var _phone_flowers: Label           ## 桌面 widget 小红花数
var _phone_pager: ScrollContainer   ## 图标分页横滚容器（iPhone 式左右翻页）
var _phone_pages_box: HBoxContainer ## 各页并排（每页宽=分页容器宽）
var _phone_dots: HBoxContainer      ## 翻页圆点指示（>1 页才显示）
var _phone_page := 0                ## 当前页
var _phone_page_w := 0.0            ## 单页宽
var _phone_pager_dragging := false  ## 拖拽中（松手贴合最近页）
var _phone_ui_t := 0.0              ## banner 刷新节流计时
var _screen_cover: Control          ## 熄屏画面（停靠=AOD 黑底暗时钟/点亮隐藏）
var _aod_clock: Label               ## 熄屏大时钟（随 refresh_banner 走字）

# —— 跨页 app 视图 ——
var _phone_app_title: Label         ## 打开的 app 标题
var _phone_open_app := ""           ## 当前打开的 app id（空=停在主屏）
var _album_pages: Dictionary = {}   ## app id → Control 页面

# —— 小红花/集邮页 ——
var _flower_field: FlowerField      ## 左页花田（3×3 土坑，自绘）
var _stamp_card: StampCard          ## 右页盖章卡（三槽，自绘）
var _ink_drops: InkDrops            ## 墨滴层（三章化墨越过中缝去左页种花）
var _stamps_total_label: Label      ## 累计盖章数
var _hearts_label: Label            ## 收到的爱心计数（玩家互动送❤，只增不减）
var _ceremony_playing := false      ## 盖章/种花仪式进行中（此时别拿钱包覆盖画面）
var _slam_now := false              ## 小朋友点了卡（等待中的 HOVER 拍据此立刻砸下）
var _ceremony_abort := false        ## 演到一半关了手机：中止且不提交，下次重演

# —— 回家页 ——
var _home_btn: Button               ## "回家"按钮（测试锚点）

# —— 物品页 ——
var _items_grid: GridContainer      ## 背包网格（动态重建）
var _items_empty: Label             ## 空态提示
var _shop_grid: GridContainer       ## 贴纸小铺货架（在线才铺货）

# —— 设置页 ——
var _reroll_btn: Button             ## "重新捏角色"按钮（测试锚点）
var _reroll_confirm: HBoxContainer  ## "重新捏角色" ✓/✗ 确认行（防小手误触）
var _avatar_btn: Button             ## "换形象"按钮（生成中禁用防连点）
var _avatar_preview: VBoxContainer  ## 换形象预览区（新形象图 + ✓/✗）
var _avatar_img: TextureRect        ## 预览图
var _avatar_hash := ""              ## 待确认的新形象资产 hash（✓ 才落档案）
var _avatar_anchors: Dictionary = {}  ## 与 _avatar_hash 配对的贴纸锚点（✓ 才随档案落盘）
var _gfx_buttons := {}              ## 画质旋钮控件 {key: Button}
var _confirm_voice_btn: Button      ## 「说完先听一遍」开关（小龄玩家语音确认模式）

func _init(world) -> void:
	_w = world

## ── 建树 ────────────────────────────────────────────────────────────────────

func build(front_vp: SubViewport, spread_vp: SubViewport) -> void:
	_build_front(front_vp)
	_build_spread(spread_vp)
	refresh_banner()
	refresh_album()

## 正面主屏：状态栏（时钟+信号格）+ 桌面 widget + 3x3 图标分页 + 翻页圆点。
func _build_front(vp: SubViewport) -> void:
	# 屏幕底：微皱白纸（实拍 CC0 纸纹，见 assets/ui/PHONE3D_PAPER_SOURCE.txt）；缺资产回退奶油纯色
	var paper := UiAssets.tex("phone3d_paper")
	if paper != null:
		var tex_bg := TextureRect.new()
		tex_bg.texture = paper
		tex_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_bg.stretch_mode = TextureRect.STRETCH_SCALE
		tex_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		vp.add_child(tex_bg)
	else:
		var bg := ColorRect.new()
		bg.color = UiAssets.CARD_BG
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		vp.add_child(bg)
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right"]:
		pad.add_theme_constant_override(side, 20)
	pad.add_theme_constant_override("margin_top", 26)
	pad.add_theme_constant_override("margin_bottom", 20)
	vp.add_child(pad)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	pad.add_child(vbox)
	# 顶部状态栏（极简 iPhone 式）：当前时间（左）+ 信号格（右）
	var banner_bar := HBoxContainer.new()
	banner_bar.add_theme_constant_override("separation", 6)
	_phone_clock = Label.new()
	_phone_clock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 手写体时钟（OFL 字体 Patrick Hand，只用到数字/冒号）；缺字体回退卡片暖棕
	if ResourceLoader.exists(HAND_FONT):
		_phone_clock.add_theme_font_override("font", load(HAND_FONT) as Font)
		_phone_clock.add_theme_font_size_override("font_size", 48)
		_phone_clock.add_theme_color_override("font_color", Color(0.32, 0.32, 0.36)) # 石墨灰
	else:
		UiAssets.style_card_label(_phone_clock, 26)
	banner_bar.add_child(_phone_clock)
	_phone_signal = _make_signal_indicator()
	banner_bar.add_child(_phone_signal)
	vbox.add_child(banner_bar)
	# 灵动岛：矢量黑药丸（圆角=半高）+ 右侧镜头点，悬浮视口顶部中央（仿 iPhone 构图）
	var island := Panel.new()
	var ist := StyleBoxFlat.new()
	ist.bg_color = Color(0.17, 0.17, 0.20, 0.92)
	ist.set_corner_radius_all(17)
	island.add_theme_stylebox_override("panel", ist)
	island.set_anchors_preset(Control.PRESET_CENTER_TOP)
	island.offset_left = -56.0
	island.offset_right = 56.0
	island.offset_top = 12.0
	island.offset_bottom = 46.0
	island.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lens := Panel.new()
	var lst := StyleBoxFlat.new()
	lst.bg_color = Color(0.36, 0.37, 0.44)
	lst.set_corner_radius_all(6)
	lens.add_theme_stylebox_override("panel", lst)
	lens.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	lens.offset_left = -24.0
	lens.offset_right = -12.0
	lens.offset_top = -6.0
	lens.offset_bottom = 6.0
	lens.mouse_filter = Control.MOUSE_FILTER_IGNORE
	island.add_child(lens)
	vp.add_child(island)
	vbox.add_child(HSeparator.new())
	vbox.add_child(_build_phone_widget())
	# 图标分页：横向 ScrollContainer，内含并排的页；拖拽翻页、松手贴合、圆点指示。
	_phone_pager = ScrollContainer.new()
	_phone_pager.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_phone_pager.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_phone_pager.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phone_pager.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_phone_pager.get_h_scroll_bar().modulate = Color(1.0, 1.0, 1.0, 0.0) # 藏滚动条
	_phone_pager.gui_input.connect(_on_phone_pager_input)
	vbox.add_child(_phone_pager)
	_phone_pages_box = HBoxContainer.new()
	_phone_pages_box.add_theme_constant_override("separation", 0)
	_phone_pager.add_child(_phone_pages_box)
	_build_phone_pages()
	_phone_dots = HBoxContainer.new()
	_phone_dots.alignment = BoxContainer.ALIGNMENT_CENTER
	_phone_dots.add_theme_constant_override("separation", 8)
	vbox.add_child(_phone_dots)
	_rebuild_phone_dots()
	# 熄屏画面（AOD 息屏显示风）：黑底+暗调手写大时钟+星星点缀；停靠=显示、点亮=隐藏，
	# 盖住含灵动岛在内的一切。时钟由 refresh_banner 同步走字（world 停靠态 60s 低频渲一帧）。
	_screen_cover = Control.new()
	_screen_cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screen_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cover_bg := ColorRect.new()
	cover_bg.color = Color(0.07, 0.07, 0.09)
	cover_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screen_cover.add_child(cover_bg)
	var aod_box := VBoxContainer.new()
	aod_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	aod_box.alignment = BoxContainer.ALIGNMENT_CENTER
	aod_box.add_theme_constant_override("separation", 18)
	_screen_cover.add_child(aod_box)
	_aod_clock = Label.new()
	_aod_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if ResourceLoader.exists(HAND_FONT):
		_aod_clock.add_theme_font_override("font", load(HAND_FONT) as Font)
	_aod_clock.add_theme_font_size_override("font_size", 110)
	_aod_clock.add_theme_color_override("font_color", Color(0.62, 0.63, 0.70, 0.75)) # 暗调月光灰
	aod_box.add_child(_aod_clock)
	var aod_star := UiAssets.icon_rect("st_star", 64.0)
	aod_star.modulate = Color(1.0, 1.0, 1.0, 0.28) # 暗夜里一颗淡星
	aod_box.add_child(aod_star)
	vp.add_child(_screen_cover)

## 跨页 app 视图：返回条（返回键+标题）+ 竖向滚动的页面宿主（flowers/items/settings）。
func _build_spread(vp: SubViewport) -> void:
	# 跨页底：微皱白纸+中缝折痕阴影（实拍 CC0 纸纹合成，非 AIGC）；缺资产回退奶油纯色
	var bg_tex := UiAssets.tex("phone3d_spread_bg")
	if bg_tex != null:
		var tex_bg := TextureRect.new()
		tex_bg.texture = bg_tex
		tex_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_bg.stretch_mode = TextureRect.STRETCH_SCALE
		tex_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		vp.add_child(tex_bg)
	else:
		var bg := ColorRect.new()
		bg.color = UiAssets.CARD_BG
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		vp.add_child(bg)
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 纯纸跨页无边框装饰，留呼吸边距即可
	pad.add_theme_constant_override("margin_left", 48)
	pad.add_theme_constant_override("margin_right", 48)
	pad.add_theme_constant_override("margin_top", 36)
	pad.add_theme_constant_override("margin_bottom", 48)
	vp.add_child(pad)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	pad.add_child(vbox)
	var app_bar := HBoxContainer.new()
	app_bar.add_theme_constant_override("separation", 8)
	var back_btn := Button.new()
	back_btn.text = "返回"
	back_btn.add_theme_font_size_override("font_size", 28)
	UiAssets.style_card_button(back_btn)
	back_btn.pressed.connect(func() -> void:
		if _w.game_audio != null:
			_w.game_audio.play_sfx("exit")
		close_app())
	app_bar.add_child(back_btn)
	_phone_app_title = Label.new()
	UiAssets.style_card_label(_phone_app_title, 40)
	_phone_app_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phone_app_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	app_bar.add_child(_phone_app_title)
	var app_bar_spacer := Control.new() # 标题视觉居中（右侧留与返回键等宽的空）
	app_bar_spacer.custom_minimum_size = Vector2(110.0, 0.0)
	app_bar.add_child(app_bar_spacer)
	vbox.add_child(app_bar)
	# 页面宿主套竖向滚动：内容多的 app（设置）滚动，不撑破跨页。
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var host := VBoxContainer.new()
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(host)
	_album_pages = {
		"home": _build_home_page(),
		"flowers": _build_flowers_page(),
		"items": _build_items_page(),
		"settings": _build_settings_page(),
	}
	for pid in _album_pages:
		var pg := _album_pages[pid] as Control
		pg.visible = false
		pg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		host.add_child(pg)

## ── 主屏部件 ────────────────────────────────────────────────────────────────

## 桌面 widget（整条卡片，少文字纯 UI）：左「可玩时间闹钟饼图」+ 右「小红花图标+数」。
func _build_phone_widget() -> PanelContainer:
	var card := PanelContainer.new()
	var cs := UiAssets.card_style(18.0, 1.0)
	cs.shadow_size = 0
	card.add_theme_stylebox_override("panel", cs)
	var pad := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(side, 12)
	card.add_child(pad)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	pad.add_child(row)
	var pie_box := CenterContainer.new()
	pie_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phone_playpie = PlayTimePie.new()
	_phone_playpie.custom_minimum_size = Vector2(72.0, 72.0)
	pie_box.add_child(_phone_playpie)
	row.add_child(pie_box)
	row.add_child(VSeparator.new())
	var fl_box := HBoxContainer.new()
	fl_box.alignment = BoxContainer.ALIGNMENT_CENTER
	fl_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fl_box.add_theme_constant_override("separation", 6)
	fl_box.add_child(UiAssets.icon_rect("reward_flower", 38.0))
	_phone_flowers = Label.new()
	UiAssets.style_card_label(_phone_flowers, 30)
	fl_box.add_child(_phone_flowers)
	row.add_child(fl_box)
	return card

## 一个 app 图标格：iOS 圆角小卡 + 图标 + 下方短名。app=[id, 短名, 图标资产]。
func _make_app_icon(app: Array) -> Control:
	var id := String(app[0])
	var tex := UiAssets.tex(String(app[2]))
	if tex == null:
		tex = UiAssets.tex(String(PHONE_APP_FALLBACK.get(id, "st_star")))
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(72.0, 72.0)
	btn.icon = tex
	btn.expand_icon = true
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.add_theme_constant_override("icon_max_width", 56)
	# app 图标底：近白 + 明显沙色描边 + 稍大投影（比奶油底对比高，像贴上去的贴纸）。
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1.0, 1.0, 0.995)
	st.set_corner_radius_all(20)
	st.set_border_width_all(2)
	st.border_color = Color(0.85, 0.72, 0.50)
	st.shadow_color = Color(0.35, 0.24, 0.10, 0.32)
	st.shadow_size = 5
	st.shadow_offset = Vector2(0.0, 3.0)
	btn.add_theme_stylebox_override("normal", st)
	var stp: StyleBoxFlat = st.duplicate()
	stp.bg_color = UiAssets.CARD_ACCENT
	btn.add_theme_stylebox_override("hover", stp)
	btn.add_theme_stylebox_override("pressed", stp)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.pressed.connect(open_app.bind(id))
	box.add_child(btn)
	var cap := Label.new()
	cap.text = String(app[1])
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiAssets.style_card_label(cap, 22)
	box.add_child(cap)
	return box

## 按 PHONE_APPS 切页填充图标（每页 3x3=9 格，不足不铺留白，仿 iPhone 主屏）。
func _build_phone_pages() -> void:
	for c in _phone_pages_box.get_children():
		c.queue_free()
	var n := PHONE_APPS.size()
	var pages := int(ceil(float(maxi(n, 1)) / float(PHONE_PAGE_SLOTS)))
	var idx := 0
	for _p in pages:
		var page := HBoxContainer.new() # 页宽=分页容器宽（tick 同步），网格水平+垂直居中
		page.alignment = BoxContainer.ALIGNMENT_CENTER
		var g := GridContainer.new()
		g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		g.columns = PHONE_GRID_COLS
		g.add_theme_constant_override("h_separation", 22)
		g.add_theme_constant_override("v_separation", 22)
		for _s in PHONE_PAGE_SLOTS:
			if idx < n:
				g.add_child(_make_app_icon(PHONE_APPS[idx]))
				idx += 1
		page.add_child(g)
		_phone_pages_box.add_child(page)

## 翻页圆点：>1 页才显示，当前页高亮。
func _rebuild_phone_dots() -> void:
	if _phone_dots == null:
		return
	for c in _phone_dots.get_children():
		c.queue_free()
	var pages := _phone_pages_box.get_child_count() if _phone_pages_box != null else 0
	_phone_dots.visible = pages > 1
	for i in pages:
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(8.0, 8.0)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.add_theme_stylebox_override("panel", _phone_dot_style(i == _phone_page))
		_phone_dots.add_child(dot)

## 只重着色圆点（页切换时用，不重建节点）。
func _highlight_phone_dot() -> void:
	if _phone_dots == null:
		return
	var i := 0
	for dot in _phone_dots.get_children():
		(dot as Panel).add_theme_stylebox_override("panel", _phone_dot_style(i == _phone_page))
		i += 1

func _phone_dot_style(active: bool) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.set_corner_radius_all(4)
	st.bg_color = Color(0.35, 0.24, 0.10, 0.85) if active else Color(0.35, 0.24, 0.10, 0.28)
	return st

## 状态栏信号格：三根递增小竖条；颜色由 refresh_banner 按 WS 在线态刷（绿/灰）。
func _make_signal_indicator() -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.alignment = BoxContainer.ALIGNMENT_END
	for h in [10.0, 16.0, 22.0]:
		var bar := ColorRect.new()
		bar.custom_minimum_size = Vector2(5.0, h)
		bar.size_flags_vertical = Control.SIZE_SHRINK_END
		box.add_child(bar)
	return box

## 分页拖拽：ScrollContainer 原生拖动横滚，松手时贴合到最近页并更新圆点。
func _on_phone_pager_input(e: InputEvent) -> void:
	var pressed := false
	if e is InputEventScreenTouch:
		pressed = (e as InputEventScreenTouch).pressed
	elif e is InputEventMouseButton:
		pressed = (e as InputEventMouseButton).pressed
	else:
		return
	if pressed:
		_phone_pager_dragging = true
	else:
		_phone_pager_dragging = false
		if _phone_page_w > 1.0 and _phone_pages_box != null:
			var last := maxi(0, _phone_pages_box.get_child_count() - 1)
			_phone_page = clampi(int(round(_phone_pager.scroll_horizontal / _phone_page_w)), 0, last)
			_highlight_phone_dot()

## 熄屏/点亮（world 在停靠/掏出时切）。
func set_screen_off(off: bool) -> void:
	if _screen_cover != null:
		_screen_cover.visible = off

## ── 每帧驱动（world 在手机打开时调）────────────────────────────────────────

## 分页步进 + banner 每秒刷新（时钟走字/信号格/饼图）。
func tick(delta: float) -> void:
	_step_phone_pager(delta)
	_phone_ui_t -= delta
	if _phone_ui_t > 0.0:
		return
	_phone_ui_t = 1.0
	refresh_banner()

## 同步单页宽=容器宽；未拖拽时把滚动缓动贴合到当前页。
func _step_phone_pager(delta: float) -> void:
	if _phone_pager == null:
		return
	var w := _phone_pager.size.x
	if w > 1.0 and not is_equal_approx(w, _phone_page_w):
		_phone_page_w = w
		for pg in _phone_pages_box.get_children():
			(pg as Control).custom_minimum_size.x = w
	if not _phone_pager_dragging and _phone_page_w > 1.0:
		var target := int(round(_phone_page * _phone_page_w))
		var cur := _phone_pager.scroll_horizontal
		if absi(cur - target) > 1:
			_phone_pager.scroll_horizontal = int(round(lerpf(float(cur), float(target), minf(1.0, 12.0 * delta))))
		else:
			_phone_pager.scroll_horizontal = target

## ── app 导航 ────────────────────────────────────────────────────────────────

## 打开一个 app：跨页只显示该页并刷新，发 app_opened（world 翻到跨页）。
func open_app(id: String) -> void:
	if not _album_pages.has(id):
		return
	if _w.game_audio != null:
		_w.game_audio.play_sfx("select")
	_phone_open_app = id
	for pid in _album_pages:
		(_album_pages[pid] as Control).visible = (pid == id)
	for entry in PHONE_APPS:
		if String(entry[0]) == id:
			_phone_app_title.text = String(entry[1])
	if id == "flowers" or id == "items":
		refresh_album()
	app_opened.emit(id)
	# 小红花页：把小朋友还没见证过的章补演出来（他自己一锤一锤盖上去）
	if id == "flowers" and has_pending_stamps():
		play_ceremony(StampCeremony.plan(_w.stamp_seen, _w.wallet, _w.take_stamp_styles()))

## 返回主屏：收起设置页的确认/预览子部件，发 back_pressed（world 翻回正面）。
## 仪式演到一半就关：中止且不提交见证游标——下次打开手机重演，小朋友不会平白丢掉一次盖章。
func close_app() -> void:
	_phone_open_app = ""
	if _ceremony_playing:
		_ceremony_abort = true
	if _reroll_confirm != null:
		_reroll_confirm.visible = false
	if _avatar_preview != null:
		_avatar_preview.visible = false
		_avatar_hash = ""
		_avatar_anchors = {}
	back_pressed.emit()

## ── 状态栏/桌面 widget 刷新 ─────────────────────────────────────────────────

## 状态栏时钟（实时）+ 信号格（WS 在线态）+ widget 饼图与小红花数。
func refresh_banner() -> void:
	if _phone_clock == null:
		return
	var t := Time.get_time_dict_from_system()
	var hh := int(t.get("hour", 0))
	var mm := int(t.get("minute", 0))
	_phone_clock.text = "%02d:%02d" % [hh, mm]
	if _phone_playpie != null:
		# 可玩阶段显示绿色剩余、冷却阶段显示蓝色进度（值由 world._step_play_budget 每帧更新）。
		_phone_playpie.set_state(_w._play_remaining_frac, _w._play_blocked, _w._play_cooldown_frac)
	if _phone_flowers != null:
		_phone_flowers.text = "x%d" % _w._red_flower_count()
	if _aod_clock != null:
		_aod_clock.text = _phone_clock.text # 熄屏画面同步走字
	if _phone_signal != null:
		var online: bool = _w.backend != null and _w.backend.is_online()
		var col := Color(0.30, 0.78, 0.42) if online else Color(0.60, 0.60, 0.60, 0.5)
		for bar in _phone_signal.get_children():
			(bar as ColorRect).color = col

## ── 跨页双页布局 ────────────────────────────────────────────────────────────

## 摊开的双页：左右两个竖排页容器，中缝（装订线）两侧各留半页边距。
## 返回 { "row": 整行, "left": 左页, "right": 右页 }。
func _make_spread_pages() -> Dictionary:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 96) # 跨过中缝装订线
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(left)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(right)
	return { "row": row, "left": left, "right": right }

## ── 回家 app ────────────────────────────────────────────────────────────────

## 「回家」app：迷路/卡在别的场景（如穿传送门进森林被树围死）时的逃生舱。跨页正中一个大
## 「回家」按钮，点了收起手机 + 把玩家送回初始世界原点（world._go_home）。用确认页而非点
## 图标直接传送，防小手误触把自己传走。图标缺 app_home 素材时回退定位钉 ic_pin。
func _build_home_page() -> Control:
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_theme_constant_override("separation", 28)
	var icon_name := "app_home" if ResourceLoader.exists("res://assets/ui/app_home.png") else "ic_pin"
	var icon := UiAssets.icon_rect(icon_name, 160.0)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	page.add_child(icon)
	var hint := Label.new()
	hint.text = "迷路了吗？\n点一下回到家！"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	UiAssets.style_card_label(hint, 34)
	page.add_child(hint)
	var go := Button.new()
	go.text = "回家"
	go.icon = UiAssets.tex(icon_name)
	go.add_theme_constant_override("icon_max_width", 48)
	go.add_theme_font_size_override("font_size", 44)
	go.custom_minimum_size = Vector2(280.0, 100.0)
	go.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UiAssets.style_card_button(go)
	go.pressed.connect(_on_home_pressed)
	_home_btn = go
	page.add_child(go)
	return page

## 点「回家」：确认音效 → world 收起手机并把玩家传回初始世界原点（在线跨场景走过场遮罩，
## 已在家/离线就地挪回原点空位解卡）。
func _on_home_pressed() -> void:
	if _w.game_audio != null:
		_w.game_audio.play_sfx("confirm")
	_w._go_home()

## ── 小红花/集邮 app ─────────────────────────────────────────────────────────

## 集邮册跨页：左页花田（3×3 土坑，长出来的小红花）；右页盖章卡（三个槽，攒满三章种一朵花）。
## 两块都是自绘控件（FlowerField / StampCard），空位画虚线幽灵圆而不是把图标调灰——
## 灰疙瘩说的是「坏掉了」，虚线留白说的是「这儿等着被填」（见 docs/stamp-flower-ux-design.md §2）。
func _build_flowers_page() -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(0.0, 820.0)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_flower_field = FlowerField.new()
	_flower_field.anchor_left = 0.0
	_flower_field.anchor_right = 0.455        # 中缝左侧
	_flower_field.anchor_top = 0.0
	_flower_field.anchor_bottom = 0.86
	_flower_field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_flower_field)

	_stamp_card = StampCard.new()
	_stamp_card.anchor_left = 0.545           # 中缝右侧
	_stamp_card.anchor_right = 1.0
	_stamp_card.anchor_top = 0.0
	_stamp_card.anchor_bottom = 0.86
	_stamp_card.tapped.connect(_on_stamp_card_tapped)
	root.add_child(_stamp_card)

	# 页脚：累计盖章数 + 收到的爱心（去文字化，图标 + 数字）
	var foot := HBoxContainer.new()
	foot.anchor_left = 0.0
	foot.anchor_right = 1.0
	foot.anchor_top = 0.88
	foot.anchor_bottom = 1.0
	foot.alignment = BoxContainer.ALIGNMENT_CENTER
	foot.add_theme_constant_override("separation", 48)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var total_row := HBoxContainer.new()
	total_row.add_theme_constant_override("separation", 10)
	total_row.add_child(UiAssets.icon_rect("stamp_star", 46.0))
	_stamps_total_label = Label.new()
	UiAssets.style_card_label(_stamps_total_label, 42)
	total_row.add_child(_stamps_total_label)
	foot.add_child(total_row)
	var hearts_row := HBoxContainer.new()
	hearts_row.add_theme_constant_override("separation", 10)
	hearts_row.add_child(UiAssets.icon_rect("em_heart", 46.0))
	_hearts_label = Label.new()
	UiAssets.style_card_label(_hearts_label, 42)
	hearts_row.add_child(_hearts_label)
	foot.add_child(hearts_row)
	root.add_child(foot)

	# 墨滴层：最后加 = 画在花田/章卡之上，才能从右页的章卡飞越中缝落到左页的土坑里
	_ink_drops = InkDrops.new()
	_ink_drops.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_ink_drops)
	return root

## 刷新小红花/集邮 + 物品页（钱包/背包数据变化、开手机、开 app 时都会调）。
## 仪式在演的时候不要用服务端的钱包去覆盖画面——那会把小朋友正在盖的章一把抹平。
func refresh_album() -> void:
	if not _ceremony_playing:
		_sync_album_to_wallet()
	if _stamps_total_label != null:
		_stamps_total_label.text = "x%d" % int(_w.wallet.get("stampsTotal", 0))
	if _hearts_label != null:
		_hearts_label.text = "x%d" % int(_w.wallet.get("hearts", 0))
	refresh_items()

## ── 盖章/种花仪式 ──────────────────────────────────────────────────────────
##
## 服务端早把账算完了（3 章换 1 花在 persistence.ts settleWallet）；这里演的是小朋友
## **还没见证过**的那几拍。分镜由 StampCeremony.plan(seen, wallet) 推导，演完
## world._commit_stamp_seen() 把见证游标推到服务端权威值。
## 中途关手机 = 中止，**不提交** —— 下次打开重演，小朋友不会平白丢掉一次盖章。

## 小朋友点了盖章卡：有橡皮章招手就砸下去。
func _on_stamp_card_tapped() -> void:
	if _stamp_card != null and _stamp_card.has_tool():
		_slam_now = true

## 橡皮章招手多久没人点就自己砸下（防幼儿盯着看把流程卡死）。回测里置 0 直接砸，别空等。
var hover_timeout := 1.2

## 有欠盖的章吗（手机角标 / 开 app 时是否起仪式）。
func has_pending_stamps() -> bool:
	return StampCeremony.pending_count(_w.stamp_seen, _w.wallet) > 0

## 仪式在演吗（world 对账据此按兵不动，别把小朋友正在盖的章抹掉）。
func ceremony_playing() -> bool:
	return _ceremony_playing

## 等一小会儿（仪式的节拍停顿）。中止时立刻返回，不拖着。
func _sleep(sec: float) -> void:
	var t := 0.0
	while t < sec and not _ceremony_abort:
		await _w.get_tree().process_frame
		t += _w.get_process_delta_time()

func play_ceremony(beats: Array) -> void:
	if _ceremony_playing or beats.is_empty():
		return
	_ceremony_playing = true
	_ceremony_abort = false
	for b in beats:
		if _ceremony_abort:
			break
		match int(b["beat"]):
			StampCeremony.Beat.STAMP:
				await _play_stamp(int(b["slot"]), String(b["style"]))
			StampCeremony.Beat.BLOOM:
				await _play_bloom(int(b["cell"]))
			StampCeremony.Beat.PLUCK:
				await _play_pluck(int(b["cell"]))
			StampCeremony.Beat.FIELD_FULL:
				await _play_field_full()
	_ceremony_playing = false
	if _ceremony_abort:
		_sync_album_to_wallet()   # 中止：回到见证游标的状态，下次重演
		return
	_w._commit_stamp_seen()       # 演完了才认账
	_sync_album_to_wallet()

## 盖一个章：橡皮章浮上来招手 → 小朋友点 → 急速砸下 → THUNK + 纸面下陷 + 整台手机后座
## → 抬起，露出盖歪的墨印。分镜时长见 docs/stamp-flower-ux-design.md §4.1。
func _play_stamp(slot: int, style: String) -> void:
	if _stamp_card == null:
		return
	_stamp_card.arm_slot(slot, style)
	_stamp_card.set_tool(slot, 0.0)
	# HOVER：等小朋友点。1.2s 没点就自己砸——幼儿园的孩子可能只是盯着看，不能卡死在这儿。
	_slam_now = false
	var waited := 0.0
	while waited < hover_timeout and not _slam_now and not _ceremony_abort:
		await _w.get_tree().process_frame
		waited += _w.get_process_delta_time()
	if _ceremony_abort:
		return
	_slam_now = false

	# SLAM：0.10s 急速砸下（EASE_IN——加速度全压在最后一刻，才有"砸"感，匀速就是"放"）
	var down: Tween = _w.create_tween()
	down.tween_method(func(v: float) -> void: _stamp_card.set_tool(slot, v), 0.0, 1.0, 0.10) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await down.finished
	if _ceremony_abort:
		return

	# IMPACT：闷响 + 纸面被压得下陷回弹 + 整台 3D 手机一记后座 + 星芒炸开
	if _w.game_audio != null:
		_w.game_audio.play_sfx("thunk")
	if _w.paper_phone != null:
		_w.paper_phone.kick(1.0)
	var hit: Tween = _w.create_tween()
	hit.set_parallel(true)
	hit.tween_method(func(v: float) -> void: _stamp_card.set_squash(v), 1.0, 0.0, 0.22) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	hit.tween_method(func(v: float) -> void: _stamp_card.set_flash(v), 0.0, 1.0, 0.20)
	hit.tween_method(func(v: float) -> void: _stamp_card.set_print(slot, v), 0.0, 1.0, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# LIFT：抬起（比砸下慢一倍，看清墨印）
	hit.tween_method(func(v: float) -> void: _stamp_card.set_tool(slot, v), 1.0, 0.0, 0.24) \
		.set_delay(0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await hit.finished
	_stamp_card.set_flash(0.0)
	_stamp_card.set_squash(0.0)
	_stamp_card.set_tool(-1, 0.0)
	await _sleep(0.15)   # 两个章之间喘口气

## 三章种出一朵花：三个章一起发金光 → 墨浮起来凝成三滴 → 划弧越过对折中缝 → 渗进空土坑
## → 纸茎弹出、叶子展开 → 花绽放 + 叮 + 星星。分镜时长见 design §4.2。
func _play_bloom(cell: int) -> void:
	if _flower_field == null or _stamp_card == null:
		return
	# GLOW：三个章一起发金光（"要变魔法了"）
	var glow: Tween = _w.create_tween()
	glow.tween_method(func(v: float) -> void: _stamp_card.set_glow(v), 0.0, 1.0, 0.25)
	await glow.finished
	if _ceremony_abort:
		return

	# INK_LIFT + FLY：墨从纸上浮起来，划弧越过中缝，落进左页那格空土坑
	if _w.game_audio != null:
		_w.game_audio.play_sfx("whoosh")
	if _ink_drops != null:
		_ink_drops.launch(
			_stamp_card.position + _stamp_card.slot_center(1),   # 从章卡正中那个槽起飞
			_flower_field.position + _flower_field.cell_center(cell))
	var fly: Tween = _w.create_tween()
	fly.set_parallel(true)
	fly.tween_method(func(v: float) -> void: _ink_drops.set_progress(v), 0.0, 1.0, 0.55) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	# 墨飞走了，章卡上的墨印就淡掉（墨真的"离开"了纸面，不是凭空消失）
	for i in STAMPS_PER_FLOWER:
		fly.tween_method(func(v: float) -> void: _stamp_card.set_print(i, v), 1.0, 0.0, 0.30) \
			.set_delay(0.06 * float(i))
	fly.tween_method(func(v: float) -> void: _stamp_card.set_glow(v), 1.0, 0.0, 0.30)
	await fly.finished
	_ink_drops.stop()
	_stamp_card.clear_stamps()
	if _ceremony_abort:
		return

	# SPROUT → BLOOM → SPARK：纸茎弹出、花绽放、星星散开
	if _w.game_audio != null:
		_w.game_audio.play_sfx("bloom")
	var grow: Tween = _w.create_tween()
	grow.tween_method(func(v: float) -> void: _flower_field.set_stem(cell, v), 0.0, 1.0, 0.50) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	grow.tween_method(func(v: float) -> void: _flower_field.set_bloom(cell, v), 0.0, 1.0, 0.38) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	grow.parallel().tween_method(func(v: float) -> void: _flower_field.set_spark(cell, v), 0.0, 1.0, 0.45)
	await grow.finished
	_flower_field.set_spark(cell, 0.0)
	if _w.fairy_voice != null:
		_w.fairy_voice.try_play("flower_grown")   # 「三个章，种出一朵小红花啦！」
	await _sleep(0.25)

## 一朵花被花掉（造角色/造物扣费）：那朵花被摘起、缩小飞走。
## 花不再是无声消失的数字——小朋友得看见自己的花变成了什么。
func _play_pluck(cell: int) -> void:
	if _flower_field == null:
		return
	if _w.game_audio != null:
		_w.game_audio.play_sfx("pluck")
	var t: Tween = _w.create_tween()
	t.tween_method(func(v: float) -> void: _flower_field.set_bloom(cell, v), 1.0, 0.0, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	t.parallel().tween_method(func(v: float) -> void: _flower_field.set_stem(cell, v), 1.0, 0.0, 0.35)
	await t.finished
	await _sleep(0.10)

## 花田满 9：章卡攒满也种不出花（服务端 settleWallet 把 progress 停在 3）。
## 别默默什么都不发生——花田整体脉冲一下 + 仙子提醒「先用掉一朵」。
func _play_field_full() -> void:
	if _w.game_audio != null:
		_w.game_audio.play_sfx("oops")
	if _w.fairy_voice != null:
		_w.fairy_voice.try_play("field_full")   # 「花田满啦，先用掉一朵吧」
	if _flower_field != null:
		var t: Tween = _w.create_tween()
		t.tween_method(func(v: float) -> void: _flower_field.modulate = Color(1, 1, 1, v), 1.0, 0.55, 0.18)
		t.tween_method(func(v: float) -> void: _flower_field.modulate = Color(1, 1, 1, v), 0.55, 1.0, 0.30)
		await t.finished
	await _sleep(0.20)

## 把花田/章卡直接摆成「见证游标」的状态（无动画）。仪式演完后也调它做最终对齐。
func _sync_album_to_wallet() -> void:
	var seen: Dictionary = _w.stamp_seen
	if _flower_field != null:
		_flower_field.set_flowers(int(seen.get("flowers", 0)))
	if _stamp_card != null:
		var prog := int(seen.get("stampProgress", 0))
		# 章卡上这几个章分别是第几个章 → 决定用哪款（与服务端发章顺序对齐）
		_stamp_card.set_progress(prog, int(seen.get("stampsTotal", 0)) - prog)
		_stamp_card.set_tool(-1, 0.0)

## ── 物品 app ────────────────────────────────────────────────────────────────

## 物品货架跨页：一张 6 列大格货架摊在双页上（跨中缝像真手账），份数手写角标风。
func _build_items_page() -> Control:
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.alignment = BoxContainer.ALIGNMENT_CENTER
	_items_grid = GridContainer.new()
	_items_grid.columns = 6
	_items_grid.add_theme_constant_override("h_separation", 26)
	_items_grid.add_theme_constant_override("v_separation", 30)
	_items_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_items_empty = Label.new()
	_items_empty.text = "还没有收起来的物品"
	_items_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_items_empty.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_items_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UiAssets.style_card_label(_items_empty, 34)
	page.add_child(_items_grid)
	page.add_child(_items_empty)
	# 贴纸小铺（docs/sticker-items-design.md §2.3）：物品页内嵌货架，1 朵小红花一张。
	var shop_title := Label.new()
	shop_title.text = "🌸 贴纸小铺 · 一朵小红花换一张"
	shop_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shop_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UiAssets.style_card_label(shop_title, 30)
	page.add_child(shop_title)
	_shop_grid = GridContainer.new()
	_shop_grid.columns = 6
	_shop_grid.add_theme_constant_override("h_separation", 26)
	_shop_grid.add_theme_constant_override("v_separation", 24)
	_shop_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	page.add_child(_shop_grid)
	return page

## 重建贴纸小铺货架（离线清空——买卖要服务端点头）。贴图直接用世界渲染同款。
func _refresh_sticker_shop() -> void:
	if _shop_grid == null:
		return
	for c in _shop_grid.get_children():
		c.queue_free()
	if _w == null or not _w.online:
		return
	for item_id in ItemCatalog.sticker_ids():
		var def := ItemCatalog.get_def(item_id)
		var key := String(def.get("renderRef", "")).get_slice(":", 1)
		var tex := PackRegistry.load_resource(key) as Texture2D # stickers pack（category "sticker"）
		if tex == null:
			continue
		var cell := VBoxContainer.new()
		cell.alignment = BoxContainer.ALIGNMENT_CENTER
		cell.custom_minimum_size = Vector2(104.0, 0.0)
		var btn := TextureButton.new()
		btn.texture_normal = tex
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		btn.custom_minimum_size = Vector2(84.0, 84.0)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.pressed.connect(func() -> void: _w.backend.send_sticker_buy(_w.world_id, String(item_id)))
		var name_label := Label.new()
		name_label.text = String(def.get("name", "贴纸"))
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.custom_minimum_size = Vector2(104.0, 0.0)
		UiAssets.style_card_label(name_label, 24)
		cell.add_child(btn)
		cell.add_child(name_label)
		_shop_grid.add_child(cell)

## 重建背包网格（礼盒贴纸+物件名+份数）。数据源是服务端权威 bag 计数，
## 名字/spec 从 ItemCatalog 实体定义取。物件不多，全量重建最简单。
func refresh_items() -> void:
	if _items_grid == null:
		return
	for c in _items_grid.get_children():
		c.queue_free()
	var ids := []
	for item_id in _w.bag:
		if int(_w.bag[item_id]) > 0:
			ids.append(String(item_id))
	ids.sort()
	_items_empty.visible = ids.is_empty()
	for item_id in ids:
		var def := ItemCatalog.get_def(item_id)
		var count := int(_w.bag[item_id])
		var cell := VBoxContainer.new()
		cell.alignment = BoxContainer.ALIGNMENT_CENTER
		cell.custom_minimum_size = Vector2(104.0, 0.0)
		# 贴纸显示本尊贴图（一眼认出买了啥），其余物件保留礼盒图标
		var skey := String(def.get("renderRef", "")).get_slice(":", 1)
		var stex: Texture2D = null
		if String(def.get("renderRef", "")).begins_with("sticker:"):
			stex = PackRegistry.load_resource(skey) as Texture2D
		var glyph: BaseButton
		if stex != null:
			var tb := TextureButton.new()
			tb.texture_normal = stex
			tb.ignore_texture_size = true
			tb.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
			tb.custom_minimum_size = Vector2(92.0, 92.0)
			tb.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			glyph = tb
		else:
			glyph = UiAssets.icon_button("ic_gift", 92.0) # 点一下进摆放模式（自己选位）
		glyph.pressed.connect(func() -> void: _w._begin_placement(String(item_id)))
		var name_label := Label.new()
		var display := String(def.get("name", "小玩意"))
		name_label.text = display if count <= 1 else "%s×%d" % [display, count]
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		name_label.custom_minimum_size = Vector2(104.0, 0.0)
		UiAssets.style_card_label(name_label, 26)
		cell.add_child(glyph)
		cell.add_child(name_label)
		_items_grid.add_child(cell)
	_refresh_sticker_shop()

## ── 设置 app ────────────────────────────────────────────────────────────────

## 设置跨页：左页「我的形象」（重捏/换形象+预览），右页「画质」旋钮组。
func _build_settings_page() -> Control:
	var pages := _make_spread_pages()
	var settings_page := pages["left"] as VBoxContainer
	settings_page.add_theme_constant_override("separation", 18)
	# 重新捏角色（回童话书重新自我介绍；onboarding 合并保存档案，贴纸/物品不丢）
	var reroll := Button.new()
	reroll.text = "重新捏角色"
	reroll.icon = UiAssets.tex("ic_retry")
	reroll.add_theme_constant_override("icon_max_width", 40)
	reroll.add_theme_font_size_override("font_size", 32)
	UiAssets.style_card_button(reroll)
	reroll.pressed.connect(_on_reroll_pressed)
	_reroll_btn = reroll
	settings_page.add_child(reroll)
	_reroll_confirm = HBoxContainer.new()
	_reroll_confirm.alignment = BoxContainer.ALIGNMENT_CENTER
	_reroll_confirm.add_theme_constant_override("separation", 12)
	_reroll_confirm.add_child(UiAssets.icon_rect("ic_question", 48.0))
	var reroll_yes := UiAssets.icon_button("ic_yes", 52.0)
	reroll_yes.pressed.connect(_on_reroll_yes)
	_reroll_confirm.add_child(reroll_yes)
	var reroll_no := UiAssets.icon_button("ic_no", 52.0)
	reroll_no.pressed.connect(_on_reroll_no)
	_reroll_confirm.add_child(reroll_no)
	_reroll_confirm.visible = false
	settings_page.add_child(_reroll_confirm)
	# 换形象：免翻书只重生成形象图（名字/称呼不动），预览满意才落档案
	_avatar_btn = Button.new()
	_avatar_btn.text = "换形象"
	_avatar_btn.icon = UiAssets.tex("ic_wand")
	_avatar_btn.add_theme_constant_override("icon_max_width", 40)
	_avatar_btn.add_theme_font_size_override("font_size", 32)
	UiAssets.style_card_button(_avatar_btn)
	_avatar_btn.pressed.connect(_on_avatar_regen_pressed)
	settings_page.add_child(_avatar_btn)
	_avatar_preview = VBoxContainer.new()
	_avatar_preview.alignment = BoxContainer.ALIGNMENT_CENTER
	_avatar_preview.add_theme_constant_override("separation", 12)
	_avatar_img = TextureRect.new()
	_avatar_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar_img.custom_minimum_size = Vector2(200.0, 200.0)
	_avatar_img.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_avatar_preview.add_child(_avatar_img)
	var avatar_row := HBoxContainer.new()
	avatar_row.alignment = BoxContainer.ALIGNMENT_CENTER
	avatar_row.add_theme_constant_override("separation", 16)
	var avatar_yes := UiAssets.icon_button("ic_yes", 52.0)
	avatar_yes.pressed.connect(_on_avatar_regen_yes)
	avatar_row.add_child(avatar_yes)
	var avatar_no := UiAssets.icon_button("ic_no", 52.0)
	avatar_no.pressed.connect(_on_avatar_regen_no)
	avatar_row.add_child(avatar_no)
	_avatar_preview.add_child(avatar_row)
	_avatar_preview.visible = false
	settings_page.add_child(_avatar_preview)
	# —— 说话分区：小龄玩家的「说完先听一遍」开关（家长照副标题就能自己权衡）——
	var talk_title := Label.new()
	talk_title.text = "说话"
	UiAssets.style_card_label(talk_title, 30)
	talk_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	settings_page.add_child(talk_title)
	var confirm_card := VBoxContainer.new()
	confirm_card.add_theme_constant_override("separation", 2)
	var confirm_row := HBoxContainer.new()
	confirm_row.add_theme_constant_override("separation", 8)
	var confirm_name := Label.new()
	confirm_name.text = "说完先听一遍"
	UiAssets.style_card_label(confirm_name, 22)
	confirm_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_row.add_child(confirm_name)
	_confirm_voice_btn = Button.new()
	_confirm_voice_btn.toggle_mode = true
	_confirm_voice_btn.add_theme_font_size_override("font_size", 20)
	_confirm_voice_btn.clip_text = true
	_confirm_voice_btn.custom_minimum_size = Vector2(96.0, 0.0)
	UiAssets.style_card_button(_confirm_voice_btn)
	_confirm_voice_btn.toggled.connect(func(on: bool) -> void: _w._on_confirm_voice_toggled(on))
	confirm_row.add_child(_confirm_voice_btn)
	confirm_card.add_child(confirm_row)
	var confirm_sub := Label.new()
	confirm_sub.text = "小小孩说话容易说一半。开了以后，跟小伙伴说完话，会把刚才那句放给他听，他点「就是这样」才发出去。"
	UiAssets.style_card_label(confirm_sub, 18)
	confirm_sub.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	confirm_sub.modulate = Color(1.0, 1.0, 1.0, 0.75)
	confirm_card.add_child(confirm_sub)
	settings_page.add_child(confirm_card)
	refresh_confirm_voice_button()
	# —— 右页画质分区：GraphicsSettings 的 9 个旋钮，每个一张卡片。点档位按钮升一档、
	# 到顶回最省，即时应用 + 存 profile（source=user，应用逻辑在 world）。——
	var gfx_page := pages["right"] as VBoxContainer
	gfx_page.add_theme_constant_override("separation", 8)
	var gfx_title := Label.new()
	gfx_title.text = "画质"
	UiAssets.style_card_label(gfx_title, 30) # 白纸底上用暖棕字（默认白色看不清）
	gfx_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gfx_page.add_child(gfx_title)
	_gfx_buttons = {}
	for key: String in GraphicsSettings.KEYS:
		var pad := MarginContainer.new()  # 别让说明文字贴到页缘
		pad.add_theme_constant_override("margin_left", 4)
		pad.add_theme_constant_override("margin_right", 4)
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 2)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_lbl := Label.new()
		name_lbl.text = String(GraphicsSettings.LABELS[key])
		UiAssets.style_card_label(name_lbl, 22)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_lbl)
		var b := Button.new()
		b.toggle_mode = true  # 非 0 档 = 按下态（style_card_button 给 pressed 态上暖黄底）
		b.add_theme_font_size_override("font_size", 20)
		b.clip_text = true
		b.custom_minimum_size = Vector2(96.0, 0.0)
		UiAssets.style_card_button(b)
		b.toggled.connect(func(on: bool) -> void: _w._on_graphics_cycle(on, key))
		row.add_child(b)
		card.add_child(row)
		var sub := Label.new()  # 「关掉后会看到什么」——家长照着这行就能自己权衡
		sub.text = String(GraphicsSettings.SUBTITLES[key])
		UiAssets.style_card_label(sub, 18)
		sub.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		sub.modulate = Color(1.0, 1.0, 1.0, 0.75)
		card.add_child(sub)
		pad.add_child(card)
		gfx_page.add_child(pad)
		_gfx_buttons[key] = b
		refresh_gfx_button(key)
	# 「恢复自动」：清掉用户 override，把定档权交回 benchmark / 后端下发
	var gfx_auto := Button.new()
	gfx_auto.text = "恢复自动画质"
	gfx_auto.add_theme_font_size_override("font_size", 20)
	gfx_auto.clip_text = true
	UiAssets.style_card_button(gfx_auto)
	gfx_auto.pressed.connect(func() -> void: _w._on_gfx_restore_auto())
	gfx_page.add_child(gfx_auto)
	# 「重新检测」：换了系统/发烫/手感变了 → 重跑一次 benchmark 定档
	var gfx_bench := Button.new()
	gfx_bench.text = "重新检测画质"
	gfx_bench.add_theme_font_size_override("font_size", 20)
	gfx_bench.clip_text = true
	UiAssets.style_card_button(gfx_bench)
	gfx_bench.pressed.connect(func() -> void: _w._on_gfx_rebench())
	gfx_page.add_child(gfx_bench)
	return pages["row"]

## 「说完先听一遍」开关按钮：文案+按下态跟随档案里的 confirm_voice。
func refresh_confirm_voice_button() -> void:
	if _confirm_voice_btn == null:
		return
	var on := PlayerProfile.confirm_voice()
	_confirm_voice_btn.button_pressed = on
	_confirm_voice_btn.text = "开" if on else "关"

## 档位按钮文案（「开」/「高清」/「粗略」…）+ 按下态跟随当前档（档数据在 world._gfx_levels）。
func refresh_gfx_button(key: String) -> void:
	var b := _gfx_buttons.get(key) as Button
	if b == null:
		return
	var lv := GraphicsSettings.clamp_level(key, int(_w._gfx_levels.get(key, 0)))
	var names: Array = GraphicsSettings.LEVEL_NAMES[key]
	b.text = String(names[lv])
	b.set_pressed_no_signal(lv > 0)

## 设置页：重新捏角色——先 ？✓✗ 确认一遍防小手误触，确认后回童话书 onboarding。
func _on_reroll_pressed() -> void:
	if _w.game_audio != null:
		_w.game_audio.play_sfx("click")
	_reroll_confirm.visible = true

## 点按音效放完再切场景（world 一切走音就断了，同 menu.gd 的 _go_to）。
func _on_reroll_yes() -> void:
	if _w.game_audio != null:
		_w.game_audio.play_sfx("confirm")
		await _w.get_tree().create_timer(0.15).timeout
	_w.get_tree().change_scene_to_file("res://onboarding.tscn")

func _on_reroll_no() -> void:
	if _w.game_audio != null:
		_w.game_audio.play_sfx("click")
	_reroll_confirm.visible = false

## 设置页：换形象——用档案答案重新生图（走服务端朝向保险丝），预览 ✓ 才落档案并热更新。
func _on_avatar_regen_pressed() -> void:
	if _avatar_btn.disabled:
		return
	_avatar_btn.disabled = true
	_avatar_preview.visible = false
	var desc := PlayerProfile.avatar_description(PlayerProfile.load_profile())
	var res: Dictionary = await _w.api.post_json("/player-sprite", { "visualDescription": desc })
	var new_hash := String(res.get("spriteAsset", ""))
	var tex: Texture2D = null
	if not new_hash.is_empty():
		tex = await _w.api.fetch_texture(new_hash)
	if not is_instance_valid(_avatar_btn) or not _w.is_inside_tree():
		return # 面板已销毁（切场景），静默放弃
	_avatar_btn.disabled = false
	if tex == null:
		return # 离线/生成失败：按钮恢复可再试，不打断小朋友
	var anch: Variant = res.get("anchors")
	_avatar_anchors = anch if typeof(anch) == TYPE_DICTIONARY else {}
	_avatar_hash = new_hash
	_avatar_img.texture = tex
	_avatar_preview.visible = true
	_w.game_audio.play_sfx("reveal")

func _on_avatar_regen_yes() -> void:
	if _avatar_hash.is_empty():
		return
	var profile := PlayerProfile.load_profile()
	profile["sprite_asset"] = _avatar_hash
	profile["anchors"] = _avatar_anchors # 与 sprite_asset 成对落档；换形象后旧锚点必须一起换掉
	PlayerProfile.save_profile(profile)
	_avatar_hash = ""
	_avatar_anchors = {}
	_avatar_preview.visible = false
	_w.game_audio.play_sfx("confirm")
	_w._apply_player_sprite() # 热更新在场玩家贴图，立即生效

func _on_avatar_regen_no() -> void:
	_avatar_hash = ""
	_avatar_anchors = {}
	_avatar_preview.visible = false
