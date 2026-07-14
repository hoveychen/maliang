class_name SdfProp
extends MeshInstance3D
## SDF blend-shell 可动物件：一段 JSON spec → 单 draw call 的无缝融合网格。
## 网格只在 setup 时构建一次（顶点存基本体局部坐标）；之后动画每帧只改
## uniform 里的基本体变换（SdfAnimator 驱动），GPU 顶点阶段重新吸附表面。
##
## 摆放约定：节点只做 yaw 旋转+平移、不缩放（shader 的 world-bend 换算依赖此约定，
## 见 sdf_field.gdshaderinc 的 apply_bend）；尺寸在 spec 里改。

const CULL_MARGIN := BendMat.CULL_MARGIN  ## 推导见 BendMat：最坏下压 30m，取 35

## 可动物件壳密度：顶点吸附（snap_iters 次全基本体场求值/顶点/帧 × 主+描边两 pass）
## 是真机成本主轴——隐藏 7 个物件 100ms→24.8ms。0.6 档顶点数 ≈ 36%，梯度法线保平滑；
## 可动物件屏占比大于树，比烘焙布景的 0.34 档保守。
const SHELL_DENSITY := 0.6
## 吸附迭代数（主壳/描边壳）：移动端 2/1 已收敛，桌面 4/4 观感与旧版完全一致。
static var _snap_iters_main := 2 if OS.has_feature("mobile") else 4
static var _snap_iters_outline := 1 if OS.has_feature("mobile") else 4

## 描边 pass 开关（画质旋钮 outline——inverted-hull 让每个物件画两遍，
## 且是全场景最重的逐顶点材质；默认恒开，弱机由 benchmark 定档摘除）。
static var _outline_enabled := true

static func set_outline_enabled(on: bool, tree: SceneTree) -> void:
	_outline_enabled = on
	for n in tree.get_nodes_in_group("perf_props"):
		var p := n as SdfProp
		if p == null or p._mats.size() < 2:
			continue
		p._mats[0].next_pass = p._mats[1] if on else null

## 纸艺风（画质页样式键）：主壳材质的纸艺参数档。与 BendMat.PAPER_PROPS 语法同源；
## 本 shader 固有三段 toon 光，无 bands 项。记忆态由 world 接线时传 BendMat.papercraft_on()
## 的解析结果（调试强制位语义只在 BendMat 一处）。
const PAPER_SDF := {"paper_facet": 1.0, "paper_edge": 0.55, "paper_grain": 0.5, "paper_tone": 0.4}
static var _papercraft := BendMat.papercraft_on()

## 纸艺风开关：作用于已存在（perf_props 组）与后续创建的所有物件（照 set_snap_iters 先例）。
static func set_papercraft(on: bool, tree: SceneTree) -> void:
	_papercraft = on
	for n in tree.get_nodes_in_group("perf_props"):
		var p := n as SdfProp
		if p == null or p._mats.is_empty():
			continue
		p._apply_paper()

## 把当前纸艺档写到主壳材质（描边 pass 无纸艺项）。创建与切换两处共用。
func _apply_paper() -> void:
	for k: String in PAPER_SDF:
		_mats[0].set_shader_parameter(k, PAPER_SDF[k] if _papercraft else 0.0)

