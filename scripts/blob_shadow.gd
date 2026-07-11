class_name BlobShadow
extends Object
## 脚下伪影工厂：共享一份 QuadMesh + 材质（shader 带 world-bend 项，远处不悬空）。
## 背景：实时定向阴影在老移动 GPU 上一开就 ~2.5 倍帧开销（Mali-G76 实测 7↔18fps，
## 与投影几何量/软硬过滤无关），全场景改平光，影子锚定感由脚下暗斑承担。

## 两档共享 mesh：bend=true 给节点未预弯的 SdfProp；bend=false 给已被
## world._place_on_bent_ground CPU 预下压的角色（再弯一次会双重下坠钻进地里）。
static var _meshes := {}

## world 开实时角色阴影(CHARACTER_SHADOWS)时置真：落地角色(bend=false)改用真实定向
## 投影，脚下暗斑让位避免双影；SdfProp(bend=true)不投实时阴影，仍保留脚下 blob。
static var suppress_actor_blob := false

## 场景太阳的地面水平方向（= 定向光照射方向在 XZ 平面的投影，归一化）：散布/建筑贴片影
## 据此朝背光侧偏移、椭圆长轴沿此方向拉长——影方向唯一从场景那盏 DirectionalLight 推导
## （world 启动时算出写入），保证跟场景明暗同一个太阳，不会两套方向打架。默认值对应
## world 默认 Sun 旋转 (-55,-40,0)，world 没设时也不至于零向量。
static var sun_ground_dir := Vector3(0.643, 0.0, -0.766)

static func _shared_mesh(bend: bool) -> QuadMesh:
	if not _meshes.has(bend):
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/blob_shadow.gdshader")
		m.set_shader_parameter("curvature", BendMat.CURVATURE if bend else 0.0)
		var q := QuadMesh.new()
		q.orientation = PlaneMesh.FACE_Y
		q.size = Vector2.ONE
		q.material = m
		_meshes[bend] = q
	return _meshes[bend]

## 挂到角色/物件根节点（锚点在脚底）下；radius 为影斑半径（米）。重复调用先清旧的。
static func attach(parent: Node3D, radius: float, bend := false) -> void:
	var old := parent.get_node_or_null("BlobShadow")
	if old != null:
		old.queue_free()
	if suppress_actor_blob and not bend:
		return  # 落地角色改用实时定向阴影，不挂脚下暗斑（避免双影）
	var mi := MeshInstance3D.new()
	mi.name = "BlobShadow"
	mi.mesh = _shared_mesh(bend)
	mi.scale = Vector3(radius * 2.0, 1.0, radius * 2.0)
	mi.position.y = 0.2  # 抬离地面：给深度测试留余量（0.04 在远距被地表吃掉）；俯视角看不出悬浮
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = BendMat.CULL_MARGIN  # world-bend 位移防误剔除，推导见 BendMat
	parent.add_child(mi)

## 摘掉伪影（悬浮的小仙子等不落地角色用——脚下暗斑反而穿帮）。
static func detach(parent: Node3D) -> void:
	var old := parent.get_node_or_null("BlobShadow")
	if old != null:
		old.queue_free()

## 散布布景（树/灌木）批量脚下影用的共享 mesh：走 MultiMesh 一次 draw call，与逐节点
## blob 同一 shader，恒取 bend 档（散布节点未 CPU 预弯，弯曲交给 shader，远处不悬空）。
## strength 独立可调——散布数量大、影斑常重叠，调淡防叠成脏斑；按 strength 缓存一份。
static var _mm_meshes := {}

static func multimesh_mesh(strength: float) -> QuadMesh:
	if not _mm_meshes.has(strength):
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/blob_shadow.gdshader")
		m.set_shader_parameter("curvature", BendMat.CURVATURE)
		m.set_shader_parameter("strength", strength)
		var q := QuadMesh.new()
		q.orientation = PlaneMesh.FACE_Y
		q.size = Vector2.ONE
		q.material = m
		_mm_meshes[strength] = q
	return _mm_meshes[strength]
