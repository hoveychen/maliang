extends Node
class_name Loading
## 进入世界的加载过场：菜单/绘本 → 世界之间插的一层。
## 先画出品牌遮罩，隔一帧再同步加载目标场景（把 main.tscn 及其 preload 资产的一次性
## 开销盖在过场下，而非旧路径那样卡在菜单帧上），实例化后把世界挂到 root，用高层
## CanvasLayer(layer=128，压过世界 HUD 的 layer=1) 盖住首屏 chunk 逐帧铺设与网络角色
## 弹入的窗口；等世界发 world_ready（首屏铺完 + 引导结束 / 8s 超时兜底）再淡出交还世界。
## 画风复用主菜单：水彩背景 + 飘动小仙子 + 三点脉动「处理中」。
##
## 不用 ResourceLoader 线程加载：目标场景脚本(chunk_manager)含大量 preload()，在加载
## 子线程上编译会解析失败(Godot 已知的 preload-on-thread 脆弱点，headless 实测 FAILED)；
## 同步 load 各处都稳，重活本就在世界 _ready/chunk 铺设，非磁盘 IO，同步足矣。
##
## next_scene 由上游（menu / onboarding）静态置入；缺省回落 main.tscn。
## 运行/测试: 上游置 Loading.next_scene 后 change_scene_to_file("res://loading.tscn")。

static var next_scene := "res://main.tscn"

const FADE_TIME := 0.45   ## 揭开淡出时长
const MIN_SHOW_MS := 600  ## 最短显示：避免过场一闪而过（世界瞬间就绪时也留个照面）
const DOT_COUNT := 3

const FAIRY_W := 296.0    ## 点点精灵框宽/高（横飞时按框定位；比例贴合图集 cell 296×256）
const FAIRY_H := 256.0
const FLY_MARGIN := 44.0  ## 飞行航道左右留白
# 点点 idle 动画图集（服务端 Seedance 生成、WebP 打包本地供离线用；6×6 网格 31 帧 8fps，cell 296×256）
const FAIRY_SHEET_COLS := 6
const FAIRY_SHEET_FRAMES := 31
const FAIRY_SHEET_FPS := 8.0
const FAIRY_CELL_W := 296
const FAIRY_CELL_H := 256
const PROG_FOLLOW := 2.5  ## 显示进度追真进度的速度（每秒）：真里程碑落地时仙子快速前冲
const PROG_CREEP := 0.035 ## 真进度停滞时的慢爬（每秒），朝 0.9 渐近但永不到顶——到顶只由 world_ready 触发
const CREEP_CEIL := 0.9   ## 慢爬封顶：网络久等时仙子最多爬到 90%，留最后一截给「真就绪」
const LAND_TIME := 0.45   ## world_ready 后仙子冲刺到终点（_prog→1）的时长

const PORTAL_W := 200.0    ## 传送门屏上宽（竖椭圆——门一般是竖着的，非正圆）
const PORTAL_H := 280.0    ## 传送门屏上高
const PORTAL_TEX := 240    ## 传送门贴图分辨率（程序化生成方形，靠 STRETCH_SCALE 拉成椭圆）
const REACT_DUR := 0.7     ## 点击屏幕后小仙子纸片翻转反应时长

var _fade_root: Control    ## 淡出目标（背景+三点挂它下面，改 modulate:a 剥离）
var _portal: TextureRect   ## 航道终点的传送门（挂 CanvasLayer 上、盖过 _fade_root，单独转场）
var _fairy: TextureRect
var _fairy_atlas: AtlasTexture ## 点点动画图集的取帧窗口（每帧移 region 播 idle 动画）
var _trail: Line2D             ## 点点飞过留下的墨迹（＝进度条：她画到哪儿，就是加载到哪儿）
var _trail_base_y := 0.0       ## 墨迹基线 Y（不随点点上下起伏抖动，是稳的一道笔画）
var _fairy_cx := 0.0           ## 点点框心 X（_layout_fairy 每帧写，墨迹终点取它）
var _status_label: Label   ## 调试浮层：当前加载阶段文案+进度百分比（仅 debug 构建，release 不建，见 _build_overlay）
var _dots: Array[ColorRect] = []
var _t := 0.0
var _prog := 0.0           ## 显示进度 [0,1]：驱动仙子横向位置；真进度来自 _world.ready_progress()
var _landing := false      ## world_ready 后接管 _prog（tween 冲到 1.0），_process 不再跟随真进度
var _react_t := 0.0        ## >0 时仙子正做点击反应（欢快转圈+上蹿+放大），给等待的小朋友找事做
var _transitioning := false ## 传送门转场已接管（门的位置/缩放交给 tween，_process 只保留自转）
var _shown_at := 0
var _world: Node = null
var _revealing := false    ## 已开始揭开（防重复 spawn/reveal）
var _frames := 0           ## 已过帧数（首帧只画遮罩，第二帧起才同步加载世界）

