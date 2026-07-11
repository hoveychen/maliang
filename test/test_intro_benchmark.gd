extends SceneTree
## P5：intro 内嵌 benchmark 段的编排机制（设计 D5）。无画质档 + 已看过引导（intro_seen=true 隔离掉教学段）
## → 建造演出跑到注魔段时 add_child 一个 embedded Benchmark：冻结世界、塞 12 个村民雏形压测负载、跑贪心
## 定档，测完就地应用 levels + save_all(source=bench)、压测负载退场、解冻，intro 继续到转正。
##
## ⚠️ headless 帧时是假的（--fixed-fps 60 → 每帧恒 16.7ms ≤ 33.3ms 达标线 → 基线即达标、零试降、一次
## 测量收工）。所以本测只验【编排机制】：Benchmark 挂上→定档→就地应用了档、没 change_scene、压测负载
## spawn 后 despawn、世界冻结过又解冻、intro 继续到底。真机定档效果（哪个旋钮真省 ms、贪心总耗时、12
## 负载够不够）只能在真机抓 BENCH 日志验，是 P6 头号项——本测不声称验证了帧时/定档正确性。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 60 --quit-after 3600 \
##       --script res://test/test_intro_benchmark.gd

var scene: Node
var frame := 0
var fails := 0
var done := false
var saw_bench_node := false      ## 采样期 Benchmark 节点挂上过
var saw_bench_load := false      ## 采样期见到过 bench_ 压测角色
var saw_freeze := false          ## 采样期世界被冻结过

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
	# 采样期锁存观测（benchmark 结束会解冻/退场，只能在窗口内抓）
	if scene.get_node_or_null("IntroDirector/Benchmark") != null:
		saw_bench_node = true
	if bool(scene.get("_bench_freeze")):
		saw_freeze = true
	for n in (scene.get("npcs") as Array):
		if String((n as Dictionary).get("id", "")).begins_with("bench_"):
			saw_bench_load = true
			break
	var intro: Node = scene.get("_intro")
	if intro != null and bool(intro.call("is_done")):
		done = true
		_finish()

func _finish() -> void:
	# —— 采样期机制 ——
	_check("采样期挂上 Benchmark 节点", saw_bench_node, true)
	_check("采样期塞进压测负载（bench_ 村民雏形）", saw_bench_load, true)
	_check("采样期世界被冻结（可复现帧）", saw_freeze, true)
	# —— 定档收尾：就地应用 + 不换场景 ——
	_check("测完已定档（has_saved 转真）", GraphicsSettings.has_saved(), true)
	_check("档来源=bench（内嵌真定档，非骨架默认）", GraphicsSettings.source(), "bench")
	_check("没 change_scene：intro 场景仍在树", scene.is_inside_tree(), true)
	_check("解冻：世界恢复动态", bool(scene.get("_bench_freeze")), false)
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
