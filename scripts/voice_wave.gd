class_name VoiceWave
extends Control
## 收听声波：一排珊瑚色柱子随 VAD 电平跳动的「我在听你说话」提示。
## world（近身对话 HUD）与 onboarding（起名麦克风页）此前各手抄一套——一套九条流动波嵌
## HUD 边框、一套五条山包独立——数据源同是 VoiceCapture.level()，画法却各写各的。本控件把
## 「电平 → 每条柱高 → 平滑」这层收敛成一处，统一成流动波观感（老板 2026-07-15 定）。
##
## 只负责「一排柱子 + 动画」；不含 HUD 边框贴图、不管整体缩放/落位——那些是宿主外层的事
## （world 把本控件塞进带 hud_listen 边框的 Control 里再整体缩放；onboarding 直接摆进页面）。
##
## 用法（构造后、加进树前设外观与注入）：
##   var w := VoiceWave.new()
##   w.level_source = func() -> float: return _vc.level()  # 每帧读的归一化响度
##   add_child(w)
##   # 宿主每帧设「此刻在不在听」；false 时柱子平滑落回静息、波停住
##   w.active = <此刻在不在听>
##
## 柱子锚在控件底边中心、只向上长（像声波从基线往上窜）。active 时叠一层相位错开的正弦
## → 一条左右流动的波，静息也留 idle_floor 让它一直轻轻滚（孩子看出「一直在听」）。
## 宿主隐藏本控件（或其父）时动画自动停（_process 查 is_visible_in_tree），不空转。

const _PHASE_SPEED := 7.0   ## 正弦相位推进速度（rad/s）：越大波流动越快
const _PHASE_STEP := 0.8    ## 相邻柱相位差（rad）：错开成一条流动的波，不是齐刷刷同高
const _SHAPE_FLOOR := 0.4   ## 单柱正弦的谷底占比：波谷不塌到 0，留住一排的整体轮廓
const _SMOOTH := 12.0       ## 柱高趋近目标的速度（越大越跟手）

## ── 宿主可调外观（构造后、加进树前设）───────────────────────────────────
var bar_count := 9                      ## 柱数
var bar_width := 12.0                    ## 单柱宽（像素）
var bar_gap := 8.0                       ## 柱间距（像素）
var bar_min_h := 8.0                     ## 静息柱高（像素）
var bar_max_h := 40.0                    ## 满音量柱高（像素）
var bar_color := Color(0.96, 0.5, 0.36)  ## 珊瑚色：与 world HUD 边框描边同调
var idle_floor := 0.25                   ## active 时的静息底幅：>0 让波一直轻轻滚
var gain := 1.0                          ## 电平灵敏度：level*gain 再 clamp 到 0..1

## ── 宿主注入 ─────────────────────────────────────────────────────────────
var level_source: Callable = func() -> float: return 0.0  ## 每帧读的归一化响度（0..1）
var active := true                       ## 此刻在不在听；false → 柱子平滑落回静息、不滚动

var _bars: Array[ColorRect] = []
var _t := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_bars()

func _build_bars() -> void:
	for i in bar_count:
		var bar := ColorRect.new()
		bar.color = bar_color
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 柱底钉在控件底边中心（anchor 底=1.0、水平中=0.5），只向上长
		bar.anchor_left = 0.5
		bar.anchor_right = 0.5
		bar.anchor_top = 1.0
		bar.anchor_bottom = 1.0
		var xoff := (float(i) - float(bar_count - 1) * 0.5) * (bar_width + bar_gap)
		bar.offset_left = xoff - bar_width * 0.5
		bar.offset_right = xoff + bar_width * 0.5
		bar.offset_bottom = 0.0
		bar.offset_top = -bar_min_h
		add_child(bar)
		_bars.append(bar)

func _process(delta: float) -> void:
	if _bars.is_empty() or not is_visible_in_tree():
		return
	if active:
		_t += delta
		var lvl := clampf(float(level_source.call()) * gain, 0.0, 1.0)
		# 整体幅度随音量抬升；idle_floor 兜底让静息也一直轻轻滚（world 原口径 0.25+lvl*0.75）。
		var base := idle_floor + lvl * (1.0 - idle_floor)
		for i in _bars.size():
			# 每根柱相位错开 → 一条左右流动的声波，音量越大越高越满。
			var shape := 0.5 + 0.5 * sin(_t * _PHASE_SPEED + float(i) * _PHASE_STEP)
			var amp := base * (_SHAPE_FLOOR + (1.0 - _SHAPE_FLOOR) * shape)
			_ease_bar(_bars[i], bar_min_h + amp * (bar_max_h - bar_min_h), delta)
	else:
		# 不在听：柱子平滑落回静息，相位不推进（波停住）。
		for bar in _bars:
			_ease_bar(bar, bar_min_h, delta)

func _ease_bar(bar: ColorRect, target: float, delta: float) -> void:
	var cur := -bar.offset_top
	bar.offset_top = -lerpf(cur, target, clampf(delta * _SMOOTH, 0.0, 1.0))

## 当前每条柱高（像素，从基线向上）。供宿主/测试读。
func bar_heights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for bar in _bars:
		out.append(-bar.offset_top)
	return out
