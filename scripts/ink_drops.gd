class_name InkDrops
extends Control
## 集邮册跨页上的一层「墨滴」覆盖层：三章攒满时，墨从盖章卡上浮起来凝成三滴金墨，
## 划一道弧**越过对折中缝**，落进花田左页的空土坑里——那道中缝是这台手机真实的物理折痕，
## 让墨滴跨过去，「种出来」的因果就长在手机的形态上了（design §4.2）。
##
## 覆盖在花田/章卡之上（鼠标穿透），只在开花那 0.45s 里有东西可画。
## 进度由 PhoneUi 的 Tween 喂 set_progress(0→1)。

const DROPS := 3
const STAGGER := 0.10        ## 三滴之间的出发间隔（进度值，不是秒）
const ARC_LIFT := 0.42       ## 弧顶抬多高（相对两点距离）
const CORE := Color(1.0, 0.91, 0.65)
const EDGE := Color(0.91, 0.64, 0.24)

var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _p := 0.0                ## 0=还没出发，1=全落地
var _live := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## 摆好起飞/落地点（本控件坐标系）。
func launch(from: Vector2, to: Vector2) -> void:
	_from = from
	_to = to
	_p = 0.0
	_live = true
	queue_redraw()

func set_progress(v: float) -> void:
	_p = v
	queue_redraw()

func stop() -> void:
	_live = false
	queue_redraw()

func _draw() -> void:
	if not _live:
		return
	var d := _to - _from
	# 弧顶：两点连线中点再往上抬——墨滴是"飞"过去的，不是滑过去的
	var ctrl := _from + d * 0.5 - Vector2(0.0, d.length() * ARC_LIFT)
	for i in DROPS:
		var t := clampf((_p - float(i) * STAGGER) / (1.0 - float(DROPS - 1) * STAGGER), 0.0, 1.0)
		if t <= 0.0 or t >= 1.0:
			continue
		var pos := _bezier(_from, ctrl, _to, t)
		# 跨页视口是 960px 宽、贴到 3D 手机上只占屏幕 ~550px：墨滴画小了就是几个像素点，
		# 一闪而过根本看不见。要够大够亮，才撑得起"墨真的飞过去了"这句话。
		var r := lerpf(18.0, 10.0, t)        # 越接近土坑越小（要渗进去了）
		# 拖尾：沿轨迹回溯几步，越远越淡
		for k in range(1, 5):
			var tt := maxf(0.0, t - float(k) * 0.035)
			var p2 := _bezier(_from, ctrl, _to, tt)
			draw_circle(p2, r * (1.0 - 0.16 * float(k)), Color(EDGE, 0.30 - 0.06 * float(k)))
		draw_circle(pos, r * 1.7, Color(EDGE, 0.28))   # 外晕
		draw_circle(pos, r, EDGE)
		draw_circle(pos - Vector2(r * 0.3, r * 0.3), r * 0.45, CORE)  # 高光

func _bezier(a: Vector2, b: Vector2, c: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return a * (u * u) + b * (2.0 * u * t) + c * (t * t)
