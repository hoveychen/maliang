class_name Benchmark
extends Node
## 新机器画质定档：在受控负载下测出「这台机器能跑稳 30fps 的最高画质档」。
##
## 为什么复用 world 而不是另搭一个场景：要测的就是孩子真正会看到的那条渲染路径——地形、
## 水面、散布植被、SDF 物件（描边 + 顶点吸附）、纸片角色（立绘 + 实时阴影 + X 光剪影）、
## 天空、雾。另起炉灶必然要复制一份太阳灯/环境参数，两处定义早晚漂移，测出来的档也就不作数。
## world.benchmark_mode 只短路掉「跟渲染无关」的部分：后端、麦克风、引导。
##
## 负载可复现（换档前后的帧时必须可比，否则贪心是在比噪声）：
##   - 额外塞 EXTRA_CHARS 个角色，环绕玩家站定，全在相机视野里
##   - 这些角色不 wander、不参与占用图；玩家不动 → 相机不动 → 每帧画面一模一样
##
## 测量：每档 warmup 后采 p95 帧时（见 FrameSampler）。达标线 = GraphicsSettings.TARGET_FRAME_MS。
## 贪心求解在 _advance()（见该函数注释）。

signal finished(levels: Dictionary, p95_ms: float)

## 「下次进 world 要定档」：world._ready 见到它就挂 Benchmark 并短路掉后端/麦克风/引导。
## 由新机器首启、或设置页「重新检测画质」置位；Benchmark 一 _ready 就消费掉它。
static var pending := false

const EXTRA_CHARS := 12  ## 环绕玩家的额外角色数：压满角色渲染这条最贵的路径

var _world: Node3D
var _levels: Dictionary          ## 当前正在测的档
var _sampler: FrameSampler
var _baseline_ms := 0.0          ## 全最高档的 p95（报告用）
var _done := false

static func make(world: Node3D) -> Benchmark:
	var b := Benchmark.new()
	b.name = "Benchmark"
	b._world = world
	return b

func _ready() -> void:
	pending = false  # 消费掉标志：定档跑一次就够，别让下次进世界又跑
	Engine.max_fps = 0  # 测真实帧时：menu 的 30fps cap 会把帧时钳在 33ms，测不出余量
	_spawn_load()
	_levels = GraphicsSettings.all_max()  # 从全最高档起步，能不降就不降
	_start_measure(_levels)

## 环绕玩家站一圈角色。不注册占用图、不给行为脚本——它们只是渲染负载，不该参与游戏逻辑。
func _spawn_load() -> void:
	var focus: Vector2 = _world.get("focus_logical")
	var tex: Texture2D = _world.get("critter_tex")
	var npcs: Array = _world.get("npcs")
	for i in EXTRA_CHARS:
		var ang := TAU * float(i) / float(EXTRA_CHARS)
		var radius := 4.0 + 2.0 * float(i % 3)  # 三圈同心，拉开深度，别互相完全遮挡
		var lg := WorldGrid.wrap_pos(focus + Vector2(cos(ang), sin(ang)) * radius)
		var npc := PaperCharacter.new()
		_world.add_child(npc)
		npc.setup(tex, Color(0.6 + 0.3 * float(i % 2), 0.75, 1.0 - 0.3 * float(i % 3)), "bench_%d" % i)
		npcs.append({ "node": npc, "logical": lg, "id": "bench_%d" % i })

## 应用一组档并开始采样。
func _start_measure(levels: Dictionary) -> void:
	for key: String in GraphicsSettings.KEYS:
		_world.call("_apply_graphics_key", key, int(levels[key]))
	_sampler = FrameSampler.new()

func _process(delta: float) -> void:
	if _done or _sampler == null:
		return
	_sampler.feed(delta)
	if _sampler.is_done():
		_advance(_sampler.p95_ms())

## 一档测完 → 决定下一步。P4 只测基线；贪心搜索在 P5 接进来。
func _advance(p95: float) -> void:
	_baseline_ms = p95
	_finish(p95)

func _finish(p95: float) -> void:
	_done = true
	set_process(false)
	Engine.max_fps = GraphicsSettings.FPS_CAP if OS.has_feature("mobile") else 0
	print("BENCH done p95=%.1fms levels=%s" % [p95, JSON.stringify(_levels)])
	finished.emit(_levels, p95)
