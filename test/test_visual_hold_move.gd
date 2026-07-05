extends SceneTree
## 暗黑式按住跟随的行为验证：合成鼠标事件走 _unhandled_input 全链路——
## 按在空地立即开走（hold_follow 进入+落点标记）、按住拖动节流改道（目标跟随指针）、
## 松开停止重下发并走到最后目标；按在 NPC 上不进入跟随、松开仍是拾取近身。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 130 --script res://test/test_visual_hold_move.gd
## 退出码 = 失败断言数；已挂入 scripts/test-headless.sh。

const DT := 0.1  ## 与 --fixed-fps 10 对应

var scene: Node
var frame := 0
var fails := 0
var start_pos := Vector2.ZERO      ## 按下时玩家逻辑坐标
var first_target := Vector2.ZERO   ## 按下后首个下发目标
var drag_screen := Vector2.ZERO    ## 拖动后的指针屏幕位置
var final_target := Vector2.ZERO   ## 松开时锁定的最终目标

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		# headless 假视口 64×64，须先设成带窗尺寸（陷阱同 test_visual_click_move）
		root.size = Vector2i(1280, 720)
	match frame:
		10:
			_press_ground()
		14:
			_check_started_moving()
		15:
			_drag_pointer()
		19:
			_check_steered()
		20:
			_release_pointer()
		23:
			_check_no_more_reissue()
		70:
			_check_arrived()
			_press_npc()
		71:
			_release_npc()
		74:
			if fails == 0:
				print("visual_hold_move PASS")
			else:
				printerr("visual_hold_move FAILED: %d" % fails)
			quit(fails)

## 按在玩家东北方向空地上：应立即进入跟随并下发首个移动目标（方向避开 demo NPC）。
func _press_ground() -> void:
	var player: Dictionary = scene.get("player")
	start_pos = player["logical"]
	var sp := _screen_of(WorldGrid.wrap_pos(start_pos + Vector2(12.0, 8.0)), 0.2)
	_send_button(sp, true)
	_check("press enters hold follow", scene.get("_hold_follow"), true)
	var marker: Node = scene.get("_tap_marker")
	_check("press shows tap marker", marker != null and marker.get("visible") == true, true)
	first_target = scene.get("_tap_marker_logical")
	var expect: Vector2 = scene.call("_pick_ground", sp)
	_check("press target under pointer (d=%.2f)" % WorldGrid.shortest_delta(first_target, expect).length(),
		WorldGrid.shortest_delta(first_target, expect).length() <= 1.0, true)

func _check_started_moving() -> void:
	var player: Dictionary = scene.get("player")
	var moved := WorldGrid.shortest_delta(start_pos, player["logical"]).length()
	_check("player moves while held (moved=%.2f)" % moved, moved > 0.5, true)

## 按住不放、指针拖到玩家西侧：跟随应在节流间隔后把目标改到新指针下。
func _drag_pointer() -> void:
	var player: Dictionary = scene.get("player")
	drag_screen = _screen_of(WorldGrid.wrap_pos((player["logical"] as Vector2) + Vector2(-10.0, 6.0)), 0.2)
	_send_motion(drag_screen)
	_check("drag keeps hold follow", scene.get("_hold_follow"), true)

func _check_steered() -> void:
	var target: Vector2 = scene.get("_tap_marker_logical")
	var jump := WorldGrid.shortest_delta(first_target, target).length()
	_check("steer reissues target (jump=%.2f)" % jump, jump > 5.0, true)
	# 相机随玩家移动，指针下地面点逐帧漂移；对当前帧重拾取给 3.0 容差
	var expect: Vector2 = scene.call("_pick_ground", drag_screen)
	var d := WorldGrid.shortest_delta(target, expect).length()
	_check("steered target under pointer (d=%.2f)" % d, d <= 3.0, true)

func _release_pointer() -> void:
	_send_button(drag_screen, false)
	_check("release exits hold follow", scene.get("_hold_follow"), false)
	final_target = scene.get("_tap_marker_logical")

func _check_no_more_reissue() -> void:
	var target: Vector2 = scene.get("_tap_marker_logical")
	_check("no reissue after release", WorldGrid.shortest_delta(target, final_target).length() <= 0.01, true)

func _check_arrived() -> void:
	var player: Dictionary = scene.get("player")
	var dist := WorldGrid.shortest_delta(player["logical"], final_target).length()
	# 到达半径 + 拾取离散误差，同 test_visual_click_move 放宽到 2.0
	_check("player stops at release target (dist=%.2f)" % dist, dist <= 2.0, true)

## 按在最近的 NPC 上：不得进入跟随；松开走原拾取链路（叫停+近身）。
func _press_npc() -> void:
	var npcs: Array = scene.get("npcs")
	var player: Dictionary = scene.get("player")
	var best_d := 1e9
	var best: Dictionary = {}
	for n in npcs:
		var d := WorldGrid.shortest_delta(player["logical"], n["logical"]).length()
		if d < best_d:
			best_d = d
			best = n
	if best.is_empty():
		fails += 1
		printerr("  FAIL no npc to press")
		return
	drag_screen = _screen_of(best["logical"], 1.6)
	_send_button(drag_screen, true)
	_check("press on npc skips hold follow", scene.get("_hold_follow"), false)

func _release_npc() -> void:
	_send_button(drag_screen, false)
	# 松开当帧断言：远则开始跑向（_approach 非空），近则可能已直接进入交互（selected 非空）
	var approaching := not (scene.get("_approach") as Dictionary).is_empty()
	var interacting: bool = scene.get("selected") != null
	_check("npc tap still approaches/interacts", approaching or interacting, true)

func _send_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	scene.call("_unhandled_input", ev)

func _send_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev.position = pos
	scene.call("_unhandled_input", ev)

## 逻辑坐标 → 屏幕坐标（与 world 同一弯曲/台阶公式，同 test_visual_click_move）。
func _screen_of(logical: Vector2, y_off: float) -> Vector2:
	var focus: Vector2 = scene.get("focus_logical")
	var cam: Camera3D = scene.get("camera")
	var d := WorldGrid.shortest_delta(focus, logical)
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(logical))) * TerrainMap.STEP_HEIGHT
	var drop := BendMat.CURVATURE * (d.x * d.x + d.y * d.y)
	return cam.unproject_position(Vector3(d.x, ty + y_off - drop, d.y))

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
