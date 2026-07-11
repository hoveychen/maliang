class_name IntroDirector
extends Node
## 「建造小世界」前置演出编排器（P3 骨架）。挂在 world 上（类比 Benchmark.make(world)），
## 在 world intro 模式下驱动：早揭幕 → 后台预取(fetch) → 建造演出 → benchmark 段 → 转正(apply)。
##
## 载体 = world 的 intro 模式（不新增场景，见设计 D1）：world 照常 _ready（打包地形+seed 村民占位+
## 本地仙子＝虚拟场景），本编排器只管演出节奏与「拉取/应用」两半段的时序。
##
## 分段职责边界（本文件是骨架，占位段留给后续 P 落地）：
##   - 早揭幕：首屏铺几帧后 emit world_ready，让 loading 过场淡出、露出建造演出（复用现有 reveal）。
##   - fetch：world._bootstrap_fetch 后台跑（只落缓存/数据，不动场景）——见 world.gd P3 地基。
##   - 建造演出（P4 旁白+教学 / P5 建造动画）：此处目前是占位等待，可被家长长按 skip() 跳过。
##   - benchmark 段（P5）：无画质档时跑贪心定档；骨架先采纳当前保守默认档为已定档（source=intro-default），
##       使 has_saved() 转真、下次启动不再因缺画质档重进 intro。真 benchmark 由 P5 替换。
##   - 转正：等 fetch（超时兜底）→ world._bootstrap_apply 演出化落地服务端世界 → 标记 intro 已看过。
##
## 兜底：离线（fetch 空）→ apply 保留虚拟世界；弱网（fetch 超时未完）→ 先离线转正，不阻塞（骨架取此
## 保守策略，服务端角色后补弹入的精细化留后续）；长按 skip → 立即跳到转正。

signal finished

## 「下次进 world 要跑 intro」：上游（menu/onboarding）按 should_run 置位，world._ready 见到即挂本编排器
## 并消费掉。与 Benchmark.pending 同款显式开关——默认 false，故 headless 测试直接实例化 main.tscn 不会误入。
static var pending := false

## 是否需要 intro 前置阶段：无画质档（新 GPU 待定档）或未看过建造演出（首次）。
## 二者有其一即进；都齐全 → 现状路径（menu → loading → world，零侵入）。见分流矩阵。
static func should_run() -> bool:
	return not GraphicsSettings.has_saved() or not PlayerProfile.intro_seen()

const REVEAL_FRAMES := 3          ## 首屏铺几帧后早揭幕（loading 淡出露出建造演出）
const BUILD_SHOW_SEC := 2.0       ## 建造演出占位时长（P4/P5 用真旁白+动画时长替换）
const FETCH_TIMEOUT_SEC := 20.0   ## 转正前等 fetch 的上限（弱网兜底：到点先离线转正）
const POLL_SEC := 0.1

var _world: Node3D
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

func is_done() -> bool:
	return _done

func _run() -> void:
	# ① 早揭幕：等首屏铺几帧（避免揭幕即黑屏），emit world_ready → loading 过场淡出、露出世界。
	for _i in range(REVEAL_FRAMES):
		await get_tree().process_frame
	if is_instance_valid(_world) and _world.has_signal("world_ready"):
		_world.emit_signal("world_ready")

	# ② 后台预取（建造演出期间跑）：只落缓存/数据，不动场景。
	_fetch_bg()

	# ③ 建造演出（占位；P4 接旁白+教学、P5 接建造动画）。可被 skip 打断。
	await _sleep(BUILD_SHOW_SEC)

	# ④ benchmark 段（占位；P5 接贪心定档）。骨架：无画质档时采纳当前保守默认为已定档。
	if not GraphicsSettings.has_saved():
		var levels: Dictionary = _world.get("_gfx_levels")
		if typeof(levels) == TYPE_DICTIONARY and not levels.is_empty():
			GraphicsSettings.save_all(levels, "intro-default", { "note": "P3 skeleton: 未跑 benchmark，采纳保守默认（P5 替换为真定档）" })

	# ⑤ 转正：等 fetch（超时兜底）→ apply 演出化落地。skip 也走这条（fetch 可能还没完 → 离线转正）。
	await _await_fetch_or_timeout()
	if is_instance_valid(_world):
		await _world.call("_bootstrap_apply", _fetched)
		_world.set("_player_restore_pending", false)

	# ⑥ 记住 intro 已看过（下次不再演教学）。
	PlayerProfile.mark_intro_seen()
	_done = true
	finished.emit()

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
