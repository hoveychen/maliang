extends SceneTree
## 平板双指手势临时视角的行为验证：合成 ScreenTouch/ScreenDrag 走 _unhandled_input 全链路——
## 第二指落下接管（取消按住跟随、抬指不拾取）、捏合张开拉近距离、双指位移改环绕角+俯仰、
## 松手 5s 无操作后偏移自动复原（相机回默认正北视角）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 160 --script res://test/test_visual_camera_gesture.gd
## 退出码 = 失败断言数；已挂入 scripts/test-headless.sh。

const DT := 0.1  ## 与 --fixed-fps 10 对应

var scene: Node
var frame := 0
var fails := 0
var sp := Vector2.ZERO  ## 第一指按下的屏幕坐标（玩家旁空地），后续手指/拖动都相对它摆

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720) # headless 假视口 64×64，须先设成带窗尺寸
	match frame:
		10:
			_press_one_finger_then_second()
		12:
			_pinch_out()
		14:
			_check_zoomed_in()
			_pan_two_fingers()
		16:
			_check_orbited()
		18:
			_release_all()
		20:
			_check_reset_armed()
		60: # 松手 4.2s：倒计时未到，偏移仍在
			_check_still_offset()
		90: # 松手 7.2s：5s 倒计时已过 + 缓动收敛，应已复原
			_check_restored()
		95:
			if fails == 0:
				print("visual_camera_gesture PASS")
			else:
				printerr("visual_camera_gesture FAILED: %d" % fails)
			quit(fails)

## 单指按在空地进入按住跟随，第二指落下应立即接管：跟随取消、进入手势态。
func _press_one_finger_then_second() -> void:
	var player: Dictionary = scene.get("player")
	sp = _screen_of(WorldGrid.wrap_pos((player["logical"] as Vector2) + Vector2(-12.0, 8.0)), 0.2)
	_send_touch(0, sp, true)
	_check("first finger enters hold follow", scene.get("_hold_follow"), true)
	_send_touch(1, sp + Vector2(200.0, 0.0), true)
	_check("second finger begins gesture", scene.get("_gesturing"), true)
	_check("gesture cancels hold follow", scene.get("_hold_follow"), false)
	_check("gesture cancels pending player move", scene.get("_player_executor") == null, true)

## 捏合张开（两指间距 200→400px）：距离倍率应减半（拉近）。
func _pinch_out() -> void:
	_send_drag(0, sp + Vector2(-100.0, 0.0))
	_send_drag(1, sp + Vector2(300.0, 0.0))
	var zt := float(scene.get("_gest_zoom_t"))
	_check("pinch out halves zoom target (zt=%.2f)" % zt, absf(zt - 0.5) < 0.05, true)

func _check_zoomed_in() -> void:
	var z := float(scene.get("_gest_zoom"))
	_check("zoom eases toward target (z=%.2f)" % z, z < 0.95, true)

## 双指同向位移（各右移 200px、下移 100px）：环绕角+俯仰目标应随之变化。
## 每指各收到一次 drag、各贡献中点位移的一半：合计 yaw += 200*0.5*SENS、pitch += 100*0.5*SENS。
func _pan_two_fingers() -> void:
	_send_drag(0, sp + Vector2(100.0, 100.0))
	_send_drag(1, sp + Vector2(500.0, 100.0))
	var yt := float(scene.get("_gest_yaw_t"))
	var pt := float(scene.get("_gest_pitch_t"))
	_check("pan yaws camera target (yt=%.2f)" % yt, yt > 0.5, true)
	_check("pan tilts pitch target (pt=%.1f)" % pt, pt > 5.0, true)

func _check_orbited() -> void:
	var cam: Camera3D = scene.get("camera")
	# 默认视角相机永远在焦点正北（x=0）；环绕后 x 分量应明显偏离 0
	_check("camera orbits off north axis (x=%.2f)" % cam.global_position.x, absf(cam.global_position.x) > 2.0, true)

func _release_all() -> void:
	_send_touch(0, sp + Vector2(100.0, 100.0), false)
	_send_touch(1, sp + Vector2(500.0, 100.0), false)
	_check("all fingers up ends gesture", scene.get("_gesturing"), false)
	_check("release does not pick/approach", scene.get("selected") == null and (scene.get("_approach") as Dictionary).is_empty(), true)

func _check_reset_armed() -> void:
	var rt := float(scene.get("_gest_reset_t"))
	_check("reset countdown armed (rt=%.1f)" % rt, rt > 3.5 and rt <= 5.0, true)

func _check_still_offset() -> void:
	var yaw := float(scene.get("_gest_yaw"))
	_check("offset holds before 5s (yaw=%.2f)" % yaw, absf(yaw) > 0.3, true)

func _check_restored() -> void:
	var yaw := float(scene.get("_gest_yaw"))
	var pitch := float(scene.get("_gest_pitch"))
	var zoom := float(scene.get("_gest_zoom"))
	_check("yaw restored (yaw=%.3f)" % yaw, absf(yaw) < 0.03, true)
	_check("pitch restored (pitch=%.2f)" % pitch, absf(pitch) < 0.5, true)
	_check("zoom restored (zoom=%.3f)" % zoom, absf(zoom - 1.0) < 0.03, true)
	var cam: Camera3D = scene.get("camera")
	_check("camera back on north axis (x=%.2f)" % cam.global_position.x, absf(cam.global_position.x) < 0.5, true)

func _send_touch(index: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = pressed
	scene.call("_unhandled_input", ev)

func _send_drag(index: int, pos: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	scene.call("_unhandled_input", ev)

## 逻辑坐标 → 屏幕坐标（与 world 同一弯曲/台阶公式，同 test_visual_hold_move）。
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
	printerr("  FAIL %s: got %s want %s" % [str(name), str(got), str(want)])
