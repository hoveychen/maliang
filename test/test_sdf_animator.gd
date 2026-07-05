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
	fails += _test_ropes()
	fails += _test_wander()
	fails += _test_spinner()
	fails += _test_quiet_flower()
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

func _test_ropes() -> int:
	var fails := 0
	var prop := SdfProp.from_json_file("res://assets/sdf_props/walking_hut.json")
	if prop == null:
		return 1
	var anim: SdfAnimator = prop.animator
	var rope: Dictionary = prop.meta.ropes[0]
	var seg_len: float = rope.seg_len

	# 静置 3 秒：段长守恒 + 锚点钉在身体上
	for i in range(90):
		anim.advance(DT)
	var pts: PackedVector3Array = anim._rope_pts[0]
	var bad_len := 0
	for k in range(pts.size() - 1):
		if absf(pts[k].distance_to(pts[k + 1]) - seg_len) > 0.02:
			bad_len += 1
	fails += _check("rope segs keep length", bad_len, 0)
	var anchor_now: Vector3 = prop.transform * (anim._body_delta_xf() * (rope.anchor as Vector3))
	fails += _check("rope pinned to body", pts[0].distance_to(anchor_now) < 1e-4, true)

	# 快速平移 1 秒：尾端应甩起来（相对锚点的水平偏移显著变化）
	var max_sway := 0.0
	for i in range(30):
		prop.position += Vector3(2.0, 0, 0) * DT
		anim.advance(DT)
		var p: PackedVector3Array = anim._rope_pts[0]
		var tip_rel := p[p.size() - 1] - p[0]
		max_sway = maxf(max_sway, absf(tip_rel.x))
	fails += _check("rope swings when moving", max_sway > 0.08, true)

	# 停下再静置：尾端回到锚点近乎正下方（微风扰动容差）
	for i in range(240):
		anim.advance(DT)
	var p2: PackedVector3Array = anim._rope_pts[0]
	var rel := p2[p2.size() - 1] - p2[0]
	fails += _check("rope settles under anchor", Vector2(rel.x, rel.z).length() < 0.12, true)

	# 绳段基本体确实被摆到点之间（物件空间端点重合）
	var inv := prop.transform.affine_inverse()
	var bad_seg := 0
	for k in range(int(rope.count)):
		var pr: SdfMath.Prim = prop.prims[int(rope.start) + k]
		var a := pr.xform * Vector3(0, -pr.params.z, 0)
		# 容差与段长约束残差同级（params.z 是静止段长的一半，运行时长度有 ±0.02 漂移）
		if a.distance_to(inv * p2[k]) > 0.02:
			bad_seg += 1
	fails += _check("rope prims follow points", bad_seg, 0)
	prop.free()
	return fails

func _test_wander() -> int:
	var fails := 0
	# walker 游走：始终在半径内，且确实动了
	var hut := SdfProp.from_json_file("res://assets/sdf_props/walking_hut.json")
	hut.position = Vector3(4, 0, -6)
	hut.enable_wander(1.6, 42)
	var center := hut.position
	var max_dist := 0.0
	var moved := 0.0
	var prev := hut.position
	for i in range(600):
		hut._wander_step(DT)
		hut.animator.advance(DT)
		max_dist = maxf(max_dist, (hut.position - center).length())
		moved += (hut.position - prev).length()
		prev = hut.position
	fails += _check("wander stays in radius", max_dist < 1.6 + 0.3, true)
	fails += _check("wander actually moves", moved > 1.0, true)
	hut.free()

	# hopper 游走：只在腾空段平移
	var box := SdfProp.from_json_file("res://assets/sdf_props/hop_mailbox.json")
	box.enable_wander(1.2, 7)
	var ground_shift := 0
	prev = box.position
	for i in range(600):
		# 位移闸门看的是 _wander_step 执行时的状态，采样要在 advance 之前
		var was_air: bool = box.animator._hop_state == "air"
		box._wander_step(DT)
		box.animator.advance(DT)
		if not was_air and (box.position - prev).length() > 1e-6:
			ground_shift += 1
		prev = box.position
	fails += _check("hopper moves only airborne", ground_shift, 0)
	box.free()
	return fails

