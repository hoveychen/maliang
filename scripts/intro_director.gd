class_name IntroDirector
extends Node
## 「建造小世界」前置演出编排器（P3 骨架 → P4 旁白+教学）。挂在 world 上（类比 Benchmark.make(world)），
## 在 world intro 模式下驱动：早揭幕 → 后台预取(fetch) → 建造演出(旁白+教学) → benchmark 段 → 转正(apply)。
##
## 载体 = world 的 intro 模式（不新增场景，见设计 D1）：world 照常 _ready（打包地形+seed 村民占位+
## 本地仙子＝虚拟场景），本编排器只管演出节奏与「拉取/应用」两半段的时序。
##
## 分段职责边界：
##   - 早揭幕：首屏铺几帧后 emit world_ready，让 loading 过场淡出、露出建造演出（复用现有 reveal）。
##   - fetch：world._bootstrap_fetch 后台跑（只落缓存/数据，不动场景）——见 world.gd P3 地基。
##   - 建造演出（P4）：IntroNarrator 顺序播预制旁白（开场/建造/伙伴/转正）；无档案(未看过引导)时
##       穿插教学段（走路→靠近村民→开口说话，见 _run_tutorial / 设计 D4）。可被家长长按 skip() 跳过。
##   - benchmark 段（P5，设计 D5）：无画质档时就地跑贪心定档（Benchmark.make_embedded）——采样期冻结
##       世界保证可复现帧，注魔旁白盖住采样窗，测完就地应用 levels + save_all（不 change_scene），
##       压测负载（12 村民雏形）测完退场。跑在「建造段」与「伙伴段」之间（见 _show_intro / 设计 §5）。
##   - 转正：等 fetch（超时兜底）→ world._bootstrap_apply 演出化落地服务端世界 → 标记 intro 已看过。
##
## 兜底：离线（fetch 空）→ apply 保留虚拟世界；弱网（fetch 超时未完）→ 先离线转正，不阻塞（服务端
## 角色后补弹入的精细化留后续）；长按 skip → 停旁白/收麦、立即跳到转正。

signal finished

## 「下次进 world 要跑 intro」：上游（menu/onboarding）按 should_run 置位，world._ready 见到即挂本编排器
## 并消费掉。与 Benchmark.pending 同款显式开关——默认 false，故 headless 测试直接实例化 main.tscn 不会误入。
static var pending := false

## 是否需要 intro 前置阶段：无画质档（新 GPU 待定档）或未看过建造演出（首次）。
## 二者有其一即进；都齐全 → 现状路径（menu → loading → world，零侵入）。见分流矩阵。
static func should_run() -> bool:
	return not GraphicsSettings.has_saved() or not PlayerProfile.intro_seen()

const REVEAL_FRAMES := 3          ## 首屏铺几帧后早揭幕（loading 淡出露出建造演出）
const NARRATE_TAIL := 0.4         ## 每条旁白播完后的停顿（秒），衔接不抢拍
const FETCH_TIMEOUT_SEC := 20.0   ## 转正前等 fetch 的上限（弱网兜底：到点先离线转正）
const POLL_SEC := 0.1
const WALK_DIST := 3.0            ## 教学「走路」达标位移（逻辑单位）
const APPROACH_RADIUS := 6.0      ## 教学「靠近村民」达标半径（< world.NOTICE_RADIUS=6.5，保证村民会挥手 emote）
const STEP_TIMEOUT_SEC := 25.0    ## 单个教学步等孩子操作的上限（到点静默推进，不卡住演出）
const LISTEN_TIMEOUT_SEC := 15.0  ## 教学「开口说话」步等开口的上限

var _world: Node3D
var _narrator: IntroNarrator
var _tutorial := false            ## 是否演教学段（无档案/未看过引导；run 开始时定，早于 mark_intro_seen）
var _bench: Benchmark = null       ## 正在跑的内嵌 benchmark（skip 时据此中止；见 _run_benchmark）
var _fetched: Dictionary = {}
var _fetch_done := false
var _skipped := false
var _done := false

static func make(world: Node3D) -> IntroDirector:
	var d := IntroDirector.new()
	d.name = "IntroDirector"
	d._world = world
	return d

func _ready() -> void:
	_run()