func _ready() -> void:
	_shown_at = Time.get_ticks_msec()
	_build_overlay()
	# 隔一帧再同步加载：先让遮罩画出来，避免加载 main.tscn 的那一帧还是黑屏。
	# 注意：这里不做任何画质决议 / 网络查询。曾经在此 await 查 backend 众包档并 gate 住
	# _spawn_world，结果网络一慢世界就永远不 spawn、加载页永远不关（真机实测卡死）。
	# 画质定档改由 menu 后的独立「建造小世界」前置阶段处理（见 world-building-intro plan）。

func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128 # 压过世界 HUD（默认 layer=1）：世界挂进 root 后仍被遮罩盖住
	add_child(layer)

	_fade_root = Control.new()
	_fade_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_root.mouse_filter = Control.MOUSE_FILTER_STOP # 吃掉过场期间的乱点，别漏到世界
	layer.add_child(_fade_root)

	# 水彩草甸村庄背景铺满（与主菜单一脉相承）
	var bg := TextureRect.new()
	bg.texture = UiAssets.tex("bg_menu")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_root.add_child(bg)

	# 点点飞过留下的墨迹＝进度条：一道墨黑笔画，从航道起点画到她当前位置。
	# 在 bg 之后、点点之前入树 → 画在她身后（她像正拖着笔尖画出这条线）。
	# Line2D 挂 Control 下按画布坐标渲染；点点母题就是墨点尾迹，这里把它连成一笔。
	_trail = Line2D.new()
	_trail.width = 12.0
	_trail.default_color = Color(0.16, 0.14, 0.13, 0.92) # 墨黑（微暖，非纯黑）
	_trail.joint_mode = Line2D.LINE_JOINT_ROUND
	_trail.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_trail.end_cap_mode = Line2D.LINE_CAP_ROUND
	# 起笔细、行笔粗（毛笔起收笔），用宽度曲线做出笔锋
	var wcurve := Curve.new()
	wcurve.add_point(Vector2(0.0, 0.35))
	wcurve.add_point(Vector2(0.12, 1.0))
	wcurve.add_point(Vector2(1.0, 0.9))
	_trail.width_curve = wcurve
	_fade_root.add_child(_trail) # Line2D 是 Node2D，本就不吃鼠标，无需 mouse_filter

	# 横飞的小仙子（bob + 呼吸 + 随就绪进度从左飞到右，见 _process）——把等待可视化成
	# 「小仙子布置世界，飞到尽头就绪」，让慢网也有进度感、且揭幕严格等仙子飞到头。
	# 锚到左上角：offset 即绝对像素，_process 每帧按 _prog 摆 X。
	_fairy = TextureRect.new()
	# idle 动画图集：AtlasTexture 每帧移 region 播（见 _update_fairy_frame）；缺失则回落静态立绘
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
	_fairy.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_fairy.custom_minimum_size = Vector2(FAIRY_W, FAIRY_H)
	_fairy.pivot_offset = Vector2(FAIRY_W * 0.5, FAIRY_H * 0.5) # 呼吸缩放绕框心
	_fairy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_root.add_child(_fairy)

	# 三点脉动：不识字也懂的「处理中」信号（奶油白圆点，顺序呼吸）
	var dot_size := 22.0
	var gap := 20.0
	var total := DOT_COUNT * dot_size + (DOT_COUNT - 1) * gap
	for i in range(DOT_COUNT):
		var d := ColorRect.new()
		d.color = Color(1.0, 0.98, 0.92)
		d.custom_minimum_size = Vector2(dot_size, dot_size)
		d.set_anchors_preset(Control.PRESET_CENTER)
		var x := -total * 0.5 + i * (dot_size + gap)
		d.offset_left = x
		d.offset_right = x + dot_size
		d.offset_top = 150.0
		d.offset_bottom = 150.0 + dot_size
		d.pivot_offset = Vector2(dot_size * 0.5, dot_size * 0.5)
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fade_root.add_child(d)
		_dots.append(d)

	# 航道终点的传送门：挂在 CanvasLayer 上、盖过 _fade_root（故仙子飞近时被门遮住＝飞入感）。
	# 转场时单独动它（居中+放大+淡出），不随背景 _fade_root 一起淡。程序化生成，无素材依赖。
	_portal = TextureRect.new()
	_portal.texture = _make_portal_tex(PORTAL_TEX)
	_portal.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portal.stretch_mode = TextureRect.STRETCH_SCALE # 方形辉光拉成竖椭圆
	_portal.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_portal.custom_minimum_size = Vector2(PORTAL_W, PORTAL_H)
	_portal.pivot_offset = Vector2(PORTAL_W * 0.5, PORTAL_H * 0.5) # 自转/缩放绕门心
	_portal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_portal)

	# 调试状态浮层（仅 debug 构建，与世界里的 FPS/坐标调试信息同门控 OS.is_debug_build()）：
	# 左上角小字显示当前在加载什么资源+进度百分比，方便知道慢在哪。release 构建不建，纯三点画风。
	if OS.is_debug_build():
		_status_label = Label.new()
		_status_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_status_label.offset_left = 16.0
		_status_label.offset_top = 12.0
		_status_label.add_theme_font_size_override("font_size", 20)
		_status_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.85))
		_status_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
		_status_label.add_theme_constant_override("outline_size", 4)
		_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_status_label.text = "启动中…"
		_fade_root.add_child(_status_label) # 挂 _fade_root：随过场一起淡出

