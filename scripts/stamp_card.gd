class_name StampCard
extends Control
## 集邮册右页：盖章卡。全自绘（卡片/虚线空槽/虚线小路/橡皮章道具/冲击星芒），章的墨印用
## 现成的 stamp_*.png 五款贴纸。
##
## 照 Pokopia 的集章卡（design §1）：
##   ① 是「一张卡放在纸页上」——自己的边、自己的影子、微微斜；
##   ② 三个槽**错落**排 + 虚线小路串起来，不是一排冰冷的圆；
##   ③ 章是**油墨印子**：盖歪几度、半透（渗进纸里），不是端端正正贴上去的贴纸。
##
## 动画状态都是 0..1 的标量，由 PhoneUi 的 Tween 喂（tween_method → setter → queue_redraw）。

signal tapped   ## 小朋友点了卡（有欠章时=砸下橡皮章）

const SLOTS := 3
const CARD_TILT := deg_to_rad(-1.8)              ## 卡片微微斜
const SLOT_DX := [-0.10, 0.10, -0.06]            ## 三槽错落（相对卡宽）
const CARD_SHADOW := Color(0.42, 0.33, 0.20, 0.26)
const CARD_FACE := Color(1.0, 0.992, 0.965)      ## 卡面比纸页更白一点，才看得出「一张卡」
const CARD_EDGE := Color(0.86, 0.75, 0.57)       ## 卡边（比 UiAssets.CARD_BORDER 更实）
const GHOST_COL := Color(0.87, 0.80, 0.66)       ## 空槽虚线
const GHOST_FILL := Color(0.965, 0.933, 0.862)
const TRAIL_COL := Color(0.89, 0.82, 0.68)       ## 槽间虚线小路
const WOOD_KNOB := Color(0.75, 0.54, 0.31)       ## 橡皮章木柄
const WOOD_BODY := Color(0.83, 0.61, 0.36)
const WOOD_FACE := Color(0.55, 0.38, 0.22)
const FLASH_COL := Color(1.0, 0.84, 0.42)
const GLOW_COL := Color(1.0, 0.85, 0.42)

var _styles: Array = ["", "", ""]     ## 每槽的章款式（""=空）
var _print := PackedFloat32Array()    ## 每槽墨印落位 0..1（1=盖实了）
var _rot := PackedFloat32Array()      ## 每槽墨印倾斜（确定性）
var _glow := 0.0                      ## 三章一起发金光（满三化墨前）
var _squash := 0.0                    ## 砸击时卡片纸面下陷 0..1
var _flash := 0.0                     ## 冲击星芒 0..1
var _tool_slot := -1                  ## 橡皮章悬在第几个槽上（-1=收起）
var _tool_drop := 0.0                 ## 橡皮章高度 0=悬停 1=贴到纸面
var _t := 0.0                         ## 招手相位
var _tex: Dictionary = {}             ## 款式 → 章贴图（**必须在 _draw 外预加载**，见 _ready）

func _init() -> void:
	_print.resize(SLOTS)
	_rot.resize(SLOTS)
	for i in SLOTS:
		_rot[i] = deg_to_rad(-9.0 + 18.0 * fmod(sin(float(i) * 78.233) * 43758.5453, 1.0))

func _ready() -> void:
	set_process(true)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# ⚠️ 五款章的贴图必须在这里先加载好。**第一次 load() 一张贴图如果发生在 _draw() 里，
	# 画出来是一张纯白占位图，而且不会自愈**（隔离实验：同一张图在 _ready 预加载 → 像素
	# (0.45,0.79,0.73) 正确；改成 _draw 里现加载 → (1,1,1,1) 纯白）。
	# 花田那边看着没事纯属侥幸——reward_flower 恰好被别处的 TextureRect 先加载过了。
	for style in StampCeremony.STYLES:
		_tex[style] = UiAssets.tex("stamp_%s" % style)

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	if _tool_slot >= 0:   # 橡皮章招手时才需要每帧重画
		_t += delta
		queue_redraw()

func _gui_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit()

## 静态刷新：进度 n（0..3）+ 起始章序号（决定各槽用哪款章，与服务端发章顺序对齐）。
func set_progress(n: int, base_index: int) -> void:
	for i in SLOTS:
		var on := i < n
		_styles[i] = StampCeremony.STYLES[(base_index + i) % StampCeremony.STYLES.size()] if on else ""
		_print[i] = 1.0 if on else 0.0
	_glow = 0.0
	queue_redraw()

