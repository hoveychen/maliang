extends SceneTree
## 回家过场输入锁 P4（home-portal-anim）：_homing 期间 _physics_process(方向键) 与 _unhandled_input(点击)
## 都吞掉，玩家只被 _step_home 脚本驱动，手动操控抢不了位。
## 先做控制组（不 homing 时方向键确实移动玩家）证明输入注入生效、断言有意义；再验锁上后不动。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 40 \
##       --script res://test/test_home_input_lock.gd

const HP_IDLE := 0  ## 须与 world.gd enum 一致（inert 阶段，_step_home 不驱动玩家）

var scene: Node
var frame := 0
var fails := 0
var pos_a: Vector2       ## 玩家出生点(必然可走,原点开阔区)——控制组从这里往右推
var locked_pos: Vector2

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(640, 480)
		scene.set("online", false)
		return
	if frame == 10:
		var p: Dictionary = scene.get("player")
		if p.is_empty():
			printerr("  ✗ 没有玩家节点"); fails += 1; _finish(); return
		pos_a = p["logical"]                  # 用出生点(可走,原点开阔区),别瞎选可能被挡的格
		scene.set("_homing", false)          # 控制组：不锁
		Input.action_press("ui_right")        # 按住右
		return
	if frame == 15:
		# 控制组断言：不锁时方向键确实把玩家推走了（证明注入生效，本测试能检出移动）
		var p: Dictionary = scene.get("player")
		var moved := WorldGrid.shortest_delta(pos_a, p["logical"]).length()
		_check("控制组:不锁时方向键推动了玩家", moved > 0.05, true)
		# 现在锁上，复位到 home_tile
		Input.action_release("ui_right")
		p["logical"] = pos_a
		p["paper_prev"] = pos_a
		scene.set("_homing", true)
		scene.set("_home_phase", HP_IDLE)     # inert：_step_home 不驱动，纯看输入锁
		locked_pos = pos_a
		Input.action_press("ui_right")        # 再按住右
		# 同时塞一个点击（左键按下），验 _unhandled_input 被 _homing 吞掉
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		ev.position = Vector2(500, 260)
		scene.call("_unhandled_input", ev)
		return
	if frame == 22:
		# 锁上后：方向键 + 点击都被吞，玩家纹丝不动
		var p: Dictionary = scene.get("player")
		var drift := WorldGrid.shortest_delta(locked_pos, p["logical"]).length()
		_check_near("锁上后方向键/点击被吞,玩家不动", drift, 0.0, 0.001)
		Input.action_release("ui_right")
		_finish()
		return

func _finish() -> void:
	print("home_input_lock ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	if is_instance_valid(scene):
		scene.queue_free()
	scene = null
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok ", name)
	else:
		printerr("  ✗ %s: got %s, want %s" % [name, got, want]); fails += 1

func _check_near(name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) <= tol:
		print("  ok ", name)
	else:
		printerr("  ✗ %s: got %f, want %f (±%f)" % [name, got, want, tol]); fails += 1
