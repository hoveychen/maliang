extends Node3D
## Demo 世界控制器（P5）。
## 浮动原点 + chunk streaming + world-bending + HD-2D 纸片角色 + 点击进交互模式。
## 逻辑/数据是纯平铺环面；弯曲只在渲染。角色精灵不走 shader，改用 CPU 复算
## 弯曲量、沿相机上方向落到弯曲地表（曲面世界放置物体的通用解法）。

const PLAYER_SPEED := 12.0
const CAM_OFFSET := Vector3(0.0, 15.0, 13.0)
const PICK_RADIUS_PX := 80.0

var player_logical := Vector2.ZERO
var camera: Camera3D
var chunk_manager: ChunkManager
var coord_label: Label
var banner: Label

var critter_tex: Texture2D
var ear_tex: Texture2D
var player_char: PaperCharacter
var npcs: Array = []              ## [{ node:PaperCharacter, logical:Vector2 }]
var selected: PaperCharacter = null
var ear_icon: Sprite3D
var _cam_up := Vector3.UP         ## 相机上方向（固定），弯曲补偿用

func _ready() -> void:
	critter_tex = load("res://assets/critter.svg")
	ear_tex = load("res://assets/ear.svg")
	_setup_environment()
	chunk_manager = ChunkManager.new()
	chunk_manager.name = "ChunkManager"
	add_child(chunk_manager)
	_setup_camera()
	_setup_player()
	_setup_npcs()
	_setup_ear()
	_setup_hud()

func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-55.0, -40.0, 0.0)
	light.light_energy = 1.15
	light.shadow_enabled = false  # 弯曲后阴影投影会错位
	add_child(light)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.82, 0.97)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.78, 0.85)
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 58.0
	camera.far = 600.0
	add_child(camera)
	camera.global_position = CAM_OFFSET
	camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	_cam_up = camera.global_transform.basis.y

func _setup_player() -> void:
	player_char = PaperCharacter.new()
	add_child(player_char)
	player_char.setup(critter_tex, Color(0.96, 0.62, 0.42), "你")
	_place_on_bent_ground(player_char, Vector3.ZERO)

func _setup_npcs() -> void:
	var defs := [
		{ "logical": Vector2(10.0, -10.0), "color": Color(0.62, 0.80, 1.0), "name": "小蓝" },
		{ "logical": Vector2(-11.0, -9.0), "color": Color(0.70, 1.0, 0.62), "name": "小绿" },
		{ "logical": Vector2(1.0, -18.0), "color": Color(1.0, 0.82, 0.5), "name": "小黄" },
	]
	for d in defs:
		var npc := PaperCharacter.new()
		add_child(npc)
		npc.setup(critter_tex, d["color"], d["name"])
		npcs.append({ "node": npc, "logical": d["logical"] })

func _setup_ear() -> void:
	ear_icon = Sprite3D.new()
	ear_icon.texture = ear_tex
	ear_icon.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	ear_icon.pixel_size = 0.02
	ear_icon.shaded = false
	ear_icon.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	ear_icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	ear_icon.visible = false
	add_child(ear_icon)

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	coord_label = Label.new()
	coord_label.position = Vector2(16.0, 12.0)
	_style_label(coord_label, 22)
	layer.add_child(coord_label)

	banner = Label.new()
	banner.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	banner.offset_top = -96.0
	banner.offset_bottom = -36.0
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_label(banner, 28)
	banner.visible = false
	layer.add_child(banner)

func _style_label(l: Label, size: int) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)

func _physics_process(delta: float) -> void:
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if input != Vector2.ZERO:
		player_logical = WorldGrid.wrap_pos(player_logical + input * PLAYER_SPEED * delta)

func _process(_delta: float) -> void:
	chunk_manager.update(player_logical)
	_place_on_bent_ground(player_char, Vector3.ZERO)
	_reposition_npcs()
	_update_ear()
	_update_hud()

func _reposition_npcs() -> void:
	for n in npcs:
		var d: Vector2 = WorldGrid.shortest_delta(player_logical, n["logical"])
		_place_on_bent_ground(n["node"], Vector3(d.x, 0.0, d.y))

## 把节点放到「弯曲后」的地表位置：先算视图空间弯曲下沉量，再沿相机上方向补偿。
func _place_on_bent_ground(node: Node3D, base_world: Vector3) -> void:
	var vp := camera.global_transform.affine_inverse() * base_world
	var drop := BendMat.CURVATURE * (vp.x * vp.x + vp.z * vp.z)
	node.global_position = base_world - _cam_up * drop

func _update_ear() -> void:
	if selected != null and is_instance_valid(selected):
		ear_icon.visible = true
		ear_icon.global_position = selected.global_position + Vector3(0.0, 3.6, 0.0)
	else:
		ear_icon.visible = false

func _update_hud() -> void:
	var t := WorldGrid.to_tile(player_logical)
	coord_label.text = "tile (%d, %d)  /  %d×%d  环面循环" % [t.x, t.y, WorldGrid.GRID_TILES, WorldGrid.GRID_TILES]

func _unhandled_input(event: InputEvent) -> void:
	var p := Vector2.INF
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		p = event.position
	elif event is InputEventScreenTouch and event.pressed:
		p = event.position
	if p == Vector2.INF:
		return
	var hit := _pick_npc(p)
	if hit != null:
		_enter_interaction(hit)
	else:
		_exit_interaction()

## 屏幕空间拾取：精灵未弯曲，其屏幕位置 = unproject(实际渲染坐标)，与点击对比。
func _pick_npc(screen_pos: Vector2) -> PaperCharacter:
	var best: PaperCharacter = null
	var best_d := PICK_RADIUS_PX
	for n in npcs:
		var node: PaperCharacter = n["node"]
		var wp := node.global_position + Vector3(0.0, 1.6, 0.0)
		if camera.is_position_behind(wp):
			continue
		var sp := camera.unproject_position(wp)
		var dd := screen_pos.distance_to(sp)
		if dd < best_d:
			best_d = dd
			best = node
	return best

func _enter_interaction(npc: PaperCharacter) -> void:
	selected = npc
	banner.text = "正在聆听 %s …    点一下开始说话  ·  点空白处退出" % npc.char_name
	banner.visible = true

func _exit_interaction() -> void:
	selected = null
	banner.visible = false
