class_name StageBall
extends Node3D
## C 档球实体节点：包一个 BallBody 物理原语（逻辑坐标 + 滚动物理）+ 一个简单球体网格。
## 模拟者每帧 step 物理推进逻辑坐标，world.gd 用 _place_on_bent_ground 把逻辑坐标换成渲染坐标。
## P2c：所有权状态机（own）分谁是模拟者——中立态 host 模拟、踢者临时持有；非模拟者端不跑物理，
## 改从复制缓冲（buf）插值/外推 + 平滑纠偏（render_logical）出渲染位置。踢击输入与真机手感见 P3。

const RADIUS := 0.6

var body := BallBody.new()
var own := BallOwnership.new()          ## 所有权状态机：谁此刻模拟这颗球（中立=host / 踢者临时）
var buf := BallReplicationBuffer.new()  ## 非模拟者端的复制缓冲（收 owner 广播的球位置，插值/外推）
var render_logical := Vector2.INF       ## 非模拟者端平滑纠偏后的渲染逻辑坐标（INF=首帧未定，直接落权威）

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

## 模拟者物理推进一帧（逻辑坐标）。非模拟者端不调（world._step_balls 走复制缓冲插值/外推）。
func step(delta: float) -> void:
	body.step(delta)
