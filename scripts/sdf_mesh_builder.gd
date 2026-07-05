class_name SdfMeshBuilder
extends RefCounted
## 把一组 SDF 基本体的"壳网格"合并成单 surface 的 ArrayMesh（一次 draw call）。
## 顶点存基本体**局部**坐标（动画只改 uniform 里的基本体变换，不重建网格），
## UV2.x 记基本体索引；真实表面位置由 sdf_blend_shell.gdshader 顶点阶段
## 先按当前基本体变换摆到物件空间、再吸附到 smooth-min SDF 表面得到。
## 壳网格只要"拓扑合理、顶点够密、离目标面不远"即可，吸附会修正形状——
## 所以圆头锥直接用胶囊壳按半径插值搓出来，不必精确。

## 细分档位：跟 paper_character 的 6×12 一个量级，单件角色约 2~5k 顶点。
const SPHERE_SEGS := 24
const SPHERE_RINGS := 16
const CAPSULE_SEGS := 20
const CAPSULE_RINGS := 12
const BOX_SUBDIV := 6

static func build(prims: Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in range(prims.size()):
		_append_shell(prims[i], float(i), verts, norms, uvs, uv2s, idx)
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
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	idx: PackedInt32Array,
) -> void:
	var src: PrimitiveMesh
	match pr.shape:
		SdfMath.SHAPE_SPHERE:
			var s := SphereMesh.new()
			s.radius = pr.params.x
			s.height = pr.params.x * 2.0
			s.radial_segments = SPHERE_SEGS
			s.rings = SPHERE_RINGS
			src = s
		SdfMath.SHAPE_CAPSULE, SdfMath.SHAPE_CONE:
			var c := CapsuleMesh.new()
			var r := pr.params.x if pr.shape == SdfMath.SHAPE_CAPSULE else maxf(pr.params.x, pr.params.y)
			var half := pr.params.y if pr.shape == SdfMath.SHAPE_CAPSULE else pr.params.z
			c.radius = r
			c.height = 2.0 * (half + r)  # CapsuleMesh.height 是含两端半球的总高
			c.radial_segments = CAPSULE_SEGS
			c.rings = CAPSULE_RINGS
			src = c
		SdfMath.SHAPE_BOX:
			var b := BoxMesh.new()
			b.size = pr.params * 2.0
			b.subdivide_width = BOX_SUBDIV
			b.subdivide_height = BOX_SUBDIV
			b.subdivide_depth = BOX_SUBDIV
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
