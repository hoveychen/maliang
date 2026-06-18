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
	tile.material_override = BendMat.make(Color.WHITE)
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
		# 村庄区块：约一半放房子(其余点缀树)，避免小世界里全是屋顶
		if posmod(wrapped.x + wrapped.y, 2) == 0:
			_add_house(deco, Vector3(0.0, 0.0, 0.0), base)
			_add_tree(deco, Vector3(CHUNK_WORLD * 0.34, 0.0, CHUNK_WORLD * 0.30), base + 7)
		else:
			_add_tree(deco, Vector3(-CHUNK_WORLD * 0.22, 0.0, CHUNK_WORLD * 0.24), base)
			_add_tree(deco, Vector3(CHUNK_WORLD * 0.28, 0.0, -CHUNK_WORLD * 0.2), base + 3)
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

## 草原村庄的房子：彩色墙体 + 红屋顶（HD-2D 卡通风）。
func _add_house(parent: Node3D, pos: Vector3, h: int) -> void:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(6.0, 4.0, 6.0)
	body.mesh = box
	var walls := [Color(0.96, 0.86, 0.7), Color(0.92, 0.8, 0.85), Color(0.8, 0.88, 0.96)]
	body.material_override = BendMat.make(walls[posmod(h, walls.size())])
	body.extra_cull_margin = CULL_MARGIN
	body.position = pos + Vector3(0.0, 2.0, 0.0)
	parent.add_child(body)

	var roof := MeshInstance3D.new()
	var pyr := CylinderMesh.new()  # 4 边 + 顶半径 0 = 方锥屋顶
	pyr.top_radius = 0.0
	pyr.bottom_radius = 5.2
	pyr.height = 3.2
	pyr.radial_segments = 4
	roof.mesh = pyr
	roof.material_override = BendMat.make(Color(0.82, 0.4, 0.32))
	roof.extra_cull_margin = CULL_MARGIN
	roof.position = pos + Vector3(0.0, 5.6, 0.0)
	roof.rotation_degrees = Vector3(0.0, 45.0, 0.0)  # 对齐方形墙体
	parent.add_child(roof)

func _add_tree(parent: Node3D, pos: Vector3, h: int) -> void:
	var height := 2.5 + float(h % 7) * 0.5
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.25
	cyl.bottom_radius = 0.35
	cyl.height = height
	trunk.mesh = cyl
	trunk.material_override = BendMat.make(Color(0.45, 0.3, 0.18))
	trunk.extra_cull_margin = CULL_MARGIN
	trunk.position = pos + Vector3(0.0, height * 0.5, 0.0)
	parent.add_child(trunk)

	var crown := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 1.6
	sph.height = 3.0
	crown.mesh = sph
	var g := 0.5 + float(h % 4) * 0.08
	crown.material_override = BendMat.make(Color(0.2, g, 0.25))
	crown.extra_cull_margin = CULL_MARGIN
	crown.position = pos + Vector3(0.0, height + 0.6, 0.0)
	parent.add_child(crown)
