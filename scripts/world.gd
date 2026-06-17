extends Node3D
## Demo 世界控制器 (P1)。
## 程序化搭建：环境光、地面占位、玩家、跟随相机。
## 后续 P2/P3 会把单块地面换成 toroidal + chunk streaming。

const PLAYER_SPEED := 7.0
## 相机相对玩家的偏移（高、远），做出 HD-2D 3/4 视角。
const CAM_OFFSET := Vector3(0.0, 15.0, 13.0)
const CAM_LERP := 0.18

var player: CharacterBody3D
var camera: Camera3D

func _ready() -> void:
	_setup_environment()
	_setup_ground()
	_setup_player()
	_setup_camera()

func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-55.0, -40.0, 0.0)
	light.light_energy = 1.15
	light.shadow_enabled = true
	add_child(light)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.82, 0.97)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.78, 0.85)
	env.ambient_light_energy = 0.55
	we.environment = env
	add_child(we)

func _setup_ground() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(240.0, 240.0)
	plane.subdivide_width = 120
	plane.subdivide_depth = 120
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.46, 0.72, 0.40)
	mat.roughness = 0.95
	ground.material_override = mat
	add_child(ground)

func _setup_player() -> void:
	player = CharacterBody3D.new()
	player.name = "Player"

	var body := MeshInstance3D.new()
	var caps := CapsuleMesh.new()
	caps.radius = 0.4
	caps.height = 1.6
	body.mesh = caps
	body.position.y = 0.8
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.92, 0.52, 0.32)
	body.material_override = pmat
	player.add_child(body)

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.6
	col.shape = shape
	col.position.y = 0.8
	player.add_child(col)

	add_child(player)

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 58.0
	camera.far = 400.0
	add_child(camera)
	_update_camera(true)

func _physics_process(_delta: float) -> void:
	if player == null:
		return
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var dir := Vector3(input.x, 0.0, input.y)
	player.velocity = dir * PLAYER_SPEED
	player.move_and_slide()

func _process(_delta: float) -> void:
	_update_camera(false)

func _update_camera(snap: bool) -> void:
	if camera == null or player == null:
		return
	var target := player.global_position + CAM_OFFSET
	if snap:
		camera.global_position = target
	else:
		camera.global_position = camera.global_position.lerp(target, CAM_LERP)
	camera.look_at(player.global_position + Vector3(0.0, 1.0, 0.0), Vector3.UP)
