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
##   - 分幕建造演出：IntroNarrator 顺序播预制旁白，世界按幕「长」出来——空地 → 揭示树木(props) →
##       小伙伴逐个蹦出(会 wander 的负载村民，负载堆到峰值) → 注魔定档；无档案(未看过引导)时
##       穿插教学段（走路→靠近村民→开口说话，见 _run_tutorial）。可被家长长按 skip() 跳过。
##   - benchmark 段（无画质档时）：在【满负载活场景】上跑贪心定档（Benchmark.make）——村民
##       照常 wander（A* 计入 p95）、仅锁输入 + 仙子定格，注魔旁白盖住画质切换、点点带镜头慢巡，测完就地
##       应用 levels + save_all（不 change_scene）。负载（小伙伴）由本编排器铺、也由本编排器退场（转正前）。
##   - 转正：等 fetch（超时兜底）→ world._bootstrap_apply 演出化落地服务端世界 → 标记 intro 已看过。
##
## 兜底：离线（fetch 空）→ apply 保留虚拟世界；弱网（fetch 超时未完）→ 先离线转正，不阻塞（服务端
## 角色后补弹入的精细化留后续）；长按 skip → 停旁白/收麦、立即跳到转正。

signal finished

## 「下次进 world 要跑 intro」：上游（menu/onboarding）按 should_run 置位，world._ready 见到即挂本编排器
## 并消费掉。显式开关——默认 false，故 headless 测试直接实例化 main.tscn 不会误入。
## 画质定档（benchmark）现在只嵌在本编排器的注魔幕里跑，没有独立入口：新机器首启 / 「重新检测画质」
## 都靠 should_run（无画质档）走这一条路。
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
const FRIEND_SPAWN_GAP := 0.18    ## 小伙伴逐个「蹦出来」的间隔（秒）：错开登场，非齐刷刷冒出
const OPEN_EMPTY_BEAT := 1.2      ## 揭幕后留给「空地」的短暂一眼（秒）：树随开场白冒出来，不让孩子对着静止空地干等整条开场白
const TOUR_RADIUS := 3.2          ## 注魔期镜头慢巡半径（逻辑单位）：绕村中心轻飘，人群基本留画面里（保负载可比）
const TOUR_SPEED := 0.5           ## 巡游角速度（弧度/秒）：~12s 一圈，慢而不晕
const HINT_COLOR_WALK := Color(1.0, 0.92, 0.35, 0.9) ## 走路步地面环：暖黄「点这儿走过去」
const HINT_COLOR_NEAR := Color(0.5, 0.85, 1.0, 0.9)  ## 靠近步地面环：天蓝「走近这个小伙伴」

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
		_world.call("intro_hint_clear") # 收掉教学视觉指引（幂等）

func is_done() -> bool:
	return _done

func _run() -> void:
	_tutorial = not PlayerProfile.intro_seen() # 首次(未看过引导)才演教学；返回用户(仅补画质档)跳过
	if is_instance_valid(_world):
		_world.call("intro_hide_scenery") # 起手一片空地，建造幕再让树木/地面影「长出来」
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

## 建造演出脚本（设计 docs/benchmark-story-ramp-design.md）：分幕把世界「建造」出来，每幕加一层负载，
## 到注魔幕在满负载的活场景上定档——小朋友观赏的是一个逐步加压的故事，不是 loading。
## 空地 → 画地长树(props 揭示) → 小伙伴逐个蹦出(镜头绕环慢移+负载堆峰值) → 注魔定档(满负载/钉死镜头) →（首次）教学 → 就绪。
## 小伙伴必须在注魔【之前】到齐（峰值测准），故旁白 partner 提到 magic 前。有画质档则跳过注魔段（现状路径）。
func _show_intro() -> void:
	# 开场幕：揭幕后只留很短一眼空地，树就随开场白冒出来——原来是整条 intro_open_1(6.3s) 放完才长树，
	# 揭幕(~t6)到长树(~t10.5) 有 ~4.5s 空地静止期，孩子像被扔在空地上干等（老板反馈）。现在把
	# intro_show_scenery 提到开场白进行中(~1.2s)，保留「空地→长树」观感、消掉干等。
	await _open_with_scenery()
	await _narrate("intro_build_1")
	await _narrate("intro_build_2")
	# 热闹幕：小伙伴逐个蹦出来（会 wander 的负载村民，镜头绕环慢移）——在注魔测档【之前】把负载堆到峰值
	await _narrate("intro_partner_1")
	await _spawn_friends()
	# 注魔幕：满负载活场景定档（整段钉死镜头保 trial 可比，见 _run_benchmark）
	await _run_benchmark_if_needed()
	# 建造/热闹/注魔期抢的镜头交还玩家——benchmark 跑没跑都要还（返回用户跳过注魔，否则镜头卡在小伙伴环上）
	if is_instance_valid(_world):
		_world.set("focus_override", Vector2.INF)
		# 小伙伴（压测负载）退场，把干净世界交给转正（bench_despawn_load 幂等）
		_world.call("bench_despawn_load")
	if _tutorial:
		await _run_tutorial()
	await _narrate("intro_ready_1")