## 家长长按跳过：置位后各占位段提前结束、直奔转正（fetch 继续后台跑，benchmark 未完则不定档留待下次）。
func skip() -> void:
	_skipped = true
	if _narrator != null:
		_narrator.stop()
	if is_instance_valid(_world):
		_world.call("intro_listen_end") # 教学监听中被跳过：立即收麦（幂等）

func is_done() -> bool:
	return _done

func _run() -> void:
	_tutorial = not PlayerProfile.intro_seen() # 首次(未看过引导)才演教学；返回用户(仅补画质档)跳过
	_narrator = IntroNarrator.new()
	_narrator.name = "IntroNarrator"
	add_child(_narrator)

	# ① 早揭幕：等首屏铺几帧（避免揭幕即黑屏），emit world_ready → loading 过场淡出、露出世界。
	for _i in range(REVEAL_FRAMES):
		await get_tree().process_frame
	if is_instance_valid(_world) and _world.has_signal("world_ready"):
		_world.emit_signal("world_ready")

	# ② 后台预取（建造演出期间跑）：只落缓存/数据，不动场景。
	_fetch_bg()

	# ③ 建造演出：旁白 + 注魔段(benchmark) + （首次）教学。可被 skip 打断。
	await _show_intro()

	# ④ 转正：等 fetch（超时兜底）→ apply 演出化落地。skip 也走这条（fetch 可能还没完 → 离线转正）。
	await _await_fetch_or_timeout()
	if is_instance_valid(_world):
		await _world.call("_bootstrap_apply", _fetched)
		_world.set("_player_restore_pending", false)

	# ⑤ 记住 intro 已看过（下次不再演教学）。
	PlayerProfile.mark_intro_seen()
	_done = true
	finished.emit()

## 建造演出脚本（设计 §5）：开场 → 建造 → 注魔段(benchmark) → 伙伴 →（首次）教学 → 转正旁白。
## 注魔段（intro_magic_1 + 内嵌 benchmark 定档）夹在建造与伙伴之间：先把世界的地基/树木盖出来，
## 再施法让画质「变清晰」，然后小伙伴才登场。有画质档（众包命中/返回用户）则跳过注魔段。
func _show_intro() -> void:
	await _narrate("intro_open_1")
	await _narrate("intro_build_1")
	await _narrate("intro_build_2")
	await _run_benchmark_if_needed()
	await _narrate("intro_partner_1")
	if _tutorial:
		await _run_tutorial()
	await _narrate("intro_ready_1")

## 注魔段（设计 D5，仅无画质档）：就地跑贪心 benchmark 定档。有画质档 → 跳过（现状路径不变）。
func _run_benchmark_if_needed() -> void:
	if _skipped or GraphicsSettings.has_saved():
		return
	await _run_benchmark()

## 内嵌 benchmark：add_child 即冻结世界 + 塞压测负载 + 起测；注魔旁白盖住采样窗（音频不占 GPU）；
## 跑完 Benchmark 就地应用 levels + save_all（不 change_scene，见 D1）、压测负载退场，然后继续演出。
## 家长跳过则中止定档、不写档，记 Benchmark.pending 留待下次快速定档（不再重演整段 intro 建造）。
## 用轮询等 finished（而非 await 信号）：skip 可随时打断，且规避「benchmark 先于 await 就绪就 emit」的竞态。
func _run_benchmark() -> void:
	var b := Benchmark.make_embedded(_world)
	_bench = b
	add_child(b)
	await _narrate("intro_magic_1")
	while not b.is_done() and not _skipped:
		await get_tree().create_timer(POLL_SEC).timeout
	if not b.is_done(): # 仅在被跳过时成立：中止、不定档、留待下次
		b.abort()
		Benchmark.pending = true
	if is_instance_valid(b):
		b.queue_free()
	_bench = null

## 教学段（仅无档案/首次，见设计 D4）：走路 → 靠近村民（村民只 emote 不开口）→ 开口说话。
## 每步都有超时兜底，孩子不操作也会静默推进，不卡演出。
func _run_tutorial() -> void:
	await _tutorial_walk()
	await _tutorial_approach()
	await _tutorial_speak()

## 走路：旁白引导点地走 → 检测玩家位移达标 → 夸奖。点击移动在 intro 期正常可用（intro 不 gate 输入）。
func _tutorial_walk() -> void:
	if _skipped:
		return
	await _narrate("intro_walk_ask")
	var start := _player_logical()
	var moved := await _wait_until(func() -> bool:
		return WorldGrid.shortest_delta(start, _player_logical()).length() >= WALK_DIST, STEP_TIMEOUT_SEC)
	if moved:
		await _narrate("intro_walk_ok")

