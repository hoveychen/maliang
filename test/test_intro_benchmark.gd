extends SceneTree
## intro 内嵌 benchmark 段的编排机制。无画质档 + 已看过引导（intro_seen=true 隔离掉教学段）
## → 建造演出跑到注魔段时 add_child 一个 embedded Benchmark：锁玩家输入 + 仙子定格（村民照常 wander）、
## 塞 EXTRA_CHARS 个会 wander 的村民压测负载、跑贪心定档，测完就地应用 levels + save_all(source=bench)、
## 压测负载退场、解锁，intro 继续到转正。
##
## ⚠️ headless 帧时是假的（--fixed-fps 60 → 每帧恒 16.7ms ≤ 33.3ms 达标线 → 基线即达标、零试降、一次
## 测量收工）。所以本测只验【编排机制】：Benchmark 挂上→定档→就地应用了档、没 change_scene、压测负载
## spawn（会 wander）后 despawn、intro 继续到底。真机定档效果（哪个旋钮真省 ms、贪心是否砍档、稳不稳
## 25-30fps）只能在真机抓 BENCH 日志验，是 P4 验收门——本测不声称验证了帧时/定档正确性。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 60 --quit-after 3600 \
##       --script res://test/test_intro_benchmark.gd

var scene: Node
var frame := 0
var fails := 0
var done := false
var saw_bench_node := false      ## 采样期 Benchmark 节点挂上过
var saw_bench_load := false      ## 采样期见到过 bench_ 压测角色
var saw_freeze := false          ## benchmark 全程锁输入/仙子定格（_bench_freeze）出现过
var bench_moved := false         ## 采样期村民【活着】：某 bench_ 负载角色在 benchmark 期间 wander 移动过（非冻结）
var _bench_pos0: Dictionary = {} ## bench_ 角色首见时的逻辑坐标，用于判定它后来移动过
# —— P2 分幕建造观测 ——
var saw_scenery_hidden := false  ## 建造前散布植被被藏起过（perf_props 组存在节点且全不可见）
var saw_scenery_shown := false   ## 建造幕后散布植被显示出来了（perf_props 组有可见节点）
var saw_friends_partial := false ## 小伙伴【逐个】蹦出：见过 0<n<EXTRA_CHARS 的中间态（非齐刷刷一次生齐）
var saw_camera_tour := false     ## 注魔期点点带镜头慢巡：focus_override 被设成非 INF 过
var _max_bench := 0              ## 见过的 bench_ 角色数峰值（应达到 EXTRA_CHARS）

func _initialize() -> void:
	PlayerProfile.clear() # 清画质档（has_saved→false，触发 benchmark）+ intro_seen
	var p := PlayerProfile.load_profile()
	p["intro_seen"] = true # 已看过引导 → _tutorial=false，隔离掉教学段只测 benchmark
	PlayerProfile.save_profile(p)
	IntroDirector.pending = true
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null or done:
		return
	frame += 1
	# —— P2 分幕建造：散布植被 隐藏→显示 ——
	var props := scene.get_tree().get_nodes_in_group("perf_props")
	if not props.is_empty():
		var any_vis := false
		var all_hidden := true
		for pn in props:
			if (pn as Node3D).visible:
				any_vis = true
				all_hidden = false
		if all_hidden:
			saw_scenery_hidden = true
		if any_vis:
			saw_scenery_shown = true
	# 采样期锁存观测（benchmark 结束会解冻/退场，只能在窗口内抓）
	var bench_running := scene.get_node_or_null("IntroDirector/Benchmark") != null
	if bench_running:
		saw_bench_node = true
		# 注魔期镜头慢巡：focus_override 被设成非 INF
		if (scene.get("focus_override") as Vector2) != Vector2.INF:
			saw_camera_tour = true
	if bool(scene.get("_bench_freeze")):
		saw_freeze = true
	# 小伙伴逐个蹦出：数当前 bench_ 角色，抓到中间态(0<n<总数)即证「逐个」而非一次生齐
	var bench_now := 0
	for n in (scene.get("npcs") as Array):
		if String((n as Dictionary).get("id", "")).begins_with("bench_"):
			bench_now += 1
	_max_bench = maxi(_max_bench, bench_now)
	if bench_now > 0 and bench_now < Benchmark.EXTRA_CHARS:
		saw_friends_partial = true
	# 采样期村民必须【活着】：抓 bench_ 负载角色，看它在 benchmark 期间 wander 移动过（旧口径会冻结它们）
	if bench_running:
		for n in (scene.get("npcs") as Array):
			var d := n as Dictionary
			var id := String(d.get("id", ""))
			if not id.begins_with("bench_"):
				continue
			saw_bench_load = true
			var lg: Vector2 = d.get("logical", Vector2.ZERO)
			if _bench_pos0.has(id):
				if (_bench_pos0[id] as Vector2).distance_to(lg) > 0.5:
					bench_moved = true
			else:
				_bench_pos0[id] = lg
	var intro: Node = scene.get("_intro")
	if intro != null and bool(intro.call("is_done")):
		done = true
		_finish()

func _finish() -> void:
	# —— 采样期机制 ——
	_check("采样期挂上 Benchmark 节点", saw_bench_node, true)
	_check("采样期塞进压测负载（bench_ 村民雏形）", saw_bench_load, true)
	_check("benchmark 全程锁输入/仙子定格", saw_freeze, true)
	_check("采样期村民活着（wander 移动，非冻结）", bench_moved, true)
	# —— P2 分幕建造：故事逐步加压 ——
	_check("建造前散布植被藏起（起手空地）", saw_scenery_hidden, true)
	_check("建造幕后散布植被显示（树木长出来）", saw_scenery_shown, true)
	_check("小伙伴逐个蹦出（见过中间态，非一次生齐）", saw_friends_partial, true)
	_check("小伙伴到齐峰值（= EXTRA_CHARS）", _max_bench, Benchmark.EXTRA_CHARS)
	_check("注魔期点点带镜头慢巡（focus_override 动过）", saw_camera_tour, true)
	# —— 定档收尾：就地应用 + 不换场景 ——
	_check("测完已定档（has_saved 转真）", GraphicsSettings.has_saved(), true)
	_check("档来源=bench（内嵌真定档，非骨架默认）", GraphicsSettings.source(), "bench")
	_check("没 change_scene：intro 场景仍在树", scene.is_inside_tree(), true)
	_check("解锁：世界恢复输入/仙子", bool(scene.get("_bench_freeze")), false)
	# —— 压测负载退场 + 保留 demo 占位村民 ——
	var bench_left := 0
	var demos := 0
	for n in (scene.get("npcs") as Array):
		var id := String((n as Dictionary).get("id", ""))
		if id.begins_with("bench_"):
			bench_left += 1
		elif id.begins_with("demo_"):
			demos += 1
	_check("压测负载测完退场（无 bench_ 残留）", bench_left, 0)
	_check("离线转正保留 demo 占位村民", demos >= 3, true)
	_check("编排器完成转正", done, true)
	_check("标记 intro_seen 保持", PlayerProfile.intro_seen(), true)
	if fails == 0:
		print("intro_benchmark tests PASS")
	else:
		printerr("intro_benchmark tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
		fails += 1
