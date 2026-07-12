class_name SdfMeshBuilder
extends RefCounted
## 把一组 SDF 基本体的"壳网格"合并成单 surface 的 ArrayMesh（一次 draw call）。
## 顶点存基本体**局部**坐标（动画只改 uniform 里的基本体变换，不重建网格），
## UV2.x 记基本体索引；真实表面位置由 sdf_blend_shell.gdshader 顶点阶段
## 先按当前基本体变换摆到物件空间、再吸附到 smooth-min SDF 表面得到。
## 壳网格只要"拓扑合理、顶点够密、离目标面不远"即可，吸附会修正形状——
## 所以圆头锥直接用胶囊壳按半径插值搓出来，不必精确。

## 细分档位：跟 paper_character 的 6×12 一个量级，单件角色约 2~5k 顶点。
## density 缩放段数（下限保轮廓不塌）：可动物件用 1.0（逐帧吸附要够密）；
## 静态烘焙布景用低档——SDF 的圆润来自梯度法线（法线插值与网格密度无关），
## 密度只影响轮廓圆滑度，god 视角一棵树百来像素，8~10 段轮廓足够。
const SPHERE_SEGS := 24
const SPHERE_RINGS := 16
const CAPSULE_SEGS := 20
const CAPSULE_RINGS := 12
const BOX_SUBDIV := 6
const TUBE_RADIAL := 10   ## 环面/弯管圆截面段数
const TORUS_ALONG := 32   ## 满环沿环方向段数（按弧比例缩）
const BEZIER_ALONG := 18  ## 弯管沿曲线采样段数

