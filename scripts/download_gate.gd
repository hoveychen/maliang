extends Node
class_name DownloadGate
## 世界内容包全量预下载门 UI（world-full-predownload-gate P3，设计见 §handoff）。
##
## intro 结束（或返回用户进世界）后，若该世界要用的内容包还没全挂上（首启弱网），由 world
## 起本页挡在已揭幕的世界之上，下完才放行——「专属、有真进度」的下载页，非模糊 loading 慢爬。
## 已缓存（二次启动 _mount_cached 已挂）→ 预下载秒完 → 本页在 GRACE 前就收到 finished，从不现身
## （「第二次启动不出页」）。
##
## 童话书风 + 点点陪伴：复用主菜单水彩背景 + 点点 idle 图集（res://assets/fairy_idle.webp），
## 「正在准备你的小世界…」+ 真进度条（已下 X/共 N 包 · A.A/B.B MB，字节来自服务端清单）。
## 弱网一轮没下齐 → 温和提示「要联网才能准备好哦~」+ 隔 RETRY_DELAY 自动重试（零挫败：不吓孩子、
## 不报错、下不完也不惩罚，能下多少算多少，联网后继续）。全程吃掉点击（mouse_filter STOP）挡住世界。
##
## 用法：world 起一个实例 add_child，调 begin(predownload, retry_cb)；等 done 信号后 free。

signal done ## 全部内容包挂上、本页淡出后触发；world 据此放行（还玩家控制权）。

const FAIRY_CELL_W := 296
const FAIRY_CELL_H := 256
const FAIRY_SHEET_COLS := 6
const FAIRY_SHEET_FRAMES := 31
const FAIRY_SHEET_FPS := 8.0
const FAIRY_W := 220.0
const FAIRY_H := 190.0
const BAR_W := 420.0        ## 进度条轨道宽
const BAR_H := 26.0
const RETRY_DELAY := 2.5    ## 一轮没下齐后，隔多久自动重试（秒）
const GRACE_BEFORE_SHOW := 0.4 ## 现身宽限：这段内下完（缓存命中/秒下）就永不现身，避免闪一下
const FADE_IN := 0.35
const FADE_OUT := 0.4
const PROG_FOLLOW := 3.0    ## 显示进度追真进度的速度（每秒），让条平滑推进而非跳变

var _root: Control = null
var _veil: ColorRect = null
var _fairy: TextureRect = null
var _fairy_atlas: AtlasTexture = null
var _title: Label = null
var _bar_fill: Panel = null
var _info: Label = null
var _hint: Label = null

var _pd: WorldPredownload = null
var _retry: Callable = Callable()
var _t := 0.0            ## 动画时钟
var _elapsed := 0.0      ## 起页至今（宽限判定）
var _target_frac := 0.0  ## 真进度分数 [0,1]
var _shown_frac := 0.0   ## 平滑显示分数
var _visible := false    ## 已过宽限、开始淡入
var _finishing := false  ## 已进入收尾（防重入）
var _last_line := ""     ## 当前信息行（避免每帧重设 Label）
const FAIRY_DY := -188.0  ## 点点相对画面中心的竖直基线（bob 在此上下浮；留出与标题的间距）

func _ready() -> void:
	_build()

func _build() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 130 # 压过世界 HUD（layer=1）与 loading（128）
	add_child(layer)

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP # 吃掉点击，挡住底下已揭幕的世界
	_root.modulate.a = 0.0 # 宽限期隐身；_process 过宽限后淡入
	layer.add_child(_root)

	# 水彩草甸背景（与主菜单/loading 一脉相承的童话书风）
	var bg := TextureRect.new()
	bg.texture = UiAssets.tex("bg_menu")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)

	# 暖色柔纱：压低背景对比、聚焦中央的点点与进度（奶油暖调，不压成黑幕——零挫败不吓孩子）
	_veil = ColorRect.new()
	_veil.color = Color(0.99, 0.94, 0.82, 0.34)
	_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_veil)

	# 居中列：点点 → 标题 → 进度条 → 信息 → （弱网）提示。锚到画面中心，按偏移堆叠。
	# 点点（idle 图集逐帧播；缺失回落静态立绘）
	_fairy = TextureRect.new()
	var sheet := load("res://assets/fairy_idle.webp") as Texture2D
	if sheet != null:
		_fairy_atlas = AtlasTexture.new()
		_fairy_atlas.atlas = sheet
		_fairy_atlas.region = Rect2(0, 0, FAIRY_CELL_W, FAIRY_CELL_H)
		_fairy.texture = _fairy_atlas
	else:
		_fairy.texture = load("res://assets/fairy.png")
	_fairy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fairy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fairy.set_anchors_preset(Control.PRESET_CENTER)
	_fairy.custom_minimum_size = Vector2(FAIRY_W, FAIRY_H)
	_fairy.pivot_offset = Vector2(FAIRY_W * 0.5, FAIRY_H * 0.5)
	_fairy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place_center(_fairy, Vector2(FAIRY_W, FAIRY_H), FAIRY_DY)
	_root.add_child(_fairy)

	_title = _make_label("正在准备你的小世界…", 40, Color(0.36, 0.24, 0.14))
	_place_center(_title, Vector2(640.0, 56.0), 24.0)
	_root.add_child(_title)

	# 进度条轨道（圆角奶白）+ 填充（暖金），填充宽度每帧按分数设。
	var track := Panel.new()
	track.add_theme_stylebox_override("panel", _rounded(Color(1.0, 0.97, 0.90, 0.9), BAR_H * 0.5))
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place_center(track, Vector2(BAR_W, BAR_H), 96.0)
	_root.add_child(track)
	_bar_fill = Panel.new()
	_bar_fill.add_theme_stylebox_override("panel", _rounded(Color(0.98, 0.74, 0.32), BAR_H * 0.5))
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_fill.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_bar_fill.offset_left = 0.0
	_bar_fill.offset_top = 0.0
	_bar_fill.offset_bottom = BAR_H
	_bar_fill.offset_right = 0.0
	track.add_child(_bar_fill)

	_info = _make_label("", 24, Color(0.42, 0.30, 0.18))
	_place_center(_info, Vector2(640.0, 40.0), 140.0)
	_root.add_child(_info)

	_hint = _make_label("要联网才能准备好哦~", 26, Color(0.85, 0.45, 0.20))
	_place_center(_hint, Vector2(640.0, 44.0), 190.0)
	_hint.modulate.a = 0.0 # 平时藏起，弱网一轮没下齐才现身
	_root.add_child(_hint)

