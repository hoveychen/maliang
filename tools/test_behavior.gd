extends SceneTree
## BehaviorExecutor 独立测试。
## 运行: Godot --headless --path . --script res://tools/test_behavior.gd

func _init() -> void:
	var fails := 0
	var span := WorldGrid.WORLD_SPAN
	# 角色起点接近接缝 (span-10, 0)，命令去 world(10, 0) → 最短路跨接缝（+20），终点 x≈10
	var target := { "logical": Vector2(span - 10.0, 0.0) }
	var ex := BehaviorExecutor.new()
	ex.setup(target, { "commands": [{ "type": "move_to", "params": { "target": [10.0, 0.0] } }], "loop": false })
	var steps := 0
	while not ex.is_done() and steps < 2000:
		ex.step(0.1)
		steps += 1
	var pos: Vector2 = target["logical"]
	var d := WorldGrid.shortest_delta(pos, Vector2(10.0, 0.0))
	fails += _check("到达目标(跨接缝)", d.length() < 2.0)
	fails += _check("终点在接缝另一侧(x≈10 而非绕远)", pos.x < 14.0)
	fails += _check("完成", ex.is_done())

	# wait 命令推进
	var t2 := { "logical": Vector2(0, 0) }
	var ex2 := BehaviorExecutor.new()
	ex2.setup(t2, { "commands": [{ "type": "wait", "params": { "duration": 0.5 } }], "loop": false })
	var s2 := 0
	while not ex2.is_done() and s2 < 100:
		ex2.step(0.1)
		s2 += 1
	fails += _check("wait 后完成", ex2.is_done())

	if fails == 0:
		print("behavior tests PASS (4/4)")
	else:
		printerr("behavior tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, ok: bool) -> int:
	if ok:
		return 0
	printerr("  FAIL %s" % name)
	return 1