## 开场白：播起来 → 留 OPEN_EMPTY_BEAT 一眼空地 → 在【这条旁白进行中】揭示植被(树/地面影) → 等它播完。
## 拆出来是因为普通 _narrate 只能「播完再揭景」，而我们要「树随开场白冒出来」消掉空地干等。
## skip 时 dur=0：短睡立即返回、照样揭景（与原 _show_intro「skip 也 show_scenery」一致），再由转正 apply 收尾。
func _open_with_scenery() -> void:
	var dur := 0.0
	if not _skipped and _narrator != null:
		dur = _narrator.play("intro_open_1")
		_duck(true)
	await _sleep(minf(OPEN_EMPTY_BEAT, dur))
	if is_instance_valid(_world):
		_world.call("intro_show_scenery")
	await _sleep(maxf(dur + NARRATE_TAIL - OPEN_EMPTY_BEAT, 0.0))
	_duck(false)

## 热闹幕：逐个生出 EXTRA_CHARS 个会 wander 的「小伙伴」，错开登场像一个个蹦出来——也是 benchmark 的
## 峰值压测负载。被跳过则把剩下的一次补齐（别停在半空），每个 idx 只生一次不重复。
func _spawn_friends() -> void:
	var total := Benchmark.EXTRA_CHARS
	var center: Vector2 = _world.get("focus_logical") if is_instance_valid(_world) else Vector2.ZERO
	for i in total:
		if not is_instance_valid(_world):
			return
		_world.call("bench_spawn_one", i, total)
		# 巡游放在【建造期】：小伙伴一个个蹦出时点点带镜头缓缓扫过环上——有生气。放这儿而非注魔测档段，
		# 是因为测档时镜头必须钉死才能让各 trial 取景一致可比（见 _run_benchmark）。
		var ang := float(i) / float(maxi(total, 1)) * TAU
		_world.set("focus_override", WorldGrid.wrap_pos(center + Vector2(cos(ang), sin(ang)) * TOUR_RADIUS))
		if _skipped:
			for j in range(i + 1, total):
				_world.call("bench_spawn_one", j, total)
			return
		await _sleep(FRIEND_SPAWN_GAP)

## 注魔段（仅无画质档）：在满负载活场景上跑贪心 benchmark 定档。有画质档 → 跳过（现状路径不变）。
func _run_benchmark_if_needed() -> void:
	if _skipped or GraphicsSettings.has_saved():
		return
	await _run_benchmark()