func _test_spinner() -> int:
	var fails := 0
	var pw := SdfProp.from_json_file("res://assets/sdf_props/pinwheel.json")
	if pw == null:
		printerr("  FAIL pinwheel load")
		return 1
	# 叶片 = 带 spin 的 body 件
	var blade_idx: Array[int] = []
	for b in pw.meta.body:
		if not (b.spin as Dictionary).is_empty():
			blade_idx.append(b.idx)
	fails += _check("pinwheel 4 spinning blades", blade_idx.size(), 4)

	var start: Array[Vector3] = []
	for bi in blade_idx:
		start.append((pw.prims[bi] as SdfMath.Prim).xform.origin)
	var d0 := start[0].distance_to(start[1])  # 刚性判定基准
	for i in range(15):  # 0.5s：rate 0.55 → 约 1/4 圈
		pw.animator.advance(DT)
	var moved := 0
	var rigid_break := 0
	var now: Array[Vector3] = []
	for k in range(blade_idx.size()):
		var o := (pw.prims[blade_idx[k]] as SdfMath.Prim).xform.origin
		now.append(o)
		if o.distance_to(start[k]) > 0.1:
			moved += 1
	for k in range(now.size() - 1):
		if absf(now[k].distance_to(now[k + 1]) - d0) > 5e-3:
			rigid_break += 1
	fails += _check("blades orbit", moved, 4)
	fails += _check("blades stay rigid", rigid_break, 0)
	# 杆不转：非 spin 件 xz 不动（只受呼吸的 y 影响）
	var pole := (pw.prims[0] as SdfMath.Prim).xform.origin
	fails += _check("pole stays put (xz)", Vector2(pole.x, pole.z).length() < 1e-3, true)
	pw.free()

	# spec 解析：数字简写归一化 + 零轴拒收
	var short := SdfSpec.parse({
		"palette": ["#fff"],
		"parts": [{"shape": "sphere", "pos": [0, 1, 0], "r": 0.2, "spin": 1.5}],
	})
	fails += _check("spin shorthand ok", short.ok, true)
	if short.ok:
		var sp: Dictionary = short.parts[0].spin
		fails += _check("spin shorthand rate", sp.rate, 1.5)
		fails += _check("spin shorthand pivot", (sp.pivot as Vector3).distance_to(Vector3(0, 1, 0)) < 1e-4, true)
	var zero_axis := SdfSpec.parse({
		"palette": ["#fff"],
		"parts": [{"shape": "sphere", "pos": [0, 1, 0], "r": 0.2, "spin": {"axis": [0, 0, 0]}}],
	})
	fails += _check("reject zero spin axis", zero_axis.ok, false)
	return fails

func _test_quiet_flower() -> int:
	var fails := 0
	var fl := SdfProp.from_json_file("res://assets/sdf_props/nodding_flower.json")
	if fl == null:
		printerr("  FAIL flower load")
		return 1
	fails += _check("flower no legs", fl.meta.legs.size(), 0)
	var stem := fl.prims[0] as SdfMath.Prim
	var petal := fl.prims[4] as SdfMath.Prim
	var stem0 := stem.xform.origin
	var sway := 0.0
	for i in range(90):  # 3s 待机
		fl.animator.advance(DT)
		sway = maxf(sway, Vector2(petal.xform.origin.x - 0.2, petal.xform.origin.z + 0.02).length())
	# 茎（body 组）xz 纹丝不动，花头（head 组）在摇
	var stem_now := stem.xform.origin
	fails += _check("stem xz still", Vector2(stem_now.x - stem0.x, stem_now.z - stem0.z).length() < 1e-4, true)
	fails += _check("flower head sways", sway > 0.03, true)
	fl.free()
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
