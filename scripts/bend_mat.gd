class_name BendMat
extends RefCounted
## 共享 world-bending ShaderMaterial 工厂。
## 所有世界几何（地块/树/角色）都用它，才能统一跟随弯曲。

const CURVATURE := 0.007
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
