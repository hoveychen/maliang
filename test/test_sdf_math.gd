extends SceneTree
## SdfMath / SdfMeshBuilder 的独立单测。
## 运行: godot --headless --path . --script res://test/test_sdf_math.gd

func _init() -> void:
	var fails := 0

	# ---- 基本体距离场：解析已知值 ----
	var sph := SdfMath.sphere(Vector3.ZERO, 0.5)
	fails += _check("sphere center", SdfMath.prim_dist(sph, Vector3.ZERO), -0.5)
	fails += _check("sphere surface", SdfMath.prim_dist(sph, Vector3(0.5, 0, 0)), 0.0)
	fails += _check("sphere outside", SdfMath.prim_dist(sph, Vector3(1.5, 0, 0)), 1.0)

	var sph_moved := SdfMath.sphere(Vector3(1, 2, 3), 0.5)
	fails += _check("moved sphere center", SdfMath.prim_dist(sph_moved, Vector3(1, 2, 3)), -0.5)

	var cap := SdfMath.capsule(Transform3D.IDENTITY, 0.3, 0.6)
	fails += _check("capsule mid side", SdfMath.prim_dist(cap, Vector3(1.3, 0, 0)), 1.0)
	fails += _check("capsule above tip", SdfMath.prim_dist(cap, Vector3(0, 0.6 + 0.3 + 1.0, 0)), 1.0)
	fails += _check("capsule inside", SdfMath.prim_dist(cap, Vector3(0, 0.4, 0)), -0.3)

	# 胶囊旋转 90° 到 X 轴：轴向端点距离不变
	var rot := Transform3D(Basis(Vector3(0, 0, 1), PI / 2.0), Vector3.ZERO)
	var cap_x := SdfMath.capsule(rot, 0.3, 0.6, Color.WHITE, 0.25)
	fails += _check("rotated capsule tip", SdfMath.prim_dist(cap_x, Vector3(-(0.6 + 0.3 + 1.0), 0, 0)), 1.0)

	var cone := SdfMath.cone(Transform3D.IDENTITY, 0.5, 0.2, 1.0)
	fails += _check("cone bottom sphere center", SdfMath.prim_dist(cone, Vector3(0, -1, 0)), -0.5)
	fails += _check("cone above top", SdfMath.prim_dist(cone, Vector3(0, 1.0 + 0.2 + 1.0, 0)), 1.0)
	fails += _check("cone below bottom", SdfMath.prim_dist(cone, Vector3(0, -(1.0 + 0.5 + 1.0), 0)), 1.0)

	var bx := SdfMath.box(Transform3D.IDENTITY, Vector3(1.0, 0.5, 0.5))
	fails += _check("box face +x", SdfMath.prim_dist(bx, Vector3(2.0, 0, 0)), 1.0)
	fails += _check("box inside", SdfMath.prim_dist(bx, Vector3.ZERO) < 0.0, true)

	# ---- smooth-min ----
	fails += _check("smin far = min", SdfMath.smin(1.0, 5.0, 0.3), 1.0)
	fails += _check("smin symmetric", SdfMath.smin(0.2, 0.3, 0.3), SdfMath.smin(0.3, 0.2, 0.3))
	fails += _check("smin overlap < min", SdfMath.smin(0.2, 0.25, 0.3) < 0.2, true)
	fails += _check("smin k=0 = min", SdfMath.smin(0.2, 0.25, 0.0), 0.2)

	# ---- 融合场：两球相交，中点在联合体内部 ----
	var pair: Array = [
		SdfMath.sphere(Vector3(-0.4, 0, 0), 0.5),
		SdfMath.sphere(Vector3(0.4, 0, 0), 0.5),
	]
	fails += _check("union midpoint inside", SdfMath.eval(pair, Vector3.ZERO, 0.25) < 0.0, true)
	# 融合面高于单球 min：颈部被 smin 填出来（表面点在单球场里为正）
	var neck := SdfMath.project(pair, Vector3(0, 0.55, 0), 0.25)
	fails += _check("neck filled above spheres", SdfMath.prim_dist(pair[0], neck) > 0.0, true)

	# blend 上限：细天线 blend≈0 时不被大球吞——远处场值等于纯 min
	var thin: Array = [
		SdfMath.sphere(Vector3.ZERO, 0.5),
		SdfMath.capsule(Transform3D(Basis.IDENTITY, Vector3(0, 0.9, 0)), 0.03, 0.35, Color.WHITE, 0.001),
	]
	var p_near := Vector3(0.1, 0.62, 0)
	var d_min := minf(SdfMath.prim_dist(thin[0], p_near), SdfMath.prim_dist(thin[1], p_near))
	fails += _check("thin part keeps min field", absf(SdfMath.eval(thin, p_near, 0.3) - d_min) < 1e-4, true)

	# ---- 梯度：球面外一点的梯度 ≈ 径向单位向量 ----
	var g := SdfMath.gradient([sph], Vector3(2, 0, 0), 0.25).normalized()
	fails += _check("gradient radial", g.distance_to(Vector3(1, 0, 0)) < 0.02, true)

	# ---- 投影收敛：绕两球融合区一圈取 12 个起点，投影后 |d| < 2e-3 ----
	var worst := 0.0
	for i in range(12):
		var a := TAU * float(i) / 12.0
		var start := Vector3(cos(a) * 0.9, sin(a) * 0.9, 0.3)
		var on := SdfMath.project(pair, start, 0.25)
		worst = maxf(worst, absf(SdfMath.eval(pair, on, 0.25)))
	fails += _check("projection converges", worst < 2e-3, true)

	# 皮下投影（iso<0）：埋没顶点收皮用
	var under := SdfMath.project(pair, Vector3(0.9, 0.2, 0), 0.25, -0.05)
	fails += _check("sub-surface iso", absf(SdfMath.eval(pair, under, 0.25) + 0.05) < 2e-3, true)

	# ---- 网格构建 ----
	var prims: Array = [
		SdfMath.sphere(Vector3(0, 0.8, 0), 0.35),
		SdfMath.capsule(Transform3D.IDENTITY, 0.25, 0.4),
		SdfMath.cone(Transform3D(Basis.IDENTITY, Vector3(0.5, 0, 0)), 0.3, 0.1, 0.4),
		SdfMath.box(Transform3D(Basis.IDENTITY, Vector3(-0.6, 0, 0)), Vector3(0.2, 0.3, 0.2)),
	]
	var mesh := SdfMeshBuilder.build(prims)
	fails += _check("single surface", mesh.get_surface_count(), 1)
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uv2s: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	fails += _check("has verts", verts.size() > 0, true)
	fails += _check("uv2 per vert", uv2s.size(), verts.size())
	fails += _check("indices triangles", idx.size() % 3, 0)
	var seen := {}
	var bad_ref := 0
	for j in range(uv2s.size()):
		var pi := int(uv2s[j].x + 0.5)
		if pi < 0 or pi >= prims.size():
			bad_ref += 1
		seen[pi] = true
	fails += _check("uv2 index in range", bad_ref, 0)
	fails += _check("all prims present", seen.size(), prims.size())
	# 三角形不跨基本体：同一三角形三个顶点的 UV2 索引一致
	var cross := 0
	for j in range(0, idx.size(), 3):
		var a0 := int(uv2s[idx[j]].x + 0.5)
		if int(uv2s[idx[j + 1]].x + 0.5) != a0 or int(uv2s[idx[j + 2]].x + 0.5) != a0:
			cross += 1
	fails += _check("no cross-prim triangle", cross, 0)
	# 自定义 AABB 覆盖所有基本体中心
	var aabb := mesh.custom_aabb
	var uncovered := 0
	for pr: SdfMath.Prim in prims:
		if not aabb.has_point(pr.xform.origin):
			uncovered += 1
	fails += _check("custom aabb covers prims", uncovered, 0)

	if fails == 0:
		print("sdf_math tests PASS")
	else:
		printerr("sdf_math tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT:
		if absf(got - want) < 1e-3:
			return 0
	elif got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
