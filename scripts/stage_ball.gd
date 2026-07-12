class_name StageBall
extends Node3D
## C 档球实体节点：包一个 BallBody 物理原语（逻辑坐标 + 滚动物理）+ 一个简单球体网格。
## host 每帧 step 物理推进逻辑坐标，world.gd 用 _place_on_bent_ground 把逻辑坐标换成渲染坐标。
## P2b：host 默认所有者、本地模拟、全端落位可见。所有权转移 / 非 owner 客户端预测与和解 /
## 球 id 纳入位置复制流（C 档更高频）见 P2c；踢击输入与真机手感见 P3。

const RADIUS := 0.6

var body := BallBody.new()

func _init() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = RADIUS
	mesh.height = RADIUS * 2.0
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.2)
	mat.roughness = 0.6
	mi.material_override = mat
	add_child(mi)

## 落位/复位到逻辑坐标（清零速度）。
func place_at(logical: Vector2) -> void:
	body.place(logical)

## host 物理推进一帧（逻辑坐标）。非 owner 端不调（P2c 走复制/预测）。
func step(delta: float) -> void:
	body.step(delta)