## 内嵌 benchmark：负载（会 wander 的小伙伴）已由热闹幕 _spawn_friends 铺好、也由 _show_intro 退场——
## 这里 add_child 一个 embedded Benchmark 只在【活的峰值】上测（村民照常 wander，仅锁输入+仙子定格），
## 就地应用 levels + save_all（不 change_scene）。注魔旁白盖住画质切换（音频不占 GPU）。
##
## ⚠️ 测档整段【定住镜头】：真机实测——镜头慢巡会让相邻 trial 的采样窗落在不同取景 → p95 抖 ±18ms
## （trial 甚至出物理上不可能的负收益），贪心戚到一个幸运低样本就误报达标、提前收手，实际只有 23fps。
## 各 trial 取景一致才可比，所以整段测量把焦点钉死在能看到满村子的机位（村民仍 wander，CPU 负载照旧计入）。
## 巡游给观感的部分已挪到 _spawn_friends（建造期镜头动）。
## 家长跳过则中止定档、不写档（画质档没存 → 下次 should_run 自然重跑首启故事定档，不留 pending 快路径）。
## 用轮询等 finished（而非 await 信号）：skip 可随时打断，且规避「benchmark 先于 await 就绪就 emit」的竞态。
func _run_benchmark() -> void:
	var b := Benchmark.make(_world)
	_bench = b
	add_child(b)
	# 钉死焦点在当前机位（小伙伴环绕于此，＝能看到满村子的代表性视角），整段测量不动 → 各 trial 可比。
	if is_instance_valid(_world):
		_world.set("focus_override", _world.get("focus_logical"))
	# 注魔旁白【触发即播、不阻塞】——采样与它并行。若 await 旁白而旁白比一次测量长，benchmark 会在旁白期间
	# 就测完（headless 实测踩到）；这里不 await，测量自己在 _process 里跑，轮询等 is_done。
	if not _skipped and _narrator != null:
		_narrator.play("intro_magic_1")
		_duck(true)
	while not b.is_done() and not _skipped:
		await get_tree().create_timer(POLL_SEC).timeout
	_duck(false)
	if is_instance_valid(_world):
		_world.set("focus_override", Vector2.INF) # 交还镜头给玩家跟随（转正后相机贴回主角）
	if not b.is_done(): # 仅在被跳过时成立：中止、不定档（下次 should_run 见无画质档自然重跑故事）
		b.abort()
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
	var start := _player_logical()
	if is_instance_valid(_world):
		_world.call("intro_hint_at", _walk_goal(start), HINT_COLOR_WALK) # 亮一个「点这儿」的地面环
	await _narrate("intro_walk_ask")
	var moved := await _wait_until(func() -> bool:
		return WorldGrid.shortest_delta(start, _player_logical()).length() >= WALK_DIST, STEP_TIMEOUT_SEC)
	if is_instance_valid(_world):
		_world.call("intro_hint_clear")
	if moved:
		await _narrate("intro_walk_ok")

## 靠近村民：旁白引导走近 → 玩家进 APPROACH_RADIUS，world._update_npc_notice 自动令村民挥手 emote
## （不开口说话，守「预制音色=运行期音色」契约）→ 夸奖。
func _tutorial_approach() -> void:
	if _skipped:
		return
	if is_instance_valid(_world):
		var vpos := _nearest_villager_logical()
		if vpos != Vector2.INF:
			_world.call("intro_hint_at", vpos, HINT_COLOR_NEAR) # 光环落在那个小伙伴脚下
	await _narrate("intro_near_ask")
	var near := await _wait_until(func() -> bool:
		return _nearest_villager_dist() <= APPROACH_RADIUS, STEP_TIMEOUT_SEC)
	if is_instance_valid(_world):
		_world.call("intro_hint_clear")
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
	_world.call("intro_hint_mic") # 亮话筒+声波 HUD，对上「话筒亮起来就能说话」这句旁白
	var heard := await _wait_until(func() -> bool:
		return bool(_world.call("intro_heard_speech")), LISTEN_TIMEOUT_SEC)
	_world.call("intro_listen_end")
	_world.call("intro_hint_clear")
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

## 最近 demo 村民的逻辑坐标（无则 INF）——靠近步的光环落点。
func _nearest_villager_logical() -> Vector2:
	var pl := _player_logical()
	var best := INF
	var best_pos := Vector2.INF
	for n in (_world.get("npcs") as Array):
		var d: Dictionary = n
		if d.get("is_fairy", false) or not String(d.get("id", "")).begins_with("demo_"):
			continue
		var pos: Vector2 = d.get("logical", Vector2.ZERO)
		var dist := WorldGrid.shortest_delta(pl, pos).length()
		if dist < best:
			best = dist
			best_pos = pos
	return best_pos

## 走路步的光环落点：朝最近小伙伴的方向、离玩家 WALK_DIST+1.5 处放一个点（走过去正好达标、也顺势带向靠近步）；
## 没有小伙伴就默认往 +X 放一个够远的点。
func _walk_goal(start: Vector2) -> Vector2:
	var dir := Vector2(1.0, 0.0)
	var vpos := _nearest_villager_logical()
	if vpos != Vector2.INF:
		var d := WorldGrid.shortest_delta(start, vpos)
		if d.length() > 0.1:
			dir = d.normalized()
	return WorldGrid.wrap_pos(start + dir * (WALK_DIST + 1.5))

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
