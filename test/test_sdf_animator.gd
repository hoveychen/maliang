extends SceneTree
## SdfAnimator 程序化动画单测：步态/IK 完整性/不滑步、跳跃腾空与压扁、振翅。
## 不依赖引擎帧循环——手动 advance，全程确定性。
## 运行: godot --headless --path . --script res://test/test_sdf_animator.gd

const DT := 1.0 / 30.0

func _init() -> void:
	var fails := 0
	fails += _test_walker("res://assets/sdf_props/walking_hut.json", 4)
	fails += _test_walker("res://assets/sdf_props/sign_scout.json", 2)
	fails += _test_walker("res://assets/sdf_props/six_leg_chest.json", 6)
	fails += _test_hopper()
	fails += _test_flyer()
	if fails == 0:
		print("sdf_animator tests PASS")
	else:
		printerr("sdf_animator tests FAILED: %d" % fails)
	quit(fails)

func _test_walker(path: String, legs_expected: int) -> int:
	var fails := 0
	var tag := path.get_file()
	var prop := SdfProp.from_json_file(path)
	if prop == null:
		printerr("  FAIL %s load" % tag)
		return 1
	var anim: SdfAnimator = prop.animator
	var legs: Array = prop.meta.legs
	fails += _check("%s legs" % tag, legs.size(), legs_expected)

	var start_anchors: Array[Vector3] = []
	for f in anim._feet:
		start_anchors.append(f.anchor)

	var vel := Vector3(0, 0, 0.8)
	var prev_planted: Array[Vector3] = []
	var prev_t: Array[float] = []
	for f in anim._feet:
		prev_planted.append(f.anchor)
		prev_t.append(-1.0)
	var slide := 0
	var cross_group := 0
	var knee_break := 0
	var body_ys: Array[float] = []
	for i in range(120):
		prop.position += vel * DT
		anim.move_vel = vel
		anim.advance(DT)
		body_ys.append(prop.prims[prop.meta.body[0].idx].xform.origin.y)
		# 不滑步：连续两帧都着地的脚，锚点必须一动不动
		for li in range(legs.size()):
			var f: Dictionary = anim._feet[li]
			if f.t < 0.0 and prev_t[li] < 0.0:
				if (f.anchor as Vector3).distance_to(prev_planted[li]) > 1e-6:
					slide += 1
			prev_planted[li] = f.anchor
			prev_t[li] = f.t
		# 两组不同时腾空
		var stepping_groups := 0
		for g in anim._groups:
			for li in g:
				if anim._feet[li].t >= 0.0:
					stepping_groups += 1
					break
		if stepping_groups > 1:
			cross_group += 1
		# IK 完整性：大腿末端与小腿起点重合（膝盖不脱臼），骨长不变
		for leg in legs:
			var up: SdfMath.Prim = prop.prims[leg.upper]
			var lo: SdfMath.Prim = prop.prims[leg.lower]
			var up_end := up.xform * Vector3(0, up.params.y, 0)
			var lo_start := lo.xform * Vector3(0, -lo.params.z, 0)
			if up_end.distance_to(lo_start) > 1e-3:
				knee_break += 1
			if absf(up.params.y * 2.0 - leg.seg_len) > 1e-3:
				knee_break += 1
	fails += _check("%s no foot slide" % tag, slide, 0)
	fails += _check("%s groups alternate" % tag, cross_group, 0)
	fails += _check("%s knee intact" % tag, knee_break, 0)
	# 走了 3.2 米：每只脚都必须跟上来（锚点前移超过 2 米）
	var lagging := 0
	for li in range(legs.size()):
		if (anim._feet[li].anchor as Vector3).z - start_anchors[li].z < 2.0:
			lagging += 1
	fails += _check("%s feet keep up" % tag, lagging, 0)
	# 身体走动有颠簸
	fails += _check("%s body bobs" % tag, _spread(body_ys) > 0.005, true)
	prop.free()
	return fails

func _test_hopper() -> int:
	var fails := 0
	var prop := SdfProp.from_json_file("res://assets/sdf_props/hop_mailbox.json")
	if prop == null:
		return 1
	var anim: SdfAnimator = prop.animator
	var b0: Dictionary = prop.meta.body[1]  # 竖直胶囊身体
	var rest_y := (b0.rest as Transform3D).origin.y
	var rest_half: float = prop.prims[b0.idx].params.y
	var max_rise := 0.0
	var min_squash := 1.0
	var landed := false
	var airborne := false
	for i in range(150):
		anim.advance(DT)
		var rise: float = prop.prims[b0.idx].xform.origin.y - rest_y
		max_rise = maxf(max_rise, rise)
		min_squash = minf(min_squash, prop.prims[b0.idx].params.y / rest_half)
		if rise > 0.3:
			airborne = true
		if airborne and anim._hop_state == "idle":
			landed = true
	fails += _check("hopper leaves ground", max_rise > 0.3, true)
	fails += _check("hopper squashes", min_squash < 0.85, true)
	fails += _check("hopper lands back", landed, true)
	# 回到 idle 时恢复原尺寸
	while anim._hop_state != "idle":
		anim.advance(DT)
	anim.advance(DT)
	fails += _check("hopper size restored", absf(prop.prims[b0.idx].params.y / rest_half - 1.0) < 0.02, true)
	prop.free()
	return fails

func _test_flyer() -> int:
	var fails := 0
	var prop := SdfProp.from_json_file("res://assets/sdf_props/fly_lantern.json")
	if prop == null:
		return 1
	var anim: SdfAnimator = prop.animator
	var wing: Dictionary = prop.meta.wings[0]
	var wing_ys: Array[float] = []
	var body_ys: Array[float] = []
	for i in range(90):
		anim.move_vel = Vector3(0.3, 0, 0)
		anim.advance(DT)
		wing_ys.append(prop.prims[wing.idx].xform.origin.y)
		body_ys.append(prop.prims[prop.meta.body[0].idx].xform.origin.y)
	fails += _check("wings flap", _spread(wing_ys) > 0.05, true)
	fails += _check("body hovers", _spread(body_ys) > 0.02, true)
	# 有横向速度时身体倾侧（body basis 不再是单位阵）
	var b_prim: SdfMath.Prim = prop.prims[prop.meta.body[0].idx]
	var roll: float = (b_prim.xform.basis * Vector3.UP).x
	fails += _check("banks into motion", absf(roll) > 0.02, true)
	prop.free()
	return fails

func _spread(vals: Array[float]) -> float:
	var lo := 1e9
	var hi := -1e9
	for v in vals:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT:
		if absf(got - want) < 1e-3:
			return 0
	elif got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