## 程序化生成发光漩涡传送门：紧亮的高斯环带（r≈0.80）+ 门心径向辉光填充 + 角向螺旋
## （自转即漩涡流动）。门心留半透发光（青→白），既能透出飞入的仙子，放大时又用魔法光
## 水满屏撑起 zoom 吞屏。颜色内→外：近白青→青→紫。返回 ImageTexture，无外部素材依赖。
func _make_portal_tex(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	var hot := Color(0.85, 0.99, 1.0)  # 门心近白青
	var mid := Color(0.40, 0.82, 1.0)  # 青
	var rim := Color(0.60, 0.42, 1.0)  # 紫环缘
	for y in size:
		for x in size:
			var dx := (float(x) - c) / c
			var dy := (float(y) - c) / c
			var r := sqrt(dx * dx + dy * dy)
			if r > 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var ang := atan2(dy, dx)
			var ring := exp(-pow((r - 0.80) / 0.13, 2.0))         # 紧亮环带
			var swirl := 0.85 + 0.15 * sin(ang * 3.0 + r * 8.0)   # 轻柔螺旋（门静止，弱化免成风车）
			var glow := pow(1.0 - r, 1.6)                          # 门心辉光填充
			var a := clampf(ring * (0.85 + 0.15 * swirl) + glow * 0.55 * swirl, 0.0, 1.0)
			var col: Color
			if r < 0.55:
				col = hot.lerp(mid, r / 0.55)
			else:
				col = mid.lerp(rim, (r - 0.55) / 0.45)
			col = col * (0.9 + 0.5 * ring) # 环处提亮
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	return ImageTexture.create_from_image(img)

func _process(delta: float) -> void:
	_t += delta
	if _react_t > 0.0:
		_react_t = maxf(0.0, _react_t - delta)
	_update_fairy_frame()
	_advance_progress(delta)
	if not _transitioning: # 转场后仙子交给吸入 tween，别再被逐帧布局覆盖 scale/位置
		_layout_fairy()
		_layout_trail()
	_layout_portal()
	# 三点顺序脉动（相位错开），alpha 在 0.35~1.0 之间呼吸
	for i in range(_dots.size()):
		var a := 0.35 + 0.65 * (0.5 + 0.5 * sin(_t * 4.0 - i * 0.9))
		_dots[i].modulate.a = a
	_update_status_label()

	if _revealing:
		return
	# 首帧只画遮罩，第二帧起再同步加载（遮罩已上屏，加载卡帧也不黑）。零阻塞：不再等任何
	# 网络决议——加载页唯一的职责就是把世界加载出来。
	_frames += 1
	if _frames >= 2:
		_spawn_world()

## 推进显示进度：真进度领先就快速追上（里程碑落地→仙子前冲）；真进度停滞则慢爬向
## CREEP_CEIL 渐近但不到顶。_landing 后由 tween 独占 _prog（冲刺到终点），这里让路。
func _advance_progress(delta: float) -> void:
	if _landing:
		return
	var real := 0.0
	if _world != null and _world.has_method("ready_progress"):
		real = _world.ready_progress()
	if real > _prog:
		_prog = move_toward(_prog, real, PROG_FOLLOW * delta)
	else:
		_prog = move_toward(_prog, CREEP_CEIL, PROG_CREEP * delta)

## 刷新调试状态浮层（仅 debug 构建存在）：显示世界当前引导阶段文案 + 显示进度百分比。
func _update_status_label() -> void:
	if _status_label == null:
		return
	var stage := "启动中…"
	if _world != null and _world.has_method("ready_status"):
		stage = String(_world.call("ready_status"))
	_status_label.text = "%s   %d%%" % [stage, int(clampf(_prog, 0.0, 1.0) * 100.0)]

## 按 _prog 把仙子从左飞到右：分层上下起伏（大摆+小颤）+ 随起伏轻微倾角，飞得更活泼；
## 叠加点击反应（转圈+上蹿+放大）。锚在左上角，offset 即绝对像素，绕框心旋转/缩放。
func _layout_fairy() -> void:
	if _fairy == null or _fade_root == null:
		return
	var vp := _fade_root.size
	var travel := maxf(vp.x - FAIRY_W - 2.0 * FLY_MARGIN, 0.0)
	# 缓入映射（pow>1）：等待/慢爬期仙子停在航道中段而非一冲就挤到门前，只有真就绪（_prog→1）才抵达门口。
	# 端点不变（eased(0)=0, eased(1)=1），_finish_center 的落点一致。
	var eased := pow(clampf(_prog, 0.0, 1.0), 1.6)
	# 持续横向漂移：即便 _prog 停滞，仙子也一直左右飘（配合上下起伏＝四处飞着布置世界），永不定住；
	# 随接近门口(eased→1)渐隐，保证落点精准。这是「让仙子一直在动」的关键。
	var flit := sin(_t * 1.3) * 16.0 * (1.0 - eased)
	var x := FLY_MARGIN + travel * eased + flit
	var bob := sin(_t * 2.1) * 26.0 + sin(_t * 4.7) * 7.0 # 大摆叠小颤，忽上忽下
	var tilt := sin(_t * 2.1) * 0.10                       # 随起伏轻微摆头
	var s := 1.0 + sin(_t * 2.6) * 0.05
	var flip := 1.0
	if _react_t > 0.0: # 点击反应：纸片翻转一圈（scale.x 过 0＝立起来翻面）+ 轻微上蹿
		var prog := 1.0 - _react_t / REACT_DUR # 0→1
		flip = cos(prog * TAU)                 # 1→-1→1，一次纸片翻转
		bob -= sin(prog * PI) * 20.0
		s += sin(prog * PI) * 0.10
	var base_y := vp.y * 0.40
	_fairy.offset_left = x
	_fairy.offset_right = x + FAIRY_W
	_fairy.offset_top = base_y + bob
	_fairy.offset_bottom = base_y + FAIRY_H + bob
	_fairy.rotation = tilt
	_fairy.scale = Vector2(s * flip, s) # x 方向翻转做纸片翻面
	_fairy_cx = x + FAIRY_W * 0.5           # 墨迹画到她身下的笔尖处（框心 x）
	_trail_base_y = base_y + FAIRY_H * 0.58 # 稳的一道基线：取她身体中下部，不随 bob 抖

## 墨迹进度条：从航道起点画到点点当前位置的一道手绘墨笔。沿途小幅正弦抖动＝手绘感，
## 每 ~26px 采一个点。点点飞到哪，墨就画到哪——加载进度天然可视化成「她画出的一条线」。
func _layout_trail() -> void:
	if _trail == null or _fade_root == null:
		return
	var start_x := FLY_MARGIN + 12.0
	var end_x := maxf(_fairy_cx - FAIRY_W * 0.18, start_x) # 收到她框心稍靠后，像墨从笔尖淌出
	var pts := PackedVector2Array()
	var seg := 26.0
	var x := start_x
	while x < end_x:
		# 沿途手绘抖动：低频波（整体起伏）+ 固定相位（画好的部分不再动，像干了的墨）
		var wob := sin(x * 0.03) * 5.0 + sin(x * 0.11) * 2.0
		pts.append(Vector2(x, _trail_base_y + wob))
		x += seg
	pts.append(Vector2(end_x, _trail_base_y + sin(end_x * 0.03) * 5.0 + sin(end_x * 0.11) * 2.0))
	_trail.points = pts

## 播 idle 动画：按 _t 与 fps 取当前帧，移动 AtlasTexture 的 region 到对应网格格子。
func _update_fairy_frame() -> void:
	if _fairy_atlas == null:
		return
	var f := int(_t * FAIRY_SHEET_FPS) % FAIRY_SHEET_FRAMES
	var col := f % FAIRY_SHEET_COLS
	@warning_ignore("integer_division")
	var row := f / FAIRY_SHEET_COLS
	_fairy_atlas.region = Rect2(col * FAIRY_CELL_W, row * FAIRY_CELL_H, FAIRY_CELL_W, FAIRY_CELL_H)

## 仙子飞行终点＝门心（_prog=1 时仙子框中心），转场里仙子被吸入此处。
func _finish_center() -> Vector2:
	var vp := _fade_root.size
	return Vector2(vp.x - FLY_MARGIN - FAIRY_W * 0.5, vp.y * 0.40 + FAIRY_H * 0.5)

## 传送门定位：静止的竖椭圆门（像 Portal——门本身不转不动），钉在航道终点；
## 转场开始后位置/缩放交给 tween。
func _layout_portal() -> void:
	if _portal == null or _transitioning or _fade_root == null:
		return
	var pc := _finish_center()
	_portal.offset_left = pc.x - PORTAL_W * 0.5
	_portal.offset_top = pc.y - PORTAL_H * 0.5
	_portal.offset_right = pc.x + PORTAL_W * 0.5
	_portal.offset_bottom = pc.y + PORTAL_H * 0.5

## 加载等待时点屏幕：小仙子做个欢快反应（_layout_fairy 里的转圈+上蹿），点处冒颗小星星——
## 让等待的小朋友有事可干。转场开始后不再响应（别打断穿越）。
func _input(event: InputEvent) -> void:
	if _transitioning or _fairy == null:
		return
	var pos := Vector2.INF
	if event is InputEventScreenTouch and event.pressed:
		pos = event.position
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
	if pos != Vector2.INF:
		_react_t = REACT_DUR
		_spawn_tap_star(pos)

## 点击处冒一颗小星星：放大弹出 + 上浮淡出后自销。
func _spawn_tap_star(pos: Vector2) -> void:
	if _fade_root == null:
		return
	var sz := 64.0
	var star := TextureRect.new()
	star.texture = UiAssets.tex("st_star")
	star.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	star.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	star.set_anchors_preset(Control.PRESET_TOP_LEFT)
	star.custom_minimum_size = Vector2(sz, sz)
	star.pivot_offset = Vector2(sz * 0.5, sz * 0.5)
	star.mouse_filter = Control.MOUSE_FILTER_IGNORE
	star.offset_left = pos.x - sz * 0.5
	star.offset_right = pos.x + sz * 0.5
	star.offset_top = pos.y - sz * 0.5
	star.offset_bottom = pos.y + sz * 0.5
	star.scale = Vector2(0.3, 0.3)
	_fade_root.add_child(star)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(star, "scale", Vector2(1.2, 1.2), 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(star, "offset_top", pos.y - sz * 0.5 - 42.0, 0.5)
	tw.tween_property(star, "offset_bottom", pos.y + sz * 0.5 - 42.0, 0.5)
	tw.tween_property(star, "modulate:a", 0.0, 0.5).set_delay(0.12)
	tw.chain().tween_callback(star.queue_free)

func _spawn_world() -> void:
	_revealing = true # 只此一次，之后只等 world_ready
	var packed := load(next_scene) as PackedScene
	if packed == null:
		push_warning("loading: 加载失败，回落硬切 %s" % next_scene)
		set_process(false)
		get_tree().change_scene_to_file(next_scene)
		return
	_world = packed.instantiate()
	# 世界挂到 root 并接管 current_scene：其 _ready 立即跑（建 HUD/环境，开始铺 chunk +
	# 在线引导）。过场自身仍是 root 的子节点、CanvasLayer(128) 盖在世界之上，直到揭开才移除。
	get_tree().root.add_child(_world)
	get_tree().current_scene = _world
	if _world.has_signal("world_ready"):
		_world.connect("world_ready", _on_world_ready, CONNECT_ONE_SHOT)
	else:
		_on_world_ready() # 目标场景没有就绪信号（保险）：直接揭开

func _on_world_ready() -> void:
	# 补齐最短显示时长，避免世界秒就绪时过场一闪而过
	var elapsed := Time.get_ticks_msec() - _shown_at
	if elapsed < MIN_SHOW_MS:
		await get_tree().create_timer((MIN_SHOW_MS - elapsed) / 1000.0).timeout

	# ① 仙子冲刺飞到航道终点（＝门心）。_landing 接管 _prog，_advance_progress 让路。
	_landing = true
	var land := create_tween()
	land.tween_property(self, "_prog", 1.0, LAND_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await land.finished

	# ② 仙子被吸入门：缩到门心并淡出。_transitioning 接管门（位置/缩放交给 tween）。
	_transitioning = true
	var suck := create_tween().set_parallel(true)
	suck.tween_property(_fairy, "scale", Vector2(0.05, 0.05), 0.26).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	suck.tween_property(_fairy, "modulate:a", 0.0, 0.26)
	await suck.finished

	# ③a 门先滑到屏幕中心（尺寸略微放大预备），此时还不吞屏——先居中、后放大，层次分明。
	var vp := _fade_root.size
	var ctr := vp * 0.5
	var recenter := create_tween().set_parallel(true)
	recenter.tween_property(_portal, "offset_left", ctr.x - PORTAL_W * 0.5, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	recenter.tween_property(_portal, "offset_top", ctr.y - PORTAL_H * 0.5, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	recenter.tween_property(_portal, "offset_right", ctr.x + PORTAL_W * 0.5, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	recenter.tween_property(_portal, "offset_bottom", ctr.y + PORTAL_H * 0.5, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	recenter.tween_property(_portal, "scale", Vector2(1.35, 1.35), 0.45).set_trans(Tween.TRANS_SINE)
	await recenter.finished

	# ③b 再 zoom in 放大吞屏，同时背景（水彩+三点）剥离淡出——门后的游戏世界随之透出。
	var zoom_max := maxf(vp.x / PORTAL_W, vp.y / PORTAL_H) * 2.6 # 保证放大后铺满屏幕
	var zoom := create_tween().set_parallel(true)
	zoom.tween_property(_portal, "scale", Vector2(zoom_max, zoom_max), 0.6).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	zoom.tween_property(_fade_root, "modulate:a", 0.0, 0.45)
	await zoom.finished

	# ④ 门 fade out → 游戏世界完全淡入（整层过场移除）。
	var out := create_tween()
	out.tween_property(_portal, "modulate:a", 0.0, 0.3)
	await out.finished
	queue_free() # 过场移除，世界成为唯一场景
