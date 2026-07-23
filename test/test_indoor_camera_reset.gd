extends SceneTree
## 室内→室外相机回正（home-interior 相机 bug）：进室内把相机俯角/距离设成 INDOOR 收束值，
## 出室内必须把它们复位到室外默认 GOD 值——否则出屋后镜头卡在室内的陡俯角+远距离，
## 「摄像头位置不对」。之前只有对话退出(_exit_interaction)会复位，纯走 portal 出门不复位。
##
## 直接对 World 实例调 _apply_indoor_render（不入树 → 不触发 _ready 全量 boot；chunk_manager/
## room_stage 为 null 被内部守卫跳过，只跑相机分支）。
## 运行: godot --headless --path . --script res://test/test_indoor_camera_reset.gd
const World := preload("res://scripts/world.gd")

func _init() -> void:
	var fails := 0
	var w := World.new()

	# 进室内：相机切到 INDOOR 俯角 + 按房间尺寸算出的框满距离（非写死），focus 钉房间中心。
	w._apply_indoor_render("home_interior")
	var want_dist := w._indoor_cam_dist_for(World.room_n_for("home_interior"))
	fails += _check("进室内俯角=INDOOR", w._target_pitch, World.INDOOR_CAM_PITCH)
	fails += _check("进室内距离=按尺寸框满", w._target_dist, want_dist)
	fails += _check("室内距离>0（真算出来了）", w._indoor_cam_dist > 0.0, true)

	# 出室内（走 portal 回村，非对话退出）：必须复位到室外默认，否则镜头卡在室内视角。
	w._apply_indoor_render("village_forest")
	fails += _check("出室内俯角复位=GOD", w._target_pitch, World.GOD_PITCH_DEG)
	fails += _check("出室内距离复位=GOD", w._target_dist, World.GOD_DIST)

	w.free()
	print("test_indoor_camera_reset: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if is_equal_approx(float(got), float(want)):
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
