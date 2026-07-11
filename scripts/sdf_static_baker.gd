class_name SdfStaticBaker
extends RefCounted
## 把 SDF spec 的静止姿态烘焙成普通 ArrayMesh：顶点吸附到 smooth-min 表面、
## 法线取场梯度、颜色按 sdf_field.gdshaderinc 的 sdf_color 公式软混进顶点色。
## 不动的布景（棉花糖树/灌木）专用——SdfProp 是每实例材质+每帧 uniform+
## 逐像素 SDF 循环的可动物件管线，铺几百棵树平板扛不住；烘焙后就是普通网格，
## 一份 mesh + 一份共享 bend 材质随便实例。
##
## GDScript 逐顶点投影一棵树要秒级，烘焙走构建期：tools/bake_sdf_deco.gd
## 离线生成 assets/sdf_props/baked/*.res，运行时 preload 零开销。

## 烘焙网格共享材质：world_bend + 顶点色（所有烘焙布景一份材质）。
static var _mat: ShaderMaterial = null

static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = BendMat.make(Color.WHITE)
		_mat.set_shader_parameter("vertex_color_mix", 1.0)
	return _mat

## 实例化一个烘焙好的布景网格（mesh 由调用方 preload 的 .res 提供）。
static func instance(mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material()
	mi.extra_cull_margin = SdfProp.CULL_MARGIN
	return mi

## 静态烘焙壳密度：圆润观感来自梯度法线（与密度无关），密度只管轮廓——
## god 视角一棵树屏幕上百来像素，球 8 段轮廓够用；1.0 档一棵树 5~9k 面
## 是平板 fps<10 的主因（500 棵占世界三角形 96%），0.34 档压到 ~1k 面。
const SHELL_DENSITY := 0.34

## SDF 环境遮蔽（Inigo Quilez 五步法）：沿外法线逐步外推采样场值，附近若有其它壳面
## 挡着 → 场值远小于步距 → 判定被遮蔽、压暗。烘进顶点色让棉花糖树的 blob 缝隙/底部
## 有明暗体积感（关实时阴影后补一层自阴影），凸处几乎不动。纯几何、随 .res 一起落盘。
const AO_STEPS := 5
const AO_STEP := 0.12     ## 每步外推距离(米)：×5 ≈ 0.6m 采样邻域，够抓 blob 缝
const AO_STRENGTH := 0.9  ## 遮蔽压暗强度
const AO_FLOOR := 0.45    ## 最暗地板：缝隙再深也不压成死黑

## spec 字典 → 烘焙 ArrayMesh；spec 不合法返回 null 并 push_warning。
static func bake_spec(spec: Dictionary) -> ArrayMesh:
	var cfg := SdfSpec.parse(spec)
	if not cfg.ok:
		push_warning("SdfStaticBaker spec 不合法: %s" % cfg.error)
		return null
	var rig := SdfSpec.build_rig(cfg)
	var prims: Array = rig.prims
	var shell := SdfMeshBuilder.build(prims, SHELL_DENSITY)
	var arrays := shell.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var k: float = cfg.blend
	var n := verts.size()
	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	var out_c := PackedColorArray()
	out_v.resize(n)
	out_n.resize(n)
	out_c.resize(n)
	for i in range(n):
		var pr: SdfMath.Prim = prims[int(uv2s[i].x + 0.5)]
		# 壳顶点是基本体局部坐标：先按静止姿态摆到物件空间，再吸附到融合面
		var p: Vector3 = pr.xform * verts[i]
		p = SdfMath.project(prims, p, k)
		var g := SdfMath.gradient(prims, p, k)
		out_v[i] = p
		out_n[i] = g.normalized() if g.length() > 1e-6 else Vector3.UP
		var ao := _ambient_occlusion(prims, p, out_n[i], k)
		var base_c := _blend_color(prims, p, k, cfg.color_k)
		out_c[i] = Color(base_c.r * ao, base_c.g * ao, base_c.b * ao, base_c.a)
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = out_v
	out[Mesh.ARRAY_NORMAL] = out_n
	out[Mesh.ARRAY_COLOR] = out_c
	out[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	return mesh

static func bake_json_file(path: String) -> ArrayMesh:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		push_warning("SdfStaticBaker JSON 解析失败: %s" % path)
		return null
	return bake_spec(data)

## SDF 环境遮蔽系数 [AO_FLOOR,1]：沿外法线 n 从表面点 p 逐步外推，累计"步距 − 实际
## 场值"（凹处邻壳更近 → 场值小 → 累计大 → 越暗），IQ 五步衰减法。乘进顶点色。
static func _ambient_occlusion(prims: Array, p: Vector3, n: Vector3, k: float) -> float:
	var occ := 0.0
	var sca := 1.0
	for i in range(1, AO_STEPS + 1):
		var d := float(i) * AO_STEP
		var f := SdfMath.eval(prims, p + n * d, k)
		occ += (d - f) * sca
		sca *= 0.6
	return clampf(1.0 - AO_STRENGTH * occ, AO_FLOOR, 1.0)

## 颜色软混：与 sdf_field.gdshaderinc 的 sdf_color 同一公式（按场值贴近度加权）。
static func _blend_color(prims: Array, p: Vector3, k: float, color_k: float) -> Color:
	var d := SdfMath.eval(prims, p, k)
	var acc := Vector3.ZERO
	var wsum := 1e-5
	for pr: SdfMath.Prim in prims:
		var di := SdfMath.prim_dist(pr, p)
		var w := clampf(1.0 - (di - d) / color_k, 0.0, 1.0)
		w *= w
		acc += Vector3(pr.color.r, pr.color.g, pr.color.b) * w
		wsum += w
	acc /= wsum
	# 顶点色属性不走 source_color 的自动 sRGB→线性转换（uniform/贴图才有），
	# 这里手动转线性，否则渲染管线把 sRGB 值当线性用，整树发白。
	return Color(acc.x, acc.y, acc.z).srgb_to_linear()
