class_name ChunkManager
extends Node3D
## 区块流送（chunk streaming）。
## 只实例化玩家周围 (2R+1)² 个区块，用对象池复用；每帧按最短环面位移
## 重定位每个 slot，并按「wrap 后的区块索引」决定外观（棋盘色 + 一棵确定性的树）。
## 越过 GRID 接缝时，区块 (39,·) 之后接 (0,·)，外观连续 → 无缝。

const CHUNK_TILES := 25
const CHUNK_WORLD := float(CHUNK_TILES) * WorldGrid.TILE_SIZE          ## 50.0
const CHUNKS_PER_SIDE := WorldGrid.GRID_TILES / CHUNK_TILES            ## 3（75/25）
const R := 1                                                          ## 半径(区块)→ 3×3 = 正好整个小世界一遍，无重复
const RENDER_RADIUS := 110.0                                          ## 圆形渲染半径，覆盖全部 3×3（远处由雾渐隐）
## world-bending 在 GPU 位移顶点，但视锥裁剪按原始 AABB → 高处/远处网格会被误剔除。
## 给所有弯曲网格设大裁剪边距，避免接近屏幕边缘时整块消失。
const CULL_MARGIN := 220.0

## KayKit CC0 资产（见 assets/kaykit/*/License）。Hexagon 建筑是微缩比例，需放大。
const TREE_SCENES: Array[PackedScene] = [
	preload("res://assets/kaykit/forest/Tree_1_A_Color1.gltf"),
	preload("res://assets/kaykit/forest/Tree_1_B_Color1.gltf"),
	preload("res://assets/kaykit/forest/Tree_1_C_Color1.gltf"),
	preload("res://assets/kaykit/forest/Tree_2_A_Color1.gltf"),
	preload("res://assets/kaykit/forest/Tree_2_B_Color1.gltf"),
]
const BUSH_SCENES: Array[PackedScene] = [
	preload("res://assets/kaykit/forest/Bush_1_A_Color1.gltf"),
	preload("res://assets/kaykit/forest/Bush_1_B_Color1.gltf"),
	preload("res://assets/kaykit/forest/Bush_2_A_Color1.gltf"),
]
const ROCK_SCENES: Array[PackedScene] = [
	preload("res://assets/kaykit/forest/Rock_1_A_Color1.gltf"),
	preload("res://assets/kaykit/forest/Rock_1_B_Color1.gltf"),
	preload("res://assets/kaykit/forest/Rock_3_A_Color1.gltf"),
]
const TUFT_SCENES: Array[PackedScene] = [
	preload("res://assets/kaykit/forest/Grass_1_A_Color1.gltf"),
	preload("res://assets/kaykit/forest/Grass_2_A_Color1.gltf"),
]
const HOUSE_SCENES: Array[PackedScene] = [
	preload("res://assets/kaykit/hexagon/building_home_A_blue.gltf"),
	preload("res://assets/kaykit/hexagon/building_home_A_red.gltf"),
	preload("res://assets/kaykit/hexagon/building_home_B_yellow.gltf"),
	preload("res://assets/kaykit/hexagon/building_home_B_green.gltf"),
]
const WELL_SCENE: PackedScene = preload("res://assets/kaykit/hexagon/building_well_blue.gltf")
const WINDMILL_SCENE: PackedScene = preload("res://assets/kaykit/hexagon/building_windmill_red.gltf")
const GRASS_TEX: Texture2D = preload("res://assets/textures/grass_tile.png")
## 50m 区块平铺 12 次 → 纹理一格 ~4.2m、三角 ~0.5m（动森草纹尺度）；整数次平铺保证区块间无缝
const GRASS_UV_SCALE := Vector2(12.0, 12.0)
const HOUSE_SCALE := 7.0  ## 微缩民居(0.93m 高) → ~6.5m

## slot 数组，每项 { root:Node3D, tile:MeshInstance3D, deco:Node3D, wrapped:Vector2i }
var _slots: Array = []