## 居中定位：锚到画面中心，按 size 与竖直偏移 dy 摆放（水平居中）。
func _place_center(c: Control, size: Vector2, dy: float) -> void:
	c.set_anchors_preset(Control.PRESET_CENTER)
	c.offset_left = -size.x * 0.5
	c.offset_right = size.x * 0.5
	c.offset_top = dy
	c.offset_bottom = dy + size.y

func _make_label(text: String, fsize: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(1.0, 1.0, 1.0, 0.85))
	l.add_theme_constant_override("outline_size", 5)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _rounded(col: Color, radius: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(int(radius))
	return sb

## 开始 gating。predownload：WorldPredownload 实例（监听其进度/结束）；retry_cb：调它跑/重试一轮
## 下载（world 提供，内部 _predownload.run 自守并发）。已 all_mounted → 立即收尾（不现身）。
func begin(predownload: WorldPredownload, retry_cb: Callable) -> void:
	_pd = predownload
	_retry = retry_cb
	if _pd == null:
		_finish()
		return
	_pd.progress_changed.connect(_on_progress)
	_pd.finished.connect(_on_round)
	_on_progress(_pd.done_packs, _pd.total_packs, _pd.done_bytes, _pd.total_bytes)
	if _pd.all_mounted:
		_finish()
		return
	if _retry.is_valid():
		_retry.call() # 确保有一轮下载在跑（intro 路径可能已起；run 自守，重复安全）

func _on_progress(dp: int, tp: int, db: int, tb: int) -> void:
	if tp <= 0:
		_target_frac = 1.0
	elif tb > 0:
		_target_frac = clampf(float(db) / float(tb), 0.0, 1.0)
	else:
		_target_frac = clampf(float(dp) / float(tp), 0.0, 1.0)
	if _info != null:
		var line := "已准备 %d/%d 个 · %s / %s MB" % [dp, tp, WorldPredownload.fmt_mb(db), WorldPredownload.fmt_mb(tb)]
		if line != _last_line:
			_last_line = line
			_info.text = line

func _on_round(all_ok: bool) -> void:
	if all_ok:
		_finish()
		return
	# 弱网一轮没下齐：温和提示 + 隔 RETRY_DELAY 自动重试（零挫败，不报错不惩罚）。
	if _hint != null:
		_hint.modulate.a = 1.0
	await get_tree().create_timer(RETRY_DELAY).timeout
	if _finishing or _pd == null:
		return
	if _pd.all_mounted: # 等待期间别处补齐了
		_finish()
		return
	if _retry.is_valid():
		_retry.call()

func _finish() -> void:
	if _finishing:
		return
	_finishing = true
	if not _visible or _root == null:
		# 还没现身（缓存命中/秒下完 → 宽限期内就下完）：直接收工，从不闪现。
		done.emit()
		queue_free()
		return
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, FADE_OUT)
	tw.tween_callback(func():
		done.emit()
		queue_free()
	)

func _process(delta: float) -> void:
	_t += delta
	_elapsed += delta
	if _finishing:
		return
	# 宽限后淡入（宽限内下完则 _finish 先跑、永不现身）
	if not _visible and _elapsed >= GRACE_BEFORE_SHOW and _root != null:
		_visible = true
		var tw := create_tween()
		tw.tween_property(_root, "modulate:a", 1.0, FADE_IN)
	# 点点 idle 逐帧
	if _fairy_atlas != null:
		var f := int(_t * FAIRY_SHEET_FPS) % FAIRY_SHEET_FRAMES
		_fairy_atlas.region = Rect2((f % FAIRY_SHEET_COLS) * FAIRY_CELL_W, (f / FAIRY_SHEET_COLS) * FAIRY_CELL_H, FAIRY_CELL_W, FAIRY_CELL_H)
	# 点点轻微上下浮（驱动 offset，不碰 position——本控件靠锚点+offset 定位）+ 呼吸缩放
	if _fairy != null:
		var bob := sin(_t * 1.8) * 8.0
		_fairy.offset_top = FAIRY_DY + bob
		_fairy.offset_bottom = FAIRY_DY + FAIRY_H + bob
		var s := 1.0 + sin(_t * 2.4) * 0.02
		_fairy.scale = Vector2(s, s)
	# 进度条平滑追真进度
	_shown_frac = move_toward(_shown_frac, _target_frac, PROG_FOLLOW * delta)
	if _bar_fill != null:
		_bar_fill.offset_right = BAR_W * _shown_frac
