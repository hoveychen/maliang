extends Node3D
## Demo 世界控制器。
## 浮动原点模型：玩家视觉固定在渲染原点 (0,0,0)，世界相对玩家滚动，
## 玩家的「逻辑坐标」(player_logical, XZ 世界单位) 用 WorldGrid 取模 wrap，
## 因此越过 GRID 边界时无跳变——平铺环面数据做无缝循环的关键。
## P2：坐标系统 + 地标柱子证明无缝 wrap + 调试标签。

const PLAYER_SPEED := 12.0
const CAM_OFFSET := Vector3(0.0, 15.0, 13.0)

## 玩家在环面世界上的逻辑坐标（世界单位，Vector2(x, z)）。
var player_logical := Vector2.ZERO

var camera: Camera3D
var chunk_manager: ChunkManager
var coord_label: Label

func _ready() -> void:
	_setup_environment()
	chunk_manager = ChunkManager.new()
	chunk_manager.name = "ChunkManager"
	add_child(chunk_manager)
	_setup_player()
	_setup_camera()
	_setup_hud()

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

func _setup_player() -> void:
	var body := MeshInstance3D.new()
	body.name = "Player"
	var caps := CapsuleMesh.new()
	caps.radius = 0.4
	caps.height = 1.6
	body.mesh = caps
	body.position = Vector3(0.0, 0.8, 0.0)  ## 固定在渲染原点
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.92, 0.52, 0.32)
	body.material_override = pmat
	add_child(body)

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 58.0
	camera.far = 600.0
	add_child(camera)
	camera.global_position = CAM_OFFSET
	camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	coord_label = Label.new()
	coord_label.position = Vector2(16.0, 12.0)
	coord_label.add_theme_font_size_override("font_size", 22)
	coord_label.add_theme_color_override("font_color", Color.WHITE)
	coord_label.add_theme_color_override("font_outline_color", Color.BLACK)
	coord_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(coord_label)

func _physics_process(delta: float) -> void:
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if input != Vector2.ZERO:
		player_logical = WorldGrid.wrap_pos(player_logical + input * PLAYER_SPEED * delta)

func _process(_delta: float) -> void:
	chunk_manager.update(player_logical)
	_update_hud()

func _update_hud() -> void:
	if coord_label == null:
		return
	var t := WorldGrid.to_tile(player_logical)
	coord_label.text = "tile (%d, %d)  /  %d×%d  环面循环" % [t.x, t.y, WorldGrid.GRID_TILES, WorldGrid.GRID_TILES]