func _ready() -> void:
	for i in range(-R, R + 1):
		for j in range(-R, R + 1):
			_slots.append(_make_slot())

func _make_slot() -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var tile := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(CHUNK_WORLD, CHUNK_WORLD)
	plane.subdivide_width = 12
	plane.subdivide_depth = 12
	tile.mesh = plane
	tile.material_override = BendMat.make_textured(GRASS_TEX, Color.WHITE, 0.95, GRASS_UV_SCALE)
	tile.extra_cull_margin = CULL_MARGIN
	root.add_child(tile)
	var deco := Node3D.new()
	root.add_child(deco)
	return { "root": root, "tile": tile, "deco": deco, "wrapped": Vector2i(-999, -999) }

func update(player_logical: Vector2) -> void:
	var pcx := int(floor(player_logical.x / CHUNK_WORLD))
	var pcz := int(floor(player_logical.y / CHUNK_WORLD))
	var idx := 0
	for i in range(-R, R + 1):
		for j in range(-R, R + 1):
			var cx := pcx + i
			var cz := pcz + j
			# 区块中心的逻辑坐标
			var center_logical := Vector2(
				(float(cx) + 0.5) * CHUNK_WORLD,
				(float(cz) + 0.5) * CHUNK_WORLD)
			var d := WorldGrid.shortest_delta(player_logical, center_logical)
			var slot: Dictionary = _slots[idx]
			var root: Node3D = slot["root"]
			root.position = Vector3(d.x, 0.0, d.y)
			# 圆形裁剪：超出半径的区块隐藏 → 圆形地平线，无正方形四角对角缺口
			root.visible = d.length() < RENDER_RADIUS
			# wrap 后的区块索引决定外观
			var wrapped := Vector2i(
				posmod(cx, CHUNKS_PER_SIDE),
				posmod(cz, CHUNKS_PER_SIDE))
			if wrapped != slot["wrapped"]:
				slot["wrapped"] = wrapped
				_skin(slot, wrapped)
			idx += 1

## 按 wrapped 索引刷新区块外观（棋盘色 + 确定性装饰）。
func _skin(slot: Dictionary, wrapped: Vector2i) -> void:
	var tile: MeshInstance3D = slot["tile"]
	var mat: ShaderMaterial = tile.material_override
	var checker := posmod(wrapped.x + wrapped.y, 2) == 0
	# 世界中心(chunk 1 = 3×3 网格中央，小神仙出生处)一片 3×3 区块为草原村庄。
	var in_village := absi(wrapped.x - 1) <= 1 and absi(wrapped.y - 1) <= 1
	var col: Color
	if in_village:
		col = Color(0.55, 0.78, 0.48) if checker else Color(0.5, 0.72, 0.43)
	else:
		col = Color(0.47, 0.73, 0.41) if checker else Color(0.41, 0.65, 0.35)
	mat.set_shader_parameter("albedo", col)

	var deco: Node3D = slot["deco"]
	for c in deco.get_children():
		c.queue_free()

	var base := hash(wrapped)
	if in_village:
		# 村庄区块：约一半放房子(其余点缀树)，避免小世界里全是屋顶。
		# 中心区块(1,1)是小神仙出生地 → 村口水井 + 空地，不盖房压住角色。
		if wrapped == Vector2i(1, 1):
			_spawn(deco, WELL_SCENE, Vector3(CHUNK_WORLD * 0.16, 0.0, -CHUNK_WORLD * 0.12), 4.5, 0.0)
			_add_tree(deco, Vector3(-CHUNK_WORLD * 0.3, 0.0, -CHUNK_WORLD * 0.26), base + 5)
		elif posmod(wrapped.x + wrapped.y, 2) == 0:
			_add_house(deco, Vector3(0.0, 0.0, 0.0), base)
			_add_tree(deco, Vector3(CHUNK_WORLD * 0.34, 0.0, CHUNK_WORLD * 0.30), base + 7)
		else:
			_add_tree(deco, Vector3(-CHUNK_WORLD * 0.22, 0.0, CHUNK_WORLD * 0.24), base)
			_add_tree(deco, Vector3(CHUNK_WORLD * 0.28, 0.0, -CHUNK_WORLD * 0.2), base + 3)
			if wrapped == Vector2i(0, 1):  # 一座风车当村庄地标
				_spawn(deco, WINDMILL_SCENE, Vector3(CHUNK_WORLD * 0.05, 0.0, -CHUNK_WORLD * 0.34), HOUSE_SCALE, 180.0)
		_scatter(deco, wrapped, base, 4)
	else:
		# 旷野区块：散布 2~3 棵树
		var count := 2 + posmod(base, 2)
		for k in range(count):
			var hk := hash(Vector3i(wrapped.x, wrapped.y, k))
			if posmod(hk, 4) == 0:
				continue  # 少量空位，避免太规整
			var rx := (float(posmod(hk, 1000)) / 1000.0 - 0.5) * CHUNK_WORLD * 0.85
			var rz := (float(posmod(hk / 1000, 1000)) / 1000.0 - 0.5) * CHUNK_WORLD * 0.85
			_add_tree(deco, Vector3(rx, 0.0, rz), hk)
		_scatter(deco, wrapped, base + 11, 6)

