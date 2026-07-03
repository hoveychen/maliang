extends SceneTree
## 临时视觉验证：红色胶囊 walker 沿 Pathfinder 路径移动，黄色轨迹点标记走过的路。
## walker 自管理（不进 world.npcs），每帧强制 focus_logical，避免联网世界替换/抢镜头。
## SCENARIO=pond|house|mountain（默认 pond）
## 运行: SCENARIO=pond godot --write-movie screenshots/f.png --fixed-fps 10 --quit-after 100 --script res://test/test_visual_pathfinding.gd

const DT := 0.1  ## 与 --fixed-fps 10 对应

var scene: Node
var walker: MeshInstance3D
var dict := {}
var ex: BehaviorExecutor
var focus := Vector2.ZERO
var trail_t := 0.0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var scenario := OS.get_environment("SCENARIO")
	if scenario.is_empty():
		scenario = "pond"
	var start: Vector2
	var goal: Vector2
	match scenario:
		"house":
			start = TerrainMap.tile_center(Vector2i(18, 63))
			goal = TerrainMap.tile_center(Vector2i(28, 63))
			focus = TerrainMap.tile_center(Vector2i(23, 63))
		"mountain":
			start = TerrainMap.tile_center(Vector2i(26, 6))
			goal = TerrainMap.tile_center(Vector2i(37, 6))
			focus = TerrainMap.tile_center(Vector2i(36, 9))
		_:
			start = TerrainMap.tile_center(Vector2i(24, 31))
			goal = TerrainMap.tile_center(Vector2i(24, 17))
			focus = TerrainMap.tile_center(Vector2i(24, 24))
	scene.ready.connect(func() -> void: _setup(scenario, start, goal))
	process_frame.connect(_tick)

func _setup(scenario: String, start: Vector2, goal: Vector2) -> void:
	if scenario == "house":
		# 用占用矩形模拟 4×3 tile 的房子，红色半透明盒可视化
		OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(21, 61)), 8, 6)
		_add_house_box(Vector2i(21, 61), 4, 3)
	walker = MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = 0.6
	m.height = 2.4
	walker.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.15, 0.1)
	walker.material_override = mat
	scene.add_child(walker)
	dict = { "logical": start, "id": "vtest_walker" }
	OccupancyMap.char_register("vtest_walker", start, 2)
	ex = BehaviorExecutor.new()
	ex.setup(dict, { "commands": [ { "type": "move_to", "params": { "target": [goal.x, goal.y] } } ] })

func _tick() -> void:
	if scene == null or ex == null or walker == null:
		return
	scene.set("focus_override", focus) # 抢回镜头（相机默认跟随玩家/联网世界聚焦小神仙）
	scene.set("focus_logical", focus)
	if not ex.is_done():
		ex.step(DT)
	_place(walker, dict["logical"], 1.4)
	trail_t += DT
	if trail_t >= 0.3:
		trail_t = 0.0
		var dot := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.28
		sm.height = 0.56
		dot.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.9, 0.1)
		dot.material_override = mat
		scene.add_child(dot)
		_place(dot, dict["logical"], 0.4)

## 与 world._reposition_npcs/_place_on_bent_ground 同一公式摆到弯曲地表。
func _place(node: Node3D, logical: Vector2, y_off: float) -> void:
	var d := WorldGrid.shortest_delta(focus, logical)
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(logical))) * TerrainMap.STEP_HEIGHT
	var drop := BendMat.CURVATURE * (d.x * d.x + d.y * d.y)
	node.position = Vector3(d.x, ty + y_off - drop, d.y)

func _add_house_box(tile_origin: Vector2i, w_tiles: int, h_tiles: int) -> void:
	var box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(float(w_tiles) * WorldGrid.TILE_SIZE, 3.0, float(h_tiles) * WorldGrid.TILE_SIZE)
	box.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.2, 0.2, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material_override = mat
	scene.add_child(box)
	var center := Vector2(
		(float(tile_origin.x) + float(w_tiles) * 0.5) * WorldGrid.TILE_SIZE,
		(float(tile_origin.y) + float(h_tiles) * 0.5) * WorldGrid.TILE_SIZE)
	_place(box, center, 1.5)