## 指定某槽要盖的款式（仪式开演前先塞进去，再用 set_print 把它「压」上纸面）。
func arm_slot(i: int, style: String) -> void:
	if i < 0 or i >= SLOTS:
		return
	_styles[i] = style
	_print[i] = 0.0
	queue_redraw()

func set_print(i: int, v: float) -> void:
	if i < 0 or i >= SLOTS:
		return
	_print[i] = v
	queue_redraw()

func set_glow(v: float) -> void:
	_glow = v
	queue_redraw()

func set_squash(v: float) -> void:
	_squash = v
	queue_redraw()

func set_flash(v: float) -> void:
	_flash = v
	queue_redraw()

func set_tool(slot: int, drop: float) -> void:
	_tool_slot = slot
	_tool_drop = drop
	queue_redraw()

func clear_stamps() -> void:
	for i in SLOTS:
		_styles[i] = ""
		_print[i] = 0.0
	_glow = 0.0
	queue_redraw()

func has_tool() -> bool:
	return _tool_slot >= 0

## 第 i 槽的中心（本控件坐标，**已含卡片倾斜**；PhoneUi 转跨页坐标给墨滴落点用）。
func slot_center(i: int) -> Vector2:
	var r := _card_rect()
	var c := r.position + r.size * 0.5
	return c + _slot_local(i).rotated(CARD_TILT)

## 第 i 槽相对卡心的偏移（**未含倾斜**）：卡片变换里作图用这个。
func _slot_local(i: int) -> Vector2:
	var r := _card_rect()
	var slot_h := r.size.y / float(SLOTS)
	return Vector2(
		r.size.x * SLOT_DX[i],
		slot_h * (float(i) + 0.5) - r.size.y * 0.5)

func slot_radius() -> float:
	return _card_rect().size.x * 0.20

func _card_rect() -> Rect2:
	var w := size.x * 0.88
	var h := size.y * 0.94
	return Rect2((size.x - w) * 0.5, (size.y - h) * 0.5, w, h)

func _draw() -> void:
	var r := _card_rect()
	var c := r.position + r.size * 0.5
	# 整张卡微微斜；砸下去的一瞬间纸面被压得下陷（scaleY 0.965）再弹回
	draw_set_transform(c, CARD_TILT, Vector2(1.0, 1.0 - 0.035 * _squash))
	var local := Rect2(-r.size * 0.5, r.size)
	# 卡片投影 + 卡片本体（真·一张卡放在纸页上：更白的卡面 + 更实的边 + 一层落影）
	draw_style_box(_box(CARD_SHADOW, CARD_SHADOW, 0), Rect2(local.position + Vector2(4.0, 10.0), local.size))
	draw_style_box(_box(CARD_FACE, CARD_EDGE, 3), local)

	# 槽间虚线小路（Pokopia 的脚印路径）
	for i in SLOTS - 1:
		_dashed_line(_slot_local(i), _slot_local(i + 1), TRAIL_COL, 3.0, 7)

	var sr := slot_radius()
	for i in SLOTS:
		var sc := _slot_local(i)
		var p := _print[i]
		if p <= 0.001:
			draw_circle(sc, sr, GHOST_FILL)
			_dashed_circle(sc, sr, GHOST_COL, 3.5, 14)
			continue
		var tex: Texture2D = _tex.get(String(_styles[i]))
		if tex == null:
			continue
		# 墨印：落下时从 1.5× 缩到 1×、透明度 0→0.95（油墨渗进纸里，不是贴上去的贴纸）
		var s := sr * 2.0 * lerpf(1.5, 1.0, minf(1.0, p))
		var a := minf(0.95, p * 0.95)
		if _glow > 0.001:
			draw_circle(sc, sr * (1.05 + 0.25 * _glow), Color(GLOW_COL, 0.42 * _glow))
		# 章自己再歪几度（每槽确定性）：卡片变换之上叠一层，所以要连卡片倾斜一起给
		draw_set_transform(c + sc.rotated(CARD_TILT), CARD_TILT + _rot[i], Vector2.ONE)
		draw_texture_rect(tex, Rect2(-Vector2(s, s) * 0.5, Vector2(s, s)), false, Color(1, 1, 1, a))
		draw_set_transform(c, CARD_TILT, Vector2(1.0, 1.0 - 0.035 * _squash))

	# 冲击星芒（砸下去那一下）
	if _flash > 0.001 and _tool_slot >= 0:
		var fc := _slot_local(_tool_slot)
		draw_circle(fc, sr * (0.6 + 1.8 * _flash), Color(FLASH_COL, 0.75 * (1.0 - _flash)))

	# 橡皮章道具：悬停时上下招手，砸下时贴到纸面。
	# 悬停高度别超过槽间距的一半——否则它会飘到上一个槽的墨印身上，看着像"盖在那个章上"。
	if _tool_slot >= 0:
		var tc := _slot_local(_tool_slot)
		var lift := sr * 1.35 * (1.0 - _tool_drop)
		var bob := sin(_t * 5.0) * sr * 0.09 * (1.0 - _tool_drop)
		var at := Vector2(tc.x, tc.y - lift + bob)
		# 悬空影：离纸越近影子越小越实（"它正在压下来"）
		var near := 1.0 - lift / (sr * 1.35)
		draw_set_transform(tc, CARD_TILT, Vector2(1.0, 0.32))
		draw_circle(Vector2.ZERO, sr * (0.85 - 0.25 * near), Color(0.35, 0.27, 0.16, 0.10 + 0.10 * near))
		draw_set_transform(c, CARD_TILT, Vector2(1.0, 1.0 - 0.035 * _squash))
		_draw_tool(at, sr)
	draw_set_transform_matrix(Transform2D.IDENTITY)