## 换档入口（画质旋钮 prop_detail）：作用于已存在（perf_props 组）与后续创建的所有物件。
static func set_snap_iters(main_iters: int, outline_iters: int, tree: SceneTree) -> void:
	_snap_iters_main = main_iters
	_snap_iters_outline = outline_iters
	for n in tree.get_nodes_in_group("perf_props"):
		var p := n as SdfProp
		if p == null or p._mats.is_empty():
			continue
		p._mats[0].set_shader_parameter("snap_iters", main_iters)
		if p._mats.size() > 1:
			p._mats[1].set_shader_parameter("snap_iters", outline_iters)

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

	mesh = SdfMeshBuilder.build(prims, SHELL_DENSITY)
	extra_cull_margin = CULL_MARGIN

	if _shell_shader == null:
		_shell_shader = load("res://shaders/sdf_blend_shell.gdshader")
		_outline_shader = load("res://shaders/sdf_outline.gdshader")
	var main := ShaderMaterial.new()
	main.shader = _shell_shader
	main.set_shader_parameter("color_k", cfg.color_k)
	main.set_shader_parameter("snap_iters", _snap_iters_main)
	_mats = [main]
	if cfg.outline > 0.0:
		var outline := ShaderMaterial.new()
		outline.shader = _outline_shader
		outline.set_shader_parameter("outline_width", cfg.outline)
		outline.set_shader_parameter("snap_iters", _snap_iters_outline)
		if _outline_enabled:
			main.next_pass = outline
		_mats.append(outline)  # 摘除态也保留引用，换档可再挂回
	for m in _mats:
		m.set_shader_parameter("prim_count", prims.size())
		m.set_shader_parameter("blend_k", cfg.blend)
		m.set_shader_parameter("curvature", BendMat.CURVATURE)
	if _papercraft:
		_apply_paper()
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
	# 屏外挂起：视锥外（如相机背后）_process 整个停摆（游走/呼吸/uniform 上传全免），
	# 回到视野自动恢复。AABB 用静止包围盒放宽动画余量，并向下延伸剔除边距（弯曲下压），
	# 与渲染剔除同一保守口径——绝不会出现"渲染着却不动"的情况。
	# headless 例外：假视口无渲染，可见性通知永不触发，挂了会把所有物件永久冻结
	# （回测靠 _process 跑动画断言），故仅真渲染环境启用。
	if DisplayServer.get_name() != "headless":
		var enabler := VisibleOnScreenEnabler3D.new()
		var box := aabb.grow(2.0)
		box.position.y -= CULL_MARGIN
		box.size.y += CULL_MARGIN
		enabler.aabb = box
		enabler.enable_node_path = NodePath("..")
		add_child(enabler)

## 把当前基本体姿态打包进两个 pass 的 uniform（动画每帧调用）。
func push_uniforms() -> void:
	var pos := PackedVector4Array()
	var rot := PackedVector4Array()
	var par := PackedVector4Array()
	var cur := PackedVector4Array()  # bezier 弯管控制点 B.xy/C.xy（其余基本体为 0）
	for pr: SdfMath.Prim in prims:
		var o := pr.xform.origin
		pos.append(Vector4(o.x, o.y, o.z, float(pr.shape)))
		var q := pr.xform.basis.get_rotation_quaternion()
		rot.append(Vector4(q.x, q.y, q.z, q.w))
		par.append(Vector4(pr.params.x, pr.params.y, pr.params.z, pr.blend))
		cur.append(pr.curve)
	_mats[0].set_shader_parameter("prim_pos", pos)
	_mats[0].set_shader_parameter("prim_rot", rot)
	_mats[0].set_shader_parameter("prim_params", par)
	_mats[0].set_shader_parameter("prim_curve", cur)
	# 描边被摘除时不给游离 pass 上传（省一半 uniform 流量）；重挂后下帧自然补上
	if _mats.size() > 1 and _mats[0].next_pass != null:
		_mats[1].set_shader_parameter("prim_pos", pos)
		_mats[1].set_shader_parameter("prim_rot", rot)
		_mats[1].set_shader_parameter("prim_params", par)
		_mats[1].set_shader_parameter("prim_curve", cur)

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

func _enter_tree() -> void:
	add_to_group("perf_props")  # PerfSweep 分解扫频用（debug 诊断）

var _upload_tick := 0

func _process(delta: float) -> void:
	if animator == null:
		return
	var t0 := Time.get_ticks_usec()
	_wander_step(delta)
	animator.advance(delta)
	# 静止（仅呼吸）时 uniform 上传降到 1/3 帧率：呼吸是慢正弦，10~20Hz 步进不可见；
	# 真位移（move_vel 非零，含蹦跳蓄力段）保持全帧率。旧版每物件每帧重建 3 个
	# PackedVector4Array + 最多 6 次 set_shader_parameter，是待机 CPU/驱动开销大头。
	_upload_tick += 1
	if not animator.move_vel.is_zero_approx() or _upload_tick % 3 == 0:
		push_uniforms()
	ProcProf.add("sdfprop", Time.get_ticks_usec() - t0)
