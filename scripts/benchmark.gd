class_name Benchmark
extends Node
## 新机器画质定档：在受控负载下测出「这台机器能跑稳 30fps 的最高画质档」。
##
## 只有一条路径——嵌在首启「建造小世界」的注魔幕里跑（IntroDirector 在无画质档时 make + add_child）。
## 不另搭 benchmark 场景、不切场景、不建遮罩：测的就是孩子真正会看到的那条渲染路径——地形、水面、
## 散布植被、SDF 物件（描边 + 顶点吸附）、纸片角色（立绘 + 实时阴影 + X 光剪影）、天空、雾。另起炉灶
## 必然要复制一份太阳灯/环境参数，两处定义早晚漂移，测出来的档也就不作数。world.set_bench_freeze 只
## 短路掉「跟渲染无关」的部分：锁玩家输入（相机/主角不动，防拖动干扰）+ 仙子定格（旁白干净）。
##
## 负载 = 活的热闹世界（不冻结——冻结静态场景系统性偏轻、测出全最高）：
##   - IntroDirector 在热闹幕铺好 EXTRA_CHARS 个会 wander 的「小伙伴」（真图集 + idle 动画 + 注册占用），
##     benchmark 只在这活的峰值上测；退场也由 IntroDirector 在转正前统一做（它是负载 owner）。
##   - 采样期它们照常 wander：A* 寻路 + 走动 CPU 计入 p95，才是弱机真实卡顿的来源
##   - 换档前后仍可比：人口/物件数稳定 + 2.4s 窗口 p95 + MIN_GAIN_MS 门槛吸收 wander 抖动
##
## 测量：每档 warmup 后采 p95 帧时（见 FrameSampler）。达标线 = GraphicsSettings.TARGET_FRAME_MS。
## 贪心求解在 _advance()（见该函数注释）。设计 docs/benchmark-story-ramp-design.md。

signal finished(levels: Dictionary, p95_ms: float)

const EXTRA_CHARS := 12   ## 环绕玩家的额外角色数：压满角色渲染这条最贵的路径
const MIN_GAIN_MS := 1.5  ## 「关了真的有明显提升」的门槛：收益低于它就不值得掉这档画质
const MAX_MEASURES := 30  ## 测量次数硬上限（~30×3.6s ≈ 108s）：最弱的机器也不能无限测下去
const HYSTERESIS_MS := 2.0 ## 近并列滞回：后选旋钮收益要超过当前最佳 HYSTERESIS_MS 才顶替，否则按 KEYS
                           ## 固定顺序留在先试的那个——杀掉「两旋钮收益差在测量噪声内、两次跑各选各的、
                           ## 采纳档不可复现」（PoC 实测：actor_shadows 与 hi_res 差 ~1-2ms，一次开一次关）。

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
var _api: Api

## 由 IntroDirector 在无画质档时 add_child 调用（注魔幕）。不切场景、不建遮罩、就地应用 levels。
static func make(world: Node3D) -> Benchmark:
	var b := Benchmark.new()
	b.name = "Benchmark"
	b._world = world
	return b

func is_done() -> bool:
	return _done

func _ready() -> void:
	Engine.max_fps = 0  # 测真实帧时：menu 的 30fps cap 会把帧时钳在 33ms，测不出余量
	_api = _world.get("api")  # intro 模式 world 已建 api，复用它上报（不另建 BenchApi）
	# 负载（会 wander 的「小伙伴」）已由 IntroDirector 在热闹幕分幕生好、也由它退场——benchmark 只管
	# 在活的峰值上测。benchmark 期锁玩家输入（相机/主角不动，防拖动干扰）+ 仙子定格（旁白干净）；
	# 村民【不】冻结：采样期照常 wander，A* + 走动 CPU 计入 p95 才测得准。
	_world.call("set_bench_freeze", true)
	_levels = GraphicsSettings.all_max()  # 从全最高档起步，能不降就不降
	_start_measure(_levels)

## 压测负载的 spawn/despawn 在 world（bench_spawn_one / bench_despawn_load）：负载角色注册占用 +
## 挂 ambient wander，同时压渲染与寻路 CPU（静态负载测不出寻路那笔），退场时对称注销 + 取消执行器。
## ⚠️ 换负载改了成本 → 改 p95 → 必须同步 bump DeviceProfile.BENCH_VERSION。

## intro 被家长跳过时中止定档：复位到当前采纳档画面、解冻，不写档不上报
## （留待下次 should_run 重跑首启故事定档，见 IntroDirector._run_benchmark）。
func abort() -> void:
	if _done:
		return
	_done = true
	_trial_key = ""
	set_process(false)
	for key: String in GraphicsSettings.KEYS:  # 可能停在没被采纳的试降档上 → 复位到当前采纳档
		_world.call("_apply_graphics_key", key, int(_levels[key]))
	Engine.max_fps = GraphicsSettings.FPS_CAP if OS.has_feature("mobile") else 0
	_world.call("set_bench_freeze", false)  # 负载退场由 IntroDirector 在转正前统一做（它是负载 owner）

## 应用一组档并开始采样。
func _start_measure(levels: Dictionary) -> void:
	# 确定化：每次测量前把压测负载复位到同一状态（村民回各自 home + 重启固定巡逻），让每个 trial 的
	# 采样窗都跑【同一段】动态负载序列，而非各测各的随机 wander（±60ms 噪声的大头，见 PoC）。
	_world.call("bench_reset_load")
	for key: String in GraphicsSettings.KEYS:
		_world.call("_apply_graphics_key", key, int(levels[key]))
	_sampler = FrameSampler.new()
	_measures += 1

func _process(delta: float) -> void:
	if _done or _sampler == null:
		return
	_sampler.feed(delta)
	# 采样期【不】冻结村民：villager wander（A* + 走动）全程活着，帧时反映真实负载。
	# 活场景的帧时抖动由 2.4s 窗口 + p95 + MIN_GAIN_MS 门槛吸收（见 _advance）。
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
	if gain > _best_gain + HYSTERESIS_MS:  # 滞回：后选旋钮要明显更优才顶替，近并列按 KEYS 顺序留先试的
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
	# 存本机（source=bench：不是用户手改的，日后 backend 有更好的众包结果可以覆盖它）
	GraphicsSettings.save_all(_levels, "bench", {
		"gpu": DeviceProfile.gpu(), "bench_version": DeviceProfile.BENCH_VERSION,
		"p95_ms": snappedf(_cur_ms, 0.1), "hit": hit,
	})
	# 就地收尾（不 change_scene）：解锁输入/仙子。压测负载（小伙伴）退场由 IntroDirector 在转正前统一做。
	_world.call("set_bench_freeze", false)
	finished.emit(_levels, _cur_ms)
	_upload(hit)

## 上报这台机器的结果（后来的同 GPU 机器就不用再当小白鼠了）。上传失败不影响孩子玩——
## 本机档已经存好了，下次启动直接用。就地收尾不切场景（intro 继续走它的转正）。
func _upload(hit: bool) -> void:
	# 没有 GPU 名就不上传：众包按 GPU 分桶，没 key 的样本服务端只会 400（本机档已存好，不影响玩）
	if _api != null and not DeviceProfile.gpu().is_empty():
		await _api.post_json("/device-profile", {
			"gpu": DeviceProfile.gpu(),
			"benchVersion": DeviceProfile.BENCH_VERSION,
			"deviceId": DeviceProfile.device_id(),
			"levels": _levels,
			"p95Ms": snappedf(_cur_ms, 0.1),
			"hit": hit,
		})
