extends SceneTree
## benchmark 场景冒烟：world.benchmark_mode 下只搭渲染负载（不连后端 / 不开麦 / 不引导），
## 塞进 EXTRA_CHARS 个额外角色，跑完一次测量并 emit finished。
##
## 注意：headless 的帧时是假的（无 GPU、固定步长），所以这里只断言「接线跑通」——
## p95 的数值正确性由 test_frame_sampler 用构造序列验证，真机数值只能在真机看。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 30 \
##       --quit-after 400 --script res://test/test_benchmark_scene.gd

var scene: Node
var frame := 0
var fails := 0
var _backup: Dictionary
var _finished := false
var _got_levels: Dictionary
var _got_p95 := -1.0

func _initialize() -> void:
	_backup = PlayerProfile.load_profile()
	PlayerProfile.clear()
	Benchmark.pending = true
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame == 6:
		var bench: Node = scene.get_node_or_null("Benchmark")
		_check("benchmark 模式挂上 Benchmark 节点", bench != null, true)
		if bench != null:
			bench.finished.connect(_on_finished)
		_check("不连后端（无 Api 节点）", scene.get_node_or_null("Api") == null, true)
		var npcs: Array = scene.get("npcs")
		var bench_chars := 0
		var is_paper := true
		for n: Dictionary in npcs:
			if String(n.get("id", "")).begins_with("bench_"):
				bench_chars += 1
				if not (n["node"] is PaperCharacter):
					is_paper = false
		# 数 benchmark 角色本身，别数总数——npcs 里还有 3 个 demo NPC + 玩家
		_check("塞进 %d 个额外角色" % Benchmark.EXTRA_CHARS, bench_chars, Benchmark.EXTRA_CHARS)
		_check("benchmark 角色都是 PaperCharacter（走真实渲染路径）", is_paper, true)
		_check("测量期间解除限帧", Engine.max_fps, 0)
	elif frame == 380:
		_check("测量跑完并 emit finished", _finished, true)
		_check("出档含全部 9 个旋钮", _got_levels.size(), 9)
		_check("采到帧时（p95 > 0）", _got_p95 > 0.0, true)
		if _backup.is_empty():
			PlayerProfile.clear()
		else:
			PlayerProfile.save_profile(_backup)
		Benchmark.pending = false
		if fails == 0:
			print("benchmark_scene PASS")
		else:
			printerr("benchmark_scene FAILED: %d" % fails)
	elif frame == 384:
		quit(fails)

func _on_finished(levels: Dictionary, p95: float) -> void:
	_finished = true
	_got_levels = levels
	_got_p95 = p95

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
