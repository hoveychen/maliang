extends SceneTree
## C 档球端到端 derisk：在真实 world 实例里跑 stage_spawn_ball → 落位可见球节点 → host 每帧
## 推进滚动物理 → ball.reset 复位 → 收场移除。验证 world.gd 宿主路径（非 stage_agent mock），
## 只断言节点存在 + 逻辑坐标（数学），不看画面（headless 只验物理/状态机，真机手感=P3）。
##
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 80 --script res://test/test_stage_ball.gd

const START := Vector2(5.0, 137.0)  ## tile_center(2,68) 附近平地（同 test_mover 的可走角）

var scene: Node
var frame := 0
var fails := 0
var _spawn_result: Dictionary = {}
var _reset_result: Dictionary = {}
var _reset_called := false
var _rolled_x := 0.0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	match frame:
		1: root.size = Vector2i(640, 360)
		12: _spawn()
		14: _after_spawn()
		45: _after_roll()
		47: _reset()
		49: _after_reset()
		51: _finish_stage()
		53: _after_finish()

func _spawn() -> void:
	scene.call("stage_begin", [])  # 空 cast：球不依赖演员
	scene.call("stage_spawn_ball", "ball1", [START.x, START.y], func(ok: bool, r: Dictionary) -> void:
		if ok:
			_spawn_result = r)

func _after_spawn() -> void:
	_check("spawn 回执带 id", String(_spawn_result.get("id", "")), "ball1")
	var balls: Dictionary = scene.get("_stage_balls")
	_check("球已登记", balls.has("ball1"), true)
	var ball = balls.get("ball1")
	_check("球节点有效", ball != null and is_instance_valid(ball), true)
	if ball == null:
		return
	var lg: Vector2 = ball.body.logical
	_check("球落在请求位置", WorldGrid.shortest_delta(lg, START).length() < 0.2, true)
	ball.body.kick(Vector2(1, 0), 5.0)  # 朝东踢一脚，host 每帧 _step_balls 推进
	_check("踢后在滚", ball.body.is_rolling(), true)

func _after_roll() -> void:
	# 12→45 帧 @10fps ≈ 3.3s：球应已朝东滚了一段并摩擦停下（host 权威模拟）
	var ball = (scene.get("_stage_balls") as Dictionary).get("ball1")
	if ball == null:
		_check("滚动后球仍在", false, true)
		return
	_rolled_x = ball.body.logical.x
	_check("球朝东滚了（x 增大）", _rolled_x > START.x + 0.5, true)
	_check("球已摩擦停下", ball.body.is_rolling(), false)
	# 渲染坐标已被 _step_balls 更新为有限值（没 NaN / 没漂到天上）
	var node := ball as Node3D
	_check("渲染 y 有限且贴地", is_finite(node.position.y) and absf(node.position.y) < 1000.0, true)

func _reset() -> void:
	scene.call("stage_ball_reset", "ball1", [10.0, 137.0], func(ok: bool, _r: Dictionary) -> void:
		_reset_called = ok)

func _after_reset() -> void:
	_check("reset 回执", _reset_called, true)
	var ball = (scene.get("_stage_balls") as Dictionary).get("ball1")
	if ball == null:
		_check("reset 后球仍在", false, true)
		return
	_check("球复位到新点", WorldGrid.shortest_delta(ball.body.logical, Vector2(10.0, 137.0)).length() < 0.2, true)
	_check("复位清零速度", ball.body.velocity == Vector2.ZERO, true)

func _finish_stage() -> void:
	scene.call("stage_finish", {}, false, "")

func _after_finish() -> void:
	_check("收场清空球登记", (scene.get("_stage_balls") as Dictionary).is_empty(), true)
	_finish()

func _finish() -> void:
	for e in (scene.get("_executors") as Array):
		(e as BehaviorExecutor).cancel()  # 排干在途 A*（同 test_stage_staging，防关停崩）
	if fails == 0:
		print("stage_ball PASS")
	else:
		printerr("stage_ball FAILED: %d" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % what)
	else:
		printerr("  FAIL %s: got %s want %s" % [what, str(got), str(want)])
		fails += 1
