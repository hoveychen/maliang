class_name FlowerField
extends Control
## 集邮册左页：花田（3×3 九格）。全自绘，不新增图片资产（花本身用现成的 reward_flower 贴纸）。
##
## 空格画成**虚线幽灵圆 + 一朵极淡的花影**，不是把图标 modulate 成灰疙瘩——灰疙瘩说的是
## 「坏掉了」，虚线留白说的是「这儿等着被填」（Pokopia 集章卡的做法，见 design §1）。
##
## 每格的状态是一个 0..1 的 `_bloom` 值：0=空土坑，1=花开满。开花动画由 PhoneUi 用
## Tween 驱动 `set_bloom(i, v)`（tween_method 直接喂 setter），本控件只负责画。

const COLS := 3
const ROWS := 3

const SOIL_COL := Color(0.86, 0.78, 0.62)        ## 土坑
const SOIL_DEEP := Color(0.80, 0.71, 0.54)
const GHOST_COL := Color(0.84, 0.76, 0.60)       ## 空位虚线
const GHOST_FLOWER := Color(0.72, 0.68, 0.62, 0.17) ## 空位的花影（将来会长出什么）
const STEM_COL := Color(0.56, 0.75, 0.42)        ## 纸茎
const LEAF_COL := Color(0.62, 0.80, 0.47)
const SHADOW_COL := Color(0.42, 0.34, 0.22, 0.18)
const SPARK_COL := Color(1.0, 0.86, 0.42)

var _bloom := PackedFloat32Array()   ## 每格开放度 0..1
var _stem := PackedFloat32Array()    ## 每格纸茎生长 0..1（开花动画中先于花）
var _spark := PackedFloat32Array()   ## 每格绽放星芒 0..1（一闪即逝）
var _tilt := PackedFloat32Array()    ## 每格确定性倾斜（弧度）
var _t := 0.0                        ## 微摆相位
var _flower_tex: Texture2D           ## 小红花贴图（**必须在 _draw 外预加载**，见 _ready）

func _init() -> void:
	var n := COLS * ROWS
	_bloom.resize(n)
	_stem.resize(n)
	_spark.resize(n)
	_tilt.resize(n)
	for i in n:
		# 确定性倾斜（−8°..+8°）：同一格每次进游戏歪的角度一样，不会闪来闪去
		_tilt[i] = deg_to_rad(-8.0 + 16.0 * fmod(sin(float(i) * 12.9898) * 43758.5453, 1.0))

func _ready() -> void:
	set_process(true)
	# ⚠️ 贴图必须在 _draw 之外先加载：首次 load() 发生在 _draw() 里会画成纯白占位图且不自愈
	# （见 StampCard._ready 的隔离实验记录）。这里现在能显示，只是因为别处的 TextureRect
	# 恰好先加载过 reward_flower——别依赖这个巧合。
	_flower_tex = UiAssets.tex("reward_flower")

## 纸花是活的：极缓微摆（±3°，3.4s 周期）。手机收起时视口停更，这里也不必白跑。
func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_t += delta
	queue_redraw()

## 直接设定已开花数（无动画）：开手机/离线对账时的静态刷新。
func set_flowers(n: int) -> void:
	for i in _bloom.size():
		var on := i < n
		_bloom[i] = 1.0 if on else 0.0
		_stem[i] = 1.0 if on else 0.0
		_spark[i] = 0.0
	queue_redraw()

## 单格动画钩子（Tween.tween_method 直接喂）。
func set_bloom(i: int, v: float) -> void:
	if i < 0 or i >= _bloom.size():
		return
	_bloom[i] = v
	queue_redraw()

func set_stem(i: int, v: float) -> void:
	if i < 0 or i >= _stem.size():
		return
	_stem[i] = v
	queue_redraw()

func set_spark(i: int, v: float) -> void:
	if i < 0 or i >= _spark.size():
		return
	_spark[i] = v
	queue_redraw()

func bloom_of(i: int) -> float:
	return _bloom[i] if i >= 0 and i < _bloom.size() else 0.0

## 第 i 格的中心（墨滴要飞到哪儿；PhoneUi 会转成跨页坐标）。
func cell_center(i: int) -> Vector2:
	var r := _cell_rect(i)
	return r.position + r.size * 0.5

