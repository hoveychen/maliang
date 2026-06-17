class_name ChunkManager
extends Node3D
## 区块流送（chunk streaming）。
## 只实例化玩家周围 (2R+1)² 个区块，用对象池复用；每帧按最短环面位移
## 重定位每个 slot，并按「wrap 后的区块索引」决定外观（棋盘色 + 一棵确定性的树）。
## 越过 GRID 接缝时，区块 (39,·) 之后接 (0,·)，外观连续 → 无缝。

const CHUNK_TILES := 25
const CHUNK_WORLD := float(CHUNK_TILES) * WorldGrid.TILE_SIZE          ## 50.0
const CHUNKS_PER_SIDE := WorldGrid.GRID_TILES / CHUNK_TILES            ## 40
const R := 3                                                          ## 半径（区块数）→ 7×7

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
	tile.material_override = StandardMaterial3D.new()
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
	var mat: StandardMaterial3D = tile.material_override
	var checker := posmod(wrapped.x + wrapped.y, 2) == 0
	mat.albedo_color = Color(0.47, 0.73, 0.41) if checker else Color(0.41, 0.65, 0.35)
	mat.roughness = 0.95

	var deco: Node3D = slot["deco"]
	for c in deco.get_children():
		c.queue_free()

	# 确定性 hash：同一 wrapped 区块永远长一样 → 跨接缝可辨认其连续性
	var h := hash(wrapped)
	if (h % 5) != 0:  # ~80% 区块放一棵树
		var rx := (float(h % 1000) / 1000.0 - 0.5) * CHUNK_WORLD * 0.7
		var rz := (float((h / 1000) % 1000) / 1000.0 - 0.5) * CHUNK_WORLD * 0.7
		_add_tree(deco, Vector3(rx, 0.0, rz), h)

func _add_tree(parent: Node3D, pos: Vector3, h: int) -> void:
	var height := 2.5 + float(h % 7) * 0.5
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.25
	cyl.bottom_radius = 0.35
	cyl.height = height
	trunk.mesh = cyl
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(0.45, 0.3, 0.18)
	trunk.material_override = tm
	trunk.position = pos + Vector3(0.0, height * 0.5, 0.0)
	parent.add_child(trunk)

	var crown := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 1.6
	sph.height = 3.0
	crown.mesh = sph
	var cm := StandardMaterial3D.new()
	var g := 0.5 + float(h % 4) * 0.08
	cm.albedo_color = Color(0.2, g, 0.25)
	crown.material_override = cm
	crown.position = pos + Vector3(0.0, height + 0.6, 0.0)
	parent.add_child(crown)
