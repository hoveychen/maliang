class_name BlobShadow
extends Object
## 脚下伪影工厂：共享一份 QuadMesh + 材质（shader 带 world-bend 项，远处不悬空）。
## 背景：实时定向阴影在老移动 GPU 上一开就 ~2.5 倍帧开销（Mali-G76 实测 7↔18fps，
## 与投影几何量/软硬过滤无关），全场景改平光，影子锚定感由脚下暗斑承担。

## 两档共享 mesh：bend=true 给节点未预弯的 SdfProp；bend=false 给已被
## world._place_on_bent_ground CPU 预下压的角色（再弯一次会双重下坠钻进地里）。
static var _meshes := {}

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
	var mi := MeshInstance3D.new()
	mi.name = "BlobShadow"
	mi.mesh = _shared_mesh(bend)
	mi.scale = Vector3(radius * 2.0, 1.0, radius * 2.0)
	mi.position.y = 0.2  # 抬离地面：给深度测试留余量（0.04 在远距被地表吃掉）；俯视角看不出悬浮
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 220.0  # 同 chunk_manager：world-bend 位移防误剔除
	parent.add_child(mi)

## 摘掉伪影（悬浮的小仙子等不落地角色用——脚下暗斑反而穿帮）。
static func detach(parent: Node3D) -> void:
	var old := parent.get_node_or_null("BlobShadow")
	if old != null:
		old.queue_free()