## 木柄橡皮章（圆头把手 + 收腰木身 + 橡胶章面），画在给定的章面中心上。
## 全自绘：三个方块摞起来像把锤子，得有圆头、收腰、章面的湿墨反光，才像幼儿园那种木头印章。
func _draw_tool(at: Vector2, sr: float) -> void:
	var w := sr * 1.75
	var face_h := sr * 0.34
	var body_h := sr * 0.62
	var knob_r := sr * 0.42
	var face_top := at.y - face_h * 0.5

	# 章面（橡胶）：圆角深棕 + 顶上一道湿墨反光
	var face := Rect2(at.x - w * 0.5, face_top, w, face_h)
	draw_style_box(_box(WOOD_FACE, WOOD_FACE, 0), face)
	draw_rect(Rect2(face.position + Vector2(w * 0.08, face_h * 0.18), Vector2(w * 0.84, face_h * 0.16)),
		Color(1.0, 1.0, 1.0, 0.14))
	# 木身：上窄下宽的收腰梯形
	var by := face_top - body_h
	draw_colored_polygon(PackedVector2Array([
		Vector2(at.x - w * 0.46, face_top), Vector2(at.x + w * 0.46, face_top),
		Vector2(at.x + w * 0.26, by), Vector2(at.x - w * 0.26, by)]), WOOD_BODY)
	# 木身的暗侧（右侧受光反面），一笔就出体积
	draw_colored_polygon(PackedVector2Array([
		Vector2(at.x + w * 0.18, face_top), Vector2(at.x + w * 0.46, face_top),
		Vector2(at.x + w * 0.26, by), Vector2(at.x + w * 0.10, by)]), Color(0.0, 0.0, 0.0, 0.10))
	# 把手：圆头旋钮 + 细颈
	draw_rect(Rect2(at.x - w * 0.14, by - knob_r * 0.6, w * 0.28, knob_r * 0.7), WOOD_KNOB)
	draw_circle(Vector2(at.x, by - knob_r * 0.7), knob_r, WOOD_KNOB)
	draw_circle(Vector2(at.x - knob_r * 0.30, by - knob_r * 0.95), knob_r * 0.28, Color(1.0, 1.0, 1.0, 0.16))

func _box(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(16)
	return sb

func _dashed_circle(c: Vector2, radius: float, col: Color, width: float, dashes: int) -> void:
	var step := TAU / float(dashes * 2)
	for k in dashes:
		var a0 := float(k) * 2.0 * step
		draw_arc(c, radius, a0, a0 + step, 4, col, width, true)

func _dashed_line(a: Vector2, b: Vector2, col: Color, width: float, dashes: int) -> void:
	var d := (b - a) / float(dashes * 2 - 1)
	for k in dashes:
		draw_line(a + d * float(k * 2), a + d * float(k * 2 + 1), col, width, true)
