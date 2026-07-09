class_name PlayTimePie
extends Control
## 桌面 widget 的「可玩时间」可视化：一个卡通闹钟 + 中间饼图，少文字、给不识字的小朋友看。
## - 可玩阶段：绿色饼从满到空，表示本轮还能玩多久（默认每轮 45 分钟）。
## - 冷却阶段：蓝色饼从空到满，表示冷却进度（默认 10 分钟），满了又能玩。
## 数值由 world.gd 的 _update_phone_banner 每秒喂进来（见 set_state）。

const FACE_COL := Color(0.99, 0.97, 0.90)   ## 钟面奶油底
const METAL_COL := Color(0.85, 0.72, 0.50)  ## 铃铛/外壳暖金
const RIM_COL := Color(0.45, 0.33, 0.16)    ## 钟面描边
const PLAY_COL := Color(0.36, 0.78, 0.45)   ## 可玩剩余（绿）
const COOLDOWN_COL := Color(0.42, 0.62, 0.90) ## 冷却进度（蓝）

var remaining := 1.0        ## 可玩剩余比例 0..1（可玩阶段用）
var cooldown := false       ## 是否处于冷却
var cooldown_frac := 0.0    ## 冷却进度 0..1（冷却阶段用）

func _ready() -> void:
	custom_minimum_size = Vector2(58.0, 58.0)

## world.gd 每秒喂状态：剩余比例、是否冷却、冷却进度。
func set_state(rem: float, cd: bool, cd_frac: float) -> void:
	remaining = clampf(rem, 0.0, 1.0)
	cooldown = cd
	cooldown_frac = clampf(cd_frac, 0.0, 1.0)
	queue_redraw()

func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.40
	# 顶部两个铃铛 + 中间小提钮
	var bell := r * 0.30
	draw_circle(c + Vector2(-r * 0.78, -r * 0.92), bell, METAL_COL)
	draw_circle(c + Vector2(r * 0.78, -r * 0.92), bell, METAL_COL)
	# 钟壳（外圈暖金）+ 钟面
	draw_circle(c, r + 3.0, METAL_COL)
	draw_circle(c, r, FACE_COL)
	# 中间饼图：可玩=绿色剩余；冷却=蓝色进度
	var frac := cooldown_frac if cooldown else remaining
	var col := COOLDOWN_COL if cooldown else PLAY_COL
	_draw_pie(c, r * 0.90, frac, col)
	# 钟面描边
	draw_arc(c, r, 0.0, TAU, 40, RIM_COL, 2.0, true)

## 从 12 点方向顺时针画一块占比 frac 的扇形（三角扇多边形）。
func _draw_pie(center: Vector2, radius: float, frac: float, col: Color) -> void:
	if frac <= 0.001:
		return
	var pts := PackedVector2Array()
	pts.append(center)
	var start := -PI * 0.5 # 12 点方向
	var steps := maxi(2, int(frac * 48.0))
	for i in steps + 1:
		var a := start + TAU * frac * (float(i) / float(steps))
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	draw_colored_polygon(pts, col)