## 靠近村民：旁白引导走近 → 玩家进 APPROACH_RADIUS，world._update_npc_notice 自动令村民挥手 emote
## （不开口说话，守「预制音色=运行期音色」契约）→ 夸奖。
func _tutorial_approach() -> void:
	if _skipped:
		return
	await _narrate("intro_near_ask")
	var near := await _wait_until(func() -> bool:
		return _nearest_villager_dist() <= APPROACH_RADIUS, STEP_TIMEOUT_SEC)
	if near:
		await _narrate("intro_near_ok")

## 开口说话：教「话筒亮了就能说」这个手势。本地 VAD 检测到开口即算完成，不理解内容、不上传 PCM。
## 端侧 ASR 未就绪(旧 Android 首次加载)→ 跳过本步（只教走路/靠近）。
func _tutorial_speak() -> void:
	if _skipped:
		return
	if bool(_world.call("intro_asr_blocked")):
		return
	await _narrate("intro_talk_ask")
	_world.call("intro_listen_begin")
	var heard := await _wait_until(func() -> bool:
		return bool(_world.call("intro_heard_speech")), LISTEN_TIMEOUT_SEC)
	_world.call("intro_listen_end")
	if heard:
		await _narrate("intro_talk_ok")

## 播一条旁白并 await 其时长（+尾停）。skip 后立即返回不再播。播放期间压低 BGM。
func _narrate(id: String) -> void:
	if _skipped or _narrator == null:
		return
	var dur := _narrator.play(id)
	_duck(true)
	await _sleep(dur + NARRATE_TAIL)
	_duck(false)

## 压低/恢复 BGM（旁白期间让仙子的声音清楚）。game_audio 未就绪则静默跳过。
func _duck(on: bool) -> void:
	if not is_instance_valid(_world):
		return
	var ga: Variant = _world.get("game_audio")
	if ga != null and (ga as Node).has_method("set_ducked"):
		ga.call("set_ducked", on)

## 轮询等某条件成立或到超时；skip 时立即返回 false。成立返回 true。
func _wait_until(pred: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout and not _skipped:
		if bool(pred.call()):
			return true
		await get_tree().create_timer(POLL_SEC).timeout
		waited += POLL_SEC
	return false

## 玩家当前逻辑坐标（未就位则原点）。
func _player_logical() -> Vector2:
	var p: Variant = _world.get("player")
	if typeof(p) == TYPE_DICTIONARY and not (p as Dictionary).is_empty():
		return (p as Dictionary).get("logical", Vector2.ZERO)
	return Vector2.ZERO

## 最近的 demo 占位村民到玩家的距离（无则 INF）。
func _nearest_villager_dist() -> float:
	var pl := _player_logical()
	var best := INF
	for n in (_world.get("npcs") as Array):
		var d: Dictionary = n
		if d.get("is_fairy", false) or not String(d.get("id", "")).begins_with("demo_"):
			continue
		var dist := WorldGrid.shortest_delta(pl, d.get("logical", Vector2.ZERO)).length()
		if dist < best:
			best = dist
	return best

## 后台 fetch（fire-and-forget，跑到首个 await 即返回）：完成后存结果、置 _fetch_done。
func _fetch_bg() -> void:
	var res: Variant = await _world.call("_bootstrap_fetch")
	_fetched = res if typeof(res) == TYPE_DICTIONARY else {}
	_fetch_done = true

## 等 fetch 完成或到超时（弱网兜底）；skip 时也顶多等到 fetch 完（转正需要素材）——
## 但若 skip 且 fetch 未完，仍走超时兜底避免卡住。
func _await_fetch_or_timeout() -> void:
	var waited := 0.0
	while not _fetch_done and waited < FETCH_TIMEOUT_SEC:
		await get_tree().create_timer(POLL_SEC).timeout
		waited += POLL_SEC

## 分段小睡：每 POLL_SEC 检查一次 skip，被跳过则立即返回（不空等剩余时长）。
func _sleep(sec: float) -> void:
	var waited := 0.0
	while waited < sec and not _skipped:
		await get_tree().create_timer(POLL_SEC).timeout
		waited += POLL_SEC
