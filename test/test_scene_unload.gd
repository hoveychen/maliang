extends SceneTree
## 切场景卸旧时，必须先 cancel 每个 BehaviorExecutor 再丢弃它们。
##
## 为什么要守这条：执行器把 A* 寻路派给 WorkerThreadPool，任务的绑定 Callable 里
## 攥着 GDScript 对象。cancel() 会把在途任务转成孤儿交给集中回收；直接 _executors.clear()
## 则任务既没转孤儿也没人 wait，引擎关停时 WorkerThreadPool 析构那个 Callable，
## GDScript 语言早已卸载 → 崩（回测 exit 134/139，真机退出也崩）。
## 这正是 test_visual_portal 一进传送点就在退出期崩溃的成因。
##
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_scene_unload.gd

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(640, 360)
		return
	if frame != 10:
		return

	# 塞一个活执行器进世界的执行器表，再走卸旧路径——它必须被 cancel。
	var ex := BehaviorExecutor.new()
	var executors: Array = scene.get("_executors")
	executors.append(ex)
	_check("注入前执行器未收工", ex.is_done(), false)

	scene.call("_unload_scene")

	_check("卸旧后执行器表清空", (scene.get("_executors") as Array).size(), 0)
	_check("卸旧必须 cancel 执行器（否则在途寻路任务泄漏，退出期崩）", ex.is_done(), true)

	if fails == 0:
		print("scene_unload PASS")
	else:
		printerr("scene_unload FAILED: %d" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % what)
	else:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1
