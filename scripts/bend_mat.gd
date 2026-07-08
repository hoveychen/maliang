class_name BendMat
extends RefCounted
## 共享 world-bending ShaderMaterial 工厂。
## 所有世界几何（地块/树/房子）都用它，才能统一跟随弯曲。
## 纯色与贴图两种入口；贴图版可选 normal map（轻 PBR：albedo + normal + 粗糙度常量）。

const CURVATURE := 0.0015  ## 动森式大半径：极缓曲率，大部分平地感、远处缓弯隐去天空
static var _shader: Shader = null

static func _shared_shader() -> Shader:
	if _shader == null:
		_shader = load("res://shaders/world_bend.gdshader")
	return _shader

static func make(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shared_shader()
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("curvature", CURVATURE)
	return m

static func make_textured(
	tex: Texture2D,
	color := Color.WHITE,
	rough := 0.95,
	uv_scale := Vector2.ONE,
	normal: Texture2D = null,
	normal_depth := 1.0,
) -> ShaderMaterial:
	var m := make(color)
	m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("roughness", rough)
	m.set_shader_parameter("uv_scale", uv_scale)
	if normal != null:
		m.set_shader_parameter("normal_tex", normal)
		m.set_shader_parameter("normal_depth", normal_depth)
	return m

## 把导入模型（如 KayKit gltf）的 StandardMaterial3D 换成等效的 bend 材质，
## 保留其 albedo 贴图/颜色与粗糙度——否则导入网格不跟随世界弯曲。
## 对同一 StandardMaterial3D 做缓存，整包资产共享一张调色板 atlas 时只建一个材质。
static var _wrapped_cache: Dictionary = {}

## 单材质版 wrap：MultiMesh 合批没有场景树可遍历，剥出的 mesh 材质走这里。
static func wrap_material(src: Material) -> ShaderMaterial:
	return src if src is ShaderMaterial else _wrap_material(src)

static func wrap_scene(root: Node) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node
		if mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var src := mi.get_active_material(s)
			if src is ShaderMaterial:
				continue  # 已是 bend 材质
			mi.set_surface_override_material(s, _wrap_material(src))

static func _wrap_material(src: Material) -> ShaderMaterial:
	if src == null:
		return make(Color.WHITE)
	var key := src.get_instance_id()
	if _wrapped_cache.has(key):
		return _wrapped_cache[key]
	var m: ShaderMaterial
	if src is BaseMaterial3D:
		var b: BaseMaterial3D = src
		m = make_textured(
			b.albedo_texture,
			b.albedo_color,
			b.roughness,
			Vector2.ONE,
			b.normal_texture if b.normal_enabled else null,
			b.normal_scale if b.normal_enabled else 0.0,
		)
	else:
		m = make(Color.WHITE)
	_wrapped_cache[key] = m
	return m
