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
signal progress(done: int, total: int)  ## 供调优页进度条（total 是上限，多数机器提前达标）

## 「下次进 world 要定档」：world._ready 见到它就挂 Benchmark 并短路掉后端/麦克风/引导。
## 由新机器首启、或设置页「重新检测画质」置位；Benchmark 一 _ready 就消费掉它。
static var pending := false

const EXTRA_CHARS := 12   ## 环绕玩家的额外角色数：压满角色渲染这条最贵的路径
const MIN_GAIN_MS := 1.5  ## 「关了真的有明显提升」的门槛：收益低于它就不值得掉这档画质
const MAX_MEASURES := 30  ## 测量次数硬上限（~30×3.6s ≈ 108s）：最弱的机器也不能无限测下去

var _world: Node3D
var _levels: Dictionary          ## 当前采纳的档
var _sampler: FrameSampler
var _baseline_ms := 0.0          ## 全最高档的 p95（报告用）
var _cur_ms := 0.0               ## 当前采纳档的 p95
var _queue: Array[String] = []   ## 本轮待试的旋钮
var _trial_key := ""             ## 正在试降的旋钮（空 = 在测采纳档本身）
var _best_key := ""              ## 本轮收益最大的旋钮
var _best_gain := -INF
var _best_ms := 0.0
var _measures := 0
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
	_measures += 1
	progress.emit(_measures, MAX_MEASURES)

func _process(delta: float) -> void:
	if _done or _sampler == null:
		return
	_sampler.feed(delta)
	if _sampler.is_done():
		_advance(_sampler.p95_ms())

## 一档测完 → 贪心推进。
##
## 算法（老板的约束：只关「关了真的有明显帧率提升」的，不为了凑帧率白牺牲画质）：
##   1. 全最高档测基线；已达标 → 直接收工，强机不该被降档
##   2. 每轮：对每个还能降的旋钮各试降一级、各测一次 p95，算收益 = 当前 p95 - 试降后 p95
##   3. 挑收益最大的那个：收益 > MIN_GAIN_MS 才真降下去；否则说明瓶颈根本不在这些旋钮
##      （CPU 卡、或机器就是弱），继续降只会白掉画质 → 停手，交出当前档（未达标如实上报）
##   4. 降完达标 → 收工；否则开下一轮
##
## 代价：每轮 O(剩余旋钮数) 次测量、每次 ~3.6s。达标即停，多数机器 1-2 轮就够；
## 最弱的机器由 MAX_MEASURES 兜底，免得孩子对着进度条等到天荒地老。
func _advance(p95: float) -> void:
	if _trial_key.is_empty():
		# 基线（或上一轮采纳后的复测）
		_cur_ms = p95
		if _baseline_ms <= 0.0:
			_baseline_ms = p95
		if _cur_ms <= GraphicsSettings.TARGET_FRAME_MS:
			_finish()  # 达标：一个旋钮都不用降
			return
		_begin_round()
		return
	# 正在试降某个旋钮：结算它的收益
	var gain := _cur_ms - p95
	print("BENCH trial %-14s lv%d p95=%.1fms gain=%+.1fms" % [
		_trial_key, int(_levels[_trial_key]) - 1, p95, gain])
	if gain > _best_gain:
		_best_gain = gain
		_best_key = _trial_key
		_best_ms = p95
	if not _queue.is_empty():
		_try_next()
		return
	# 本轮所有候选试完
	if _best_gain <= MIN_GAIN_MS or _best_key.is_empty():
		print("BENCH 本轮最佳收益 %+.1fms ≤ %.1fms 门槛：瓶颈不在画质旋钮，停手保画质" % [
			_best_gain, MIN_GAIN_MS])
		_finish()
		return
	_levels[_best_key] = int(_levels[_best_key]) - 1  # 真降下去
	_cur_ms = _best_ms
	print("BENCH 采纳 %s → lv%d（收益 %+.1fms，p95=%.1fms）" % [
		_best_key, int(_levels[_best_key]), _best_gain, _cur_ms])
	if _cur_ms <= GraphicsSettings.TARGET_FRAME_MS or _measures >= MAX_MEASURES:
		_finish()
		return
	_begin_round()

## 开一轮：把所有还能降的旋钮排进候选队列。
func _begin_round() -> void:
	_queue.clear()
	for key: String in GraphicsSettings.KEYS:
		if int(_levels[key]) > 0:
			_queue.append(key)
	_best_gain = -INF
	_best_key = ""
	_best_ms = 0.0
	if _queue.is_empty() or _measures >= MAX_MEASURES:
		_finish()  # 所有旋钮见底 / 测量预算用尽
		return
	_try_next()

## 试降队首旋钮一级（在当前采纳档的基础上，只动这一个）。
func _try_next() -> void:
	if _measures >= MAX_MEASURES:
		_exhaust()  # 上限也要在轮内查：一轮有 9 个候选，只在开轮时查会冲破预算
		return
	_trial_key = _queue.pop_front()
	var trial := _levels.duplicate()
	trial[_trial_key] = int(trial[_trial_key]) - 1
	_start_measure(trial)

## 测量预算用尽：本轮已经试出的最佳收益别浪费——够门槛就采纳，再交出当前档收工。
func _exhaust() -> void:
	if _best_gain > MIN_GAIN_MS and not _best_key.is_empty():
		_levels[_best_key] = int(_levels[_best_key]) - 1
		_cur_ms = _best_ms
	print("BENCH 测量预算用尽（%d 次）：交出当前最优档，未达标也不再测" % _measures)
	_finish()

func _finish() -> void:
	_done = true
	_trial_key = ""
	set_process(false)
	for key: String in GraphicsSettings.KEYS:  # 最后一次测的可能是没被采纳的试降档
		_world.call("_apply_graphics_key", key, int(_levels[key]))
	Engine.max_fps = GraphicsSettings.FPS_CAP if OS.has_feature("mobile") else 0
	var hit := _cur_ms <= GraphicsSettings.TARGET_FRAME_MS
	print("BENCH done p95=%.1fms（基线 %.1fms）达标=%s 测量%d次 levels=%s" % [
		_cur_ms, _baseline_ms, hit, _measures, JSON.stringify(_levels)])
	finished.emit(_levels, _cur_ms)