## 实例化 KayKit 场景：包裹 bend 材质 + 大裁剪边距（弯曲位移会超出原始 AABB）。
func _spawn(parent: Node3D, scene: PackedScene, pos: Vector3, scale_f: float, yaw_deg: float) -> Node3D:
	var inst := scene.instantiate() as Node3D
	inst.position = pos
	inst.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	inst.scale = Vector3.ONE * scale_f
	parent.add_child(inst)
	BendMat.wrap_scene(inst)
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		mi.extra_cull_margin = CULL_MARGIN
	return inst

## 确定性散布小装饰（灌木/石头/草丛），避开区块中心（房子/水井占位）。
func _scatter(parent: Node3D, wrapped: Vector2i, seed_h: int, count: int) -> void:
	for k in range(count):
		var hk := hash(Vector3i(wrapped.x + 97, wrapped.y, seed_h + k))
		var rx := (float(posmod(hk, 1000)) / 1000.0 - 0.5) * CHUNK_WORLD * 0.9
		var rz := (float(posmod(hk / 1000, 1000)) / 1000.0 - 0.5) * CHUNK_WORLD * 0.9
		if Vector2(rx, rz).length() < CHUNK_WORLD * 0.18:
			continue
		var pos := Vector3(rx, 0.0, rz)
		var kind := posmod(hk / 7, 5)
		if kind == 0:
			_spawn(parent, ROCK_SCENES[posmod(hk, ROCK_SCENES.size())], pos, 1.6 + float(posmod(hk, 3)) * 0.4, float(posmod(hk, 360)))
		elif kind <= 2:
			_spawn(parent, BUSH_SCENES[posmod(hk, BUSH_SCENES.size())], pos, 4.0 + float(posmod(hk, 3)), float(posmod(hk, 360)))
		else:
			_spawn(parent, TUFT_SCENES[posmod(hk, TUFT_SCENES.size())], pos, 1.8, float(posmod(hk, 360)))

## 村庄民居：KayKit 各色小屋（微缩模型放大到 ~6.5m）。
func _add_house(parent: Node3D, pos: Vector3, h: int) -> void:
	var yaw := float(posmod(h, 4)) * 90.0
	_spawn(parent, HOUSE_SCENES[posmod(h, HOUSE_SCENES.size())], pos, HOUSE_SCALE, yaw)

func _add_tree(parent: Node3D, pos: Vector3, h: int) -> void:
	var scale_f := 1.1 + float(h % 5) * 0.15
	_spawn(parent, TREE_SCENES[posmod(h, TREE_SCENES.size())], pos, scale_f, float(posmod(h, 360)))