static func build(prims: Array, density := 1.0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in range(prims.size()):
		_append_shell(prims[i], float(i), density, verts, norms, uvs, uv2s, idx)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# 顶点存的是基本体局部坐标，Godot 按它算的 AABB 是错的；
	# 用静止姿态的保守包围盒，SdfProp 端还会再叠 extra_cull_margin。
	mesh.custom_aabb = SdfMath.rest_aabb(prims)
	return mesh

static func _append_shell(
	pr: SdfMath.Prim,
	prim_index: float,
	density: float,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	idx: PackedInt32Array,
) -> void:
	# 环面/弯管：走扫掠变径圆管壳（中心线折线 + 每点半径），不用 PrimitiveMesh。
	if pr.shape == SdfMath.SHAPE_TORUS or pr.shape == SdfMath.SHAPE_BEZIER:
		var pts := PackedVector3Array()
		var radii := PackedFloat32Array()
		var closed := false
		if pr.shape == SdfMath.SHAPE_TORUS:
			var big_r: float = pr.params.x
			var minor: float = pr.params.y
			var arc: float = pr.params.z
			closed = arc >= 179.5
			# 弧对称于 +Y 轴（φ=90°），半宽 arc；满环则整圈
			var span := deg_to_rad(minf(arc, 180.0)) * 2.0
			var n := maxi(6, roundi(TORUS_ALONG * density * (span / TAU)))
			var count := n if closed else n + 1
			for k in range(count):
				var frac := float(k) / float(n)
				var phi := deg_to_rad(90.0 - arc) + span * frac
				pts.append(Vector3(cos(phi) * big_r, sin(phi) * big_r, 0.0))
				radii.append(minor)
		else:
			var big_a := Vector3.ZERO
			var big_b := Vector3(pr.curve.x, pr.curve.y, 0.0)
			var big_c := Vector3(pr.curve.z, pr.curve.w, 0.0)
			var n := maxi(4, roundi(BEZIER_ALONG * density))
			for k in range(n + 1):
				var t := float(k) / float(n)
				var omt := 1.0 - t
				# 二次贝塞尔 B(t) = (1-t)²A + 2(1-t)t·Bctrl + t²C
				var pt := big_a * (omt * omt) + big_b * (2.0 * omt * t) + big_c * (t * t)
				pts.append(pt)
				radii.append(lerpf(pr.params.x, pr.params.y, t))
		_append_tube(pts, radii, closed, prim_index, verts, norms, uvs, uv2s, idx)
		return

	var src: PrimitiveMesh
	match pr.shape:
		SdfMath.SHAPE_SPHERE:
			var s := SphereMesh.new()
			s.radius = pr.params.x
			s.height = pr.params.x * 2.0
			s.radial_segments = maxi(8, roundi(SPHERE_SEGS * density))
			s.rings = maxi(5, roundi(SPHERE_RINGS * density))
			src = s
		SdfMath.SHAPE_CAPSULE, SdfMath.SHAPE_CONE:
			var c := CapsuleMesh.new()
			var r := pr.params.x if pr.shape == SdfMath.SHAPE_CAPSULE else maxf(pr.params.x, pr.params.y)
			var half := pr.params.y if pr.shape == SdfMath.SHAPE_CAPSULE else pr.params.z
			c.radius = r
			c.height = 2.0 * (half + r)  # CapsuleMesh.height 是含两端半球的总高
			c.radial_segments = maxi(8, roundi(CAPSULE_SEGS * density))
			c.rings = maxi(4, roundi(CAPSULE_RINGS * density))
			src = c
		SdfMath.SHAPE_BOX:
			var b := BoxMesh.new()
			b.size = pr.params * 2.0
			var sub := maxi(1, roundi(BOX_SUBDIV * density))
			b.subdivide_width = sub
			b.subdivide_height = sub
			b.subdivide_depth = sub
			src = b
	var arr := src.get_mesh_arrays()
	var sv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var sn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var su: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var si: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var base := verts.size()
	for j in range(sv.size()):
		var v := sv[j]
		if pr.shape == SdfMath.SHAPE_CONE:
			v = _morph_cone(v, pr.params.x, pr.params.y, pr.params.z)
		verts.append(v)
		norms.append(sn[j])
		uvs.append(su[j])
		uv2s.append(Vector2(prim_index, 0.0))
	for j in range(si.size()):
		idx.append(base + si[j])

## 沿中心线折线扫掠圆截面（半径逐点给）成一根管壳。环面/弯管共用。
## 曲线在局部 XY 平面，圆截面在 (面内法向, Z 轴) 平面内——故截面基向量取
## 面内法向 N=(T.y,-T.x,0) 与世界 Z，两者都 ⊥ 切向 T。closed=true 首尾环相连成闭环
## （满环），false 则两端 fan-cap 补盖成水密壳（吸附会把盖拉到 SDF 面）。
static func _append_tube(
	pts: PackedVector3Array,
	radii: PackedFloat32Array,
	closed: bool,
	prim_index: float,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	idx: PackedInt32Array,
) -> void:
	var m := pts.size()
	if m < 2:
		return
	var ring_base := PackedInt32Array()  # 每个中心点第一个环顶点的全局索引
	for i in range(m):
		# 切向：闭环首尾环绕，开管端点用单侧差分
		var t_dir: Vector3
		if closed:
			t_dir = pts[(i + 1) % m] - pts[(i - 1 + m) % m]
		elif i == 0:
			t_dir = pts[1] - pts[0]
		elif i == m - 1:
			t_dir = pts[m - 1] - pts[m - 2]
		else:
			t_dir = pts[i + 1] - pts[i - 1]
		var tan := t_dir.normalized() if t_dir.length() > 1e-6 else Vector3(1, 0, 0)
		var n_plane := Vector3(tan.y, -tan.x, 0.0)
		if n_plane.length() < 1e-6:
			n_plane = Vector3(1, 0, 0)
		n_plane = n_plane.normalized()
		var z_axis := Vector3(0, 0, 1)
		ring_base.append(verts.size())
		for j in range(TUBE_RADIAL):
			var a := TAU * float(j) / float(TUBE_RADIAL)
			var dir := n_plane * cos(a) + z_axis * sin(a)
			verts.append(pts[i] + dir * radii[i])
			norms.append(dir)
			uvs.append(Vector2(float(i) / float(m - 1), float(j) / float(TUBE_RADIAL)))
			uv2s.append(Vector2(prim_index, 0.0))
	# 环间四边形（两三角）
	var seg := m if closed else m - 1
	for i in range(seg):
		var a0: int = ring_base[i]
		var b0: int = ring_base[(i + 1) % m]
		for j in range(TUBE_RADIAL):
			var j1 := (j + 1) % TUBE_RADIAL
			# 缠绕：正面朝外（与 Godot PrimitiveMesh 约定一致），描边 cull_front 才只留轮廓
			idx.append(a0 + j); idx.append(a0 + j1); idx.append(b0 + j)
			idx.append(a0 + j1); idx.append(b0 + j1); idx.append(b0 + j)
	# 开管两端 fan-cap 补盖成水密壳
	if not closed:
		_cap_end(pts[0], radii[0], ring_base[0], true, prim_index, verts, norms, uvs, uv2s, idx)
		_cap_end(pts[m - 1], radii[m - 1], ring_base[m - 1], false, prim_index, verts, norms, uvs, uv2s, idx)

## 用中心点 fan 封住一端的环。start=true 为首端（法线朝反切向），否则尾端。
static func _cap_end(
	center: Vector3,
	r: float,
	ring0: int,
	is_start: bool,
	prim_index: float,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	idx: PackedInt32Array,
) -> void:
	var c := verts.size()
	verts.append(center)
	norms.append(Vector3(0, 0, 1))
	uvs.append(Vector2(0.5, 0.5))
	uv2s.append(Vector2(prim_index, 0.0))
	for j in range(TUBE_RADIAL):
		var j1 := (j + 1) % TUBE_RADIAL
		if is_start:
			idx.append(c); idx.append(ring0 + j); idx.append(ring0 + j1)
		else:
			idx.append(c); idx.append(ring0 + j1); idx.append(ring0 + j)

## 胶囊壳 → 圆头锥壳：按高度把 xz 半径从 r1 插到 r2，端帽的 y 也压到各自半径。
## 只是给吸附一个近似初始面，不追求与 SdfMath._round_cone 严格一致。
static func _morph_cone(v: Vector3, r1: float, r2: float, half_h: float) -> Vector3:
	var rmax := maxf(r1, r2)
	var t := clampf((v.y + half_h) / maxf(2.0 * half_h, 1e-6), 0.0, 1.0)
	var s := lerpf(r1, r2, t) / maxf(rmax, 1e-6)
	var out := Vector3(v.x * s, v.y, v.z * s)
	if v.y > half_h:
		out.y = half_h + (v.y - half_h) * (r2 / maxf(rmax, 1e-6))
	elif v.y < -half_h:
		out.y = -half_h + (v.y + half_h) * (r1 / maxf(rmax, 1e-6))
	return out
