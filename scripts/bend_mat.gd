class_name BendMat
extends RefCounted
## 共享 world-bending ShaderMaterial 工厂。
## 所有世界几何（地块/树/房子）都用它，才能统一跟随弯曲。
## 纯色与贴图两种入口；贴图版可选 normal map（轻 PBR：albedo + normal + 粗糙度常量）。

const CURVATURE := 0.0015  ## 动森式大半径：极缓曲率，大部分平地感、远处缓弯隐去天空
## 弯曲网格的视锥剔除 AABB 外扩（所有 bend 几何共用这一个值）。
## bend 只把顶点往下压，最大位移出现在离焦点最远的区块角：slot 重定位保证区块中心
## 离焦点每轴 ≤75m（半世界），角点再加半区块 25m → |xz|² = 2×100² = 20000，
## 最大下压 = CURVATURE × 20000 = 30m；取 35 留余量。
## 旧值 220 ≈ 全场景永不剔除——相机俯仰 47°，背后/侧面几何全在白白提交渲染。
const CULL_MARGIN := 35.0
static var _shader: Shader = null

## 纸艺化开关（画质页样式键 papercraft，world._apply_graphics_key 接线）：
## 开 = 所有 bend 材质统一上纸艺参数（折面化法线+色阶光照+折痕白描+纸纹+卡纸色调）。
## MALIANG_PAPERCRAFT=1 是调试强制位（headless 截图/harness 用），置位后 set_papercraft(false)
## 也压不掉。地形/水面的同款参数在 chunk_manager（set_papercraft），保证全世界一套纸。
static var _env_forced := OS.get_environment("MALIANG_PAPERCRAFT") == "1"
static var _papercraft := _env_forced
## 活材质注册表：make() 出厂的每张材质都登记弱引用，运行时切换开关要挨个补参数
## （材质被 _wrapped_cache/scatter 批缓存长期持有，只对新建生效的开关等于没切）。
static var _live: Array[WeakRef] = []

## 物品档纸艺参数（地形/水面各有自己的档，见 chunk_manager）。
const PAPER_PROPS := {
	"paper_facet": 1.0, "paper_bands": 3.0, "paper_edge": 0.7,
	"paper_grain": 0.7, "paper_tone": 0.5,
}

static func papercraft_on() -> bool:
	return _papercraft

## 运行时切换（画质页即时生效）：更新记忆态 + 给所有活材质补参数，顺手清掉已死弱引用。
static func set_papercraft(on: bool) -> void:
	_papercraft = on or _env_forced
	var alive: Array[WeakRef] = []
	for wr in _live:
		var m: ShaderMaterial = wr.get_ref()
		if m == null:
			continue
		_apply_paper(m, _papercraft)
		alive.append(wr)
	_live = alive

static func _apply_paper(m: ShaderMaterial, on: bool) -> void:
	for k: String in PAPER_PROPS:
		m.set_shader_parameter(k, PAPER_PROPS[k] if on else 0.0)

static func _shared_shader() -> Shader:
	if _shader == null:
		_shader = load("res://shaders/world_bend.gdshader")
	return _shader

static func make(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shared_shader()
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("curvature", CURVATURE)
	if _papercraft:
		_apply_paper(m, true)
	_live.append(weakref(m))
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
