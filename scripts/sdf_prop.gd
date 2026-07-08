class_name SdfProp
extends MeshInstance3D
## SDF blend-shell 可动物件：一段 JSON spec → 单 draw call 的无缝融合网格。
## 网格只在 setup 时构建一次（顶点存基本体局部坐标）；之后动画每帧只改
## uniform 里的基本体变换（SdfAnimator 驱动），GPU 顶点阶段重新吸附表面。
##
## 摆放约定：节点只做 yaw 旋转+平移、不缩放（shader 的 world-bend 换算依赖此约定，
## 见 sdf_field.gdshaderinc 的 apply_bend）；尺寸在 spec 里改。

const CULL_MARGIN := 220.0  ## 与 chunk_manager 一致：world-bend 位移大，防误剔除

static var _shell_shader: Shader = null
static var _outline_shader: Shader = null

var config: Dictionary = {}
var prims: Array = []
var meta: Dictionary = {}
var animator: SdfAnimator = null
var _mats: Array[ShaderMaterial] = []

# 锚点游走（世界摆放用）：围绕启用时的位置在小半径内漫游，走走停停
var _wander_r := 0.0
var _wander_center := Vector3.ZERO
var _wander_target := Vector3.ZERO
var _wander_wait := 0.0
var _wander_rng := RandomNumberGenerator.new()

const TURN_RATE := 5.0  ## 朝向追速度方向的角速度 rad/s

## 从 spec 字典创建；spec 不合法返回 null 并 push_warning（LLM 产物要能安全拒收）。
static func from_spec(spec: Dictionary) -> SdfProp:
	var cfg := SdfSpec.parse(spec)
	if not cfg.ok:
		push_warning("SdfProp spec 不合法: %s" % cfg.error)
		return null
	var prop := SdfProp.new()
	prop._setup(cfg)
	return prop

static func from_json_file(path: String) -> SdfProp:
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		push_warning("SdfProp JSON 解析失败: %s" % path)
		return null
	return from_spec(data)

func _setup(cfg: Dictionary) -> void:
	config = cfg
	name = str(cfg.name)
	var rig := SdfSpec.build_rig(cfg)
	prims = rig.prims
	meta = rig.meta

	mesh = SdfMeshBuilder.build(prims)
	extra_cull_margin = CULL_MARGIN

	if _shell_shader == null:
		_shell_shader = load("res://shaders/sdf_blend_shell.gdshader")
		_outline_shader = load("res://shaders/sdf_outline.gdshader")
	var main := ShaderMaterial.new()
	main.shader = _shell_shader
	main.set_shader_parameter("color_k", cfg.color_k)
	_mats = [main]
	if cfg.outline > 0.0:
		var outline := ShaderMaterial.new()
		outline.shader = _outline_shader
		outline.set_shader_parameter("outline_width", cfg.outline)
		main.next_pass = outline
		_mats.append(outline)
	for m in _mats:
		m.set_shader_parameter("prim_count", prims.size())
		m.set_shader_parameter("blend_k", cfg.blend)
		m.set_shader_parameter("curvature", BendMat.CURVATURE)
	material_override = main

	var colors := PackedVector4Array()
	for pr: SdfMath.Prim in prims:
		colors.append(Vector4(pr.color.r, pr.color.g, pr.color.b, 1.0))
	main.set_shader_parameter("prim_color", colors)

	animator = SdfAnimator.new(self)
	push_uniforms()
	# 脚下伪影（替代实时阴影，见 BlobShadow 注释）：半径取静止包围盒水平尺寸；
	# SdfProp 节点未被 CPU 预弯（弯曲在自己 shader 里），blob 走 bend=true 档
	var aabb := SdfMath.rest_aabb(prims)
	BlobShadow.attach(self, clampf(maxf(aabb.size.x, aabb.size.z) * 0.4, 0.4, 2.2), true)

## 把当前基本体姿态打包进两个 pass 的 uniform（动画每帧调用）。
func push_uniforms() -> void:
	var pos := PackedVector4Array()
	var rot := PackedVector4Array()
	var par := PackedVector4Array()
	for pr: SdfMath.Prim in prims:
		var o := pr.xform.origin
		pos.append(Vector4(o.x, o.y, o.z, float(pr.shape)))
		var q := pr.xform.basis.get_rotation_quaternion()
		rot.append(Vector4(q.x, q.y, q.z, q.w))
		par.append(Vector4(pr.params.x, pr.params.y, pr.params.z, pr.blend))
	for m in _mats:
		m.set_shader_parameter("prim_pos", pos)
		m.set_shader_parameter("prim_rot", rot)
		m.set_shader_parameter("prim_params", par)

## 启用锚点游走：以当前局部位置为圆心、radius 为半径漫游（父空间为区块局部系，
## 跟随世界环面重定位）。seed 用于确定性行为（同一 tile 的物件每次表现一致）。
func enable_wander(radius: float, seed_v: int = 0) -> void:
	_wander_r = radius
	_wander_center = position
	_wander_target = position
	_wander_wait = 0.5
	_wander_rng.seed = seed_v if seed_v != 0 else hash(name)
	if animator != null:
		animator.reset_pose()

func _wander_step(delta: float) -> void:
	if _wander_r <= 0.0 or animator == null:
		return
	var loco: Dictionary = config.locomotion
	if loco.type == "none":
		return
	var to_target := _wander_target - position
	to_target.y = 0.0
	if to_target.length() < 0.12:
		animator.move_vel = Vector3.ZERO
		_wander_wait -= delta
		if _wander_wait <= 0.0:
			var a := _wander_rng.randf() * TAU
			var r := sqrt(_wander_rng.randf()) * _wander_r
			_wander_target = _wander_center + Vector3(cos(a) * r, 0, sin(a) * r)
			_wander_wait = _wander_rng.randf_range(1.2, 3.5)
		return
	var dir := to_target.normalized()
	# 朝运动方向转身（模型正面朝 +Z）
	var want_yaw := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, want_yaw, minf(TURN_RATE * delta, 1.0))
	var speed: float = loco.speed
	var vel := dir * speed
	# hopper 只在腾空时平移（蹲/落地时原地蓄力）
	if not animator.can_translate():
		vel = Vector3.ZERO
	position += vel * minf(delta, to_target.length() / maxf(speed, 0.01))
	animator.move_vel = transform.basis.inverse() * (dir * speed)

func _process(delta: float) -> void:
	if animator == null:
		return
	var t0 := Time.get_ticks_usec()
	_wander_step(delta)
	animator.advance(delta)
	push_uniforms()
	ProcProf.add("sdfprop", Time.get_ticks_usec() - t0)
