extends SceneTree
## C 档球端到端 derisk：在真实 world 实例里跑 stage_spawn_ball → 落位可见球节点 → host 每帧
## 推进滚动物理 → ball.reset 复位 → 收场移除。P2c 追加：所有权路由（他端踢球→本端让出模拟、
## 从复制缓冲取位置；他端滚停→交回 host 中立、host 恢复物理模拟）。
## 只断言节点存在 + 逻辑坐标 + 所有权/缓冲状态（数学/状态机），不看画面，也不断言插值出的具体位置
## （headless 时钟非确定，插值/外推的数学由 test_ball_replication_buffer 覆盖）。真机手感=P3。
##
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 90 --script res://test/test_stage_ball.gd

const START := Vector2(5.0, 137.0)  ## tile_center(2,68) 附近平地（同 test_mover 的可走角）
const REMOTE := "remoteKid"          ## 模拟的他端玩家 id（离线本端 player_id 为空，二者必不相等）

var scene: Node
var frame := 0
var fails := 0
var _spawn_result: Dictionary = {}
var _reset_result: Dictionary = {}
var _reset_called := false
var _rolled_x := 0.0
var _resume_x := 0.0
var _resume_rolled := false

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
		51: _remote_kick()
		53: _after_remote_kick()
		55: _feed_replication()
		57: _after_replication()
		59: _remote_settle_and_resume()
		75: _after_resume()
		77: _finish_stage()
		79: _after_finish()
	# host 恢复模拟后踢的那脚，滚过 0.5 的时刻取决于 _step_balls 的推进节奏（headless 时钟非确定，
	# 见文件头注释）：轮询窗口内滚过即里程碑，不钉死在 frame 75，避免间歇性「还没滚够」假阴。
	if frame > 59 and not _resume_rolled:
		var b = (scene.get("_stage_balls") as Dictionary).get("ball1")
		if b != null and b.body.logical.x > _resume_x + 0.5:
			_resume_rolled = true

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
	_check("复位后仍中立（未经 FSM 踢击）", ball.own.is_neutral(), true)

## 他端踢球：owner 转给远端玩家 → 本端（host）让出模拟权、改从复制缓冲取位置。
func _remote_kick() -> void:
	var ball = (scene.get("_stage_balls") as Dictionary).get("ball1")
	if ball == null:
		_check("remote_kick 前球在", false, true)
		return
	var lg: Vector2 = ball.body.logical
	scene.call("_on_ball_kick", { "ballId": "ball1", "playerId": REMOTE,
		"x": lg.x, "y": lg.y, "vx": 6.0, "vy": 0.0, "t": Time.get_ticks_msec() })

func _after_remote_kick() -> void:
	var ball = (scene.get("_stage_balls") as Dictionary).get("ball1")
	if ball == null:
		_check("remote_kick 后球在", false, true)
		return
	_check("所有权转给他端", ball.own.owner(), REMOTE)
	_check("本端 host 让出模拟（非模拟者）", ball.own.simulates("", true), false)
	_check("踢击已播种复制缓冲", ball.buf.has_samples(), true)
	# 非模拟者渲染路径不崩：节点 y 仍有限贴地
	var node := ball as Node3D
	_check("非模拟者渲染 y 有限", is_finite(node.position.y) and absf(node.position.y) < 1000.0, true)

## 喂一条他端复制位置（模拟 positions_relay 里的球条目）：应进缓冲。
func _feed_replication() -> void:
	var ball = (scene.get("_stage_balls") as Dictionary).get("ball1")
	if ball == null:
		return
	var lg: Vector2 = ball.body.logical
	scene.call("_apply_ball_replicated", "ball1", Vector2(lg.x + 3.0, lg.y),
		Vector2(6.0, 0.0), Time.get_ticks_msec() + 200, Time.get_ticks_msec())

func _after_replication() -> void:
	var ball = (scene.get("_stage_balls") as Dictionary).get("ball1")
	if ball == null:
		return
	_check("复制样本已入缓冲", ball.buf.has_samples(), true)
	# 非模拟者身份下，_apply_ball_replicated 不该被自己权威忽略
	_check("非模拟者仍不模拟", ball.own.simulates("", true), false)

## 他端球滚停：owner 交回中立 → host 恢复模拟；随后本端 host 踢一脚验证物理确实又跑起来了。
func _remote_settle_and_resume() -> void:
	var ball = (scene.get("_stage_balls") as Dictionary).get("ball1")
	if ball == null:
		return
	var lg: Vector2 = ball.body.logical
	scene.call("_on_ball_settle", { "ballId": "ball1", "x": lg.x, "y": lg.y, "t": Time.get_ticks_msec() })
	_check("滚停后交回中立", ball.own.is_neutral(), true)
	_check("host 恢复模拟", ball.own.simulates("", true), true)
	# host 恢复模拟后踢一脚：_step_balls 应本地推进物理
	ball.body.place(TerrainMap.tile_center(Vector2i(2, 68)))
	_resume_x = ball.body.logical.x
	ball.body.kick(Vector2(1, 0), 5.0)

func _after_resume() -> void:
	var ball = (scene.get("_stage_balls") as Dictionary).get("ball1")
	if ball == null:
		return
	_check("host 恢复后球朝东滚动（物理重新生效）", _resume_rolled, true)

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