## 格子取正方形并整体居中：控件比 3:3 高得多，直接按 h/3 分行会把每行拉成瘦高格，
## 花全挤在格底、上方一大片空——一块花圃该是紧凑的。
func _cell_rect(i: int) -> Rect2:
	var s := minf(size.x / float(COLS), size.y / float(ROWS))
	var o := Vector2((size.x - s * COLS) * 0.5, (size.y - s * ROWS) * 0.5)
	return Rect2(o + Vector2(float(i % COLS) * s, float(i / COLS) * s), Vector2(s, s))

func _draw() -> void:
	var tex := _flower_tex
	for i in COLS * ROWS:
		var r := _cell_rect(i)
		var c := r.position + r.size * 0.5
		var side := r.size.x * 0.92
		var soil_r := side * 0.42
		var soil_c := Vector2(c.x, r.position.y + r.size.y * 0.80)

		# 土坑：压扁的圆（draw_circle 没有椭圆版，用变换压 y）
		draw_set_transform(soil_c, 0.0, Vector2(1.0, 0.40))
		draw_circle(Vector2.ZERO, soil_r * 1.20, SOIL_DEEP)
		draw_circle(Vector2(0.0, -soil_r * 0.10), soil_r, SOIL_COL)
		draw_set_transform_matrix(Transform2D.IDENTITY)

		var b := _bloom[i]
		if b <= 0.001 and _stem[i] <= 0.001:
			# 空位：虚线幽灵圆 + 极淡花影
			_dashed_circle(Vector2(c.x, c.y - side * 0.06), side * 0.46, GHOST_COL, 3.0, 16)
			if tex != null:
				var gs := side * 0.62
				draw_texture_rect(tex, Rect2(c - Vector2(gs, gs) * 0.5 - Vector2(0.0, side * 0.06),
					Vector2(gs, gs)), false, GHOST_FLOWER)
			continue

		# 纸茎：从土里弹出来（开花前先长茎）
		var stem_h := side * 0.38 * _stem[i]
		if stem_h > 1.0:
			var top := soil_c - Vector2(0.0, stem_h)
			draw_line(soil_c, top, STEM_COL, 5.0)
			# 两片叶：随茎展开
			var leaf := side * 0.16 * _stem[i]
			draw_set_transform(soil_c - Vector2(0.0, stem_h * 0.55), 0.0, Vector2.ONE)
			draw_colored_polygon(PackedVector2Array([Vector2.ZERO,
				Vector2(-leaf, -leaf * 0.55), Vector2(-leaf * 1.25, leaf * 0.15)]), LEAF_COL)
			draw_colored_polygon(PackedVector2Array([Vector2.ZERO,
				Vector2(leaf, -leaf * 0.55), Vector2(leaf * 1.25, leaf * 0.15)]), LEAF_COL)
			draw_set_transform_matrix(Transform2D.IDENTITY)

		if b <= 0.001 or tex == null:
			continue
		# 花：确定性倾斜 + 微摆；坐在茎顶上
		var head := soil_c - Vector2(0.0, maxf(stem_h, side * 0.30))
		var sway := sin(_t * 1.85 + float(i) * 1.7) * deg_to_rad(3.0)
		var fs := side * 0.72
		# 落地假影（贴在土上，不随花摆）
		draw_set_transform(soil_c, 0.0, Vector2(1.0, 0.34))
		draw_circle(Vector2.ZERO, fs * 0.30 * b, SHADOW_COL)
		draw_set_transform_matrix(Transform2D.IDENTITY)
		draw_set_transform(head, _tilt[i] + sway, Vector2.ONE * b)
		draw_texture_rect(tex, Rect2(-Vector2(fs, fs) * 0.5, Vector2(fs, fs)), false)
		draw_set_transform_matrix(Transform2D.IDENTITY)

		# 绽放星芒：一闪即逝
		var sp := _spark[i]
		if sp > 0.001:
			for k in 6:
				var a := TAU * float(k) / 6.0 + _t * 0.6
				var d := side * (0.34 + 0.30 * sp)
				var p := head + Vector2(cos(a), sin(a)) * d
				draw_circle(p, side * 0.055 * (1.0 - sp), Color(SPARK_COL, 1.0 - sp))

## 虚线圆（Control 没有内建虚线绘制，按弧段画）。
func _dashed_circle(c: Vector2, radius: float, col: Color, width: float, dashes: int) -> void:
	var step := TAU / float(dashes * 2)
	for k in dashes:
		var a0 := float(k) * 2.0 * step
		draw_arc(c, radius, a0, a0 + step, 4, col, width, true)
