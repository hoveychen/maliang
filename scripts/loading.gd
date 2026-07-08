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

var _fade_root: Control    ## 淡出目标（整层视觉挂它下面，改 modulate:a）
var _fairy: TextureRect
var _dots: Array[ColorRect] = []
var _t := 0.0
var _fairy_base_y := 0.0
var _shown_at := 0
var _world: Node = null
var _revealing := false    ## 已开始揭开（防重复 spawn/reveal）
var _frames := 0           ## 已过帧数（首帧只画遮罩，第二帧起才同步加载世界）

func _ready() -> void:
	_shown_at = Time.get_ticks_msec()
	_build_overlay()
	# 隔一帧再同步加载：先让遮罩画出来，避免加载 main.tscn 的那一帧还是黑屏

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

	# 居中飘动的小仙子（bob + 呼吸，见 _process）——「小仙子正在布置世界」的无字表达
	_fairy = TextureRect.new()
	_fairy.texture = load("res://assets/fairy.png")
	_fairy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fairy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fairy.set_anchors_preset(Control.PRESET_CENTER)
	_fairy.custom_minimum_size = Vector2(260.0, 178.0)
	_fairy.offset_left = -130.0
	_fairy.offset_right = 130.0
	_fairy.offset_top = -140.0
	_fairy.offset_bottom = 38.0
	_fairy.pivot_offset = Vector2(130.0, 89.0)
	_fairy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_root.add_child(_fairy)
	_fairy_base_y = _fairy.offset_top

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

func _process(delta: float) -> void:
	_t += delta
	if _fairy != null:
		_fairy.offset_top = _fairy_base_y + sin(_t * 1.6) * 12.0
		_fairy.offset_bottom = _fairy_base_y + 178.0 + sin(_t * 1.6) * 12.0
		var s := 1.0 + sin(_t * 2.0) * 0.04
		_fairy.scale = Vector2(s, s)
	# 三点顺序脉动（相位错开），alpha 在 0.35~1.0 之间呼吸
	for i in range(_dots.size()):
		var a := 0.35 + 0.65 * (0.5 + 0.5 * sin(_t * 4.0 - i * 0.9))
		_dots[i].modulate.a = a

	if _revealing:
		return
	# 首帧只画遮罩，第二帧起再同步加载（遮罩已上屏，加载卡帧也不黑）
	_frames += 1
	if _frames >= 2:
		_spawn_world()

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
	var tw := create_tween()
	tw.tween_property(_fade_root, "modulate:a", 0.0, FADE_TIME)
	await tw.finished
	queue_free() # 过场移除，世界成为唯一场景
