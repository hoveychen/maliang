extends Node3D
## Demo 世界控制器。
## 浮动原点模型：玩家视觉固定在渲染原点 (0,0,0)，世界相对玩家滚动，
## 玩家的「逻辑坐标」(player_logical, XZ 世界单位) 用 WorldGrid 取模 wrap，
## 因此越过 GRID 边界时无跳变——平铺环面数据做无缝循环的关键。
## P2：坐标系统 + 地标柱子证明无缝 wrap + 调试标签。

const PLAYER_SPEED := 12.0
const CAM_OFFSET := Vector3(0.0, 15.0, 13.0)
const RENDER_RADIUS := 130.0  ## 超出此半径的地标暂时隐藏

## 玩家在环面世界上的逻辑坐标（世界单位，Vector2(x, z)）。
var player_logical := Vector2.ZERO

var camera: Camera3D
var world_root: Node3D
var landmarks: Array = []  ## [{ node, logical:Vector2 }]
var coord_label: Label

func _ready() -> void:
	_setup_environment()
	world_root = Node3D.new()
	world_root.name = "WorldRoot"
	add_child(world_root)
	_setup_ground()
	_setup_landmarks()
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

func _setup_ground() -> void:
	## P2 临时：一块跟随玩家原点的大草地（P3 换成 chunk 流送的真地形）。
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(300.0, 300.0)
	plane.subdivide_width = 60
	plane.subdivide_depth = 60
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.46, 0.72, 0.40)
	mat.roughness = 0.95
	ground.material_override = mat
	add_child(ground)  ## 直接挂在原点下，恒在玩家脚下

func _setup_landmarks() -> void:
	var span := WorldGrid.WORLD_SPAN
	var defs := [
		{ "logical": Vector2(0.0, 0.0), "color": Color(0.3, 0.8, 0.3) },        # 起点
		{ "logical": Vector2(24.0, 0.0), "color": Color(0.9, 0.3, 0.3) },       # 东
		{ "logical": Vector2(0.0, 24.0), "color": Color(0.3, 0.5, 0.95) },      # 北
		{ "logical": Vector2(span - 24.0, 0.0), "color": Color(0.95, 0.85, 0.2) }, # 接缝西侧
		{ "logical": Vector2(12.0, span - 12.0), "color": Color(0.7, 0.35, 0.85) }, # 接缝南侧
	]
	for d in defs:
		var pillar := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.6, 5.0, 1.6)
		pillar.mesh = box
		var m := StandardMaterial3D.new()
		m.albedo_color = d["color"]
		pillar.material_override = m
		world_root.add_child(pillar)
		landmarks.append({ "node": pillar, "logical": d["logical"] })

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
	_reposition_world()
	_update_hud()

## 以玩家为中心：每个地标放到离渲染原点最近的等价位置。
func _reposition_world() -> void:
	for lm in landmarks:
		var d: Vector2 = WorldGrid.shortest_delta(player_logical, lm["logical"])
		var node: MeshInstance3D = lm["node"]
		if d.length() > RENDER_RADIUS:
			node.visible = false
		else:
			node.visible = true
			node.position = Vector3(d.x, 2.5, d.y)

func _update_hud() -> void:
	if coord_label == null:
		return
	var t := WorldGrid.to_tile(player_logical)
	coord_label.text = "tile (%d, %d)  /  %d×%d  环面循环" % [t.x, t.y, WorldGrid.GRID_TILES, WorldGrid.GRID_TILES]
