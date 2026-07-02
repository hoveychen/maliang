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
const HOUSE_SCALE := 7.0  ## 微缩民居(0.93m 高) → ~6.5m

## slot 数组，每项 { root:Node3D, tile:MeshInstance3D, deco:Node3D, wrapped:Vector2i }
var _slots: Array = []
## wrapped 区块索引 → 逐 tile autotile 地面 ArrayMesh。全世界只有 3×3 个
## wrapped 区块，mesh 各建一次后永久缓存（首帧 9 次，之后零开销）。
var _chunk_meshes: Dictionary = {}
## 所有地面共享一个 atlas 材质（颜色全烘在 TerrainAtlas 里，albedo 置白）。
var _ground_mat: ShaderMaterial = null

func _ready() -> void:
	for i in range(-R, R + 1):
		for j in range(-R, R + 1):
			_slots.append(_make_slot())

func _make_slot() -> Dictionary:
	if _ground_mat == null:
		_ground_mat = BendMat.make_textured(TerrainAtlas.texture(), Color.WHITE, 0.95)
	var root := Node3D.new()
	add_child(root)
	var tile := MeshInstance3D.new()
	tile.material_override = _ground_mat
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

## 按 wrapped 索引刷新区块外观（autotile 地面 + 确定性装饰）。
## 地面棋盘/路/水全部由 TerrainMap+TerrainAtlas 决定，不再逐区块调色。
func _skin(slot: Dictionary, wrapped: Vector2i) -> void:
	var tile: MeshInstance3D = slot["tile"]
	tile.mesh = _chunk_mesh(wrapped)
	# 世界中心(chunk 1 = 3×3 网格中央，小神仙出生处)一片 3×3 区块为草原村庄。
	var in_village := absi(wrapped.x - 1) <= 1 and absi(wrapped.y - 1) <= 1

	var deco: Node3D = slot["deco"]
	for c in deco.get_children():
		c.queue_free()

	# L1 摆放网格化：装饰全部吸附 tile 中心，占地检查避让路/水（used 记录已占 tile）。
	var used := {}
	var base := hash(wrapped)
	if in_village:
		# 村庄区块：约一半放房子(其余点缀树)，避免小世界里全是屋顶。
		# 中心区块(1,1)是小神仙出生地 → 水井坐镇广场（地标特批压路），空地不盖房。
		if wrapped == Vector2i(1, 1):
			_spawn_on_tile(deco, used, wrapped, WELL_SCENE, Vector2i(12, 12), 4.5, 0.0, 1, 0, true)
			_tree_on_tile(deco, used, wrapped, Vector2i(5, 6), base + 5)
		elif posmod(wrapped.x + wrapped.y, 2) == 0:
			_house_on_tile(deco, used, wrapped, Vector2i(12, 12), base)
			_tree_on_tile(deco, used, wrapped, Vector2i(21, 20), base + 7)
		else:
			_tree_on_tile(deco, used, wrapped, Vector2i(7, 18), base)
			_tree_on_tile(deco, used, wrapped, Vector2i(19, 7), base + 3)
			if wrapped == Vector2i(0, 1):  # 一座风车当村庄地标
				_spawn_on_tile(deco, used, wrapped, WINDMILL_SCENE, Vector2i(13, 4), HOUSE_SCALE, 180.0, 1, 3)
		_scatter(deco, used, wrapped, base, 4)
	else:
		# 旷野区块：散布 2~3 棵树（当前 3×3 世界全是村庄，此分支为世界扩容预留）
		var count := 2 + posmod(base, 2)
		for k in range(count):
			var hk := hash(Vector3i(wrapped.x, wrapped.y, k))
			if posmod(hk, 4) == 0:
				continue  # 少量空位，避免太规整
			var ti := Vector2i(1 + posmod(hk, CHUNK_TILES - 2), 1 + posmod(hk / 1000, CHUNK_TILES - 2))
			_tree_on_tile(deco, used, wrapped, ti, hk)
		_scatter(deco, used, wrapped, base + 11, 6)

## 构建（或取缓存）一个 wrapped 区块的地面 ArrayMesh：
## 25×25 tile，每 tile 按 Autotile 拆 4 个半 tile 角 quad，UV 指向 atlas 对应变体 cell。
## 顶点在区块局部坐标（区块中心为原点，与旧 PlaneMesh 一致）；quad 1m 见方，
## 比旧 subdivide 12 更密，world_bend 顶点位移更平滑。
func _chunk_mesh(wrapped: Vector2i) -> ArrayMesh:
	if _chunk_meshes.has(wrapped):
		return _chunk_meshes[wrapped]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var base_tile := wrapped * CHUNK_TILES
	var half := CHUNK_WORLD * 0.5
	var half_tile := WorldGrid.TILE_SIZE * 0.5
	for j in range(CHUNK_TILES):
		for i in range(CHUNK_TILES):
			var t := base_tile + Vector2i(i, j)
			var ttype := TerrainMap.tile_type(t)
			var h := TerrainMap.tile_height(t)
			var y := float(h) * TerrainMap.STEP_HEIGHT
			var parity := posmod(t.x + t.y, 2)
			# 角变体与取图类型：路/水走同类过渡；草地在有更低邻居时换悬崖边草皮
			var uv_type := ttype
			var corners := PackedInt32Array([0, 0, 0, 0])  # 平草地不看变体
			if ttype != TerrainMap.T_GRASS:
				var same := func(q: Vector2i) -> bool: return TerrainMap.tile_type(q) == ttype
				corners = Autotile.corners_from_mask(Autotile.mask_of(t, same))
			elif h > 0:
				var not_lower := func(q: Vector2i) -> bool: return TerrainMap.tile_height(q) >= h
				var mask := Autotile.mask_of(t, not_lower)
				if mask != 255:
					uv_type = TerrainAtlas.CLIFF_RIM
					corners = Autotile.corners_from_mask(mask)
			var x0 := -half + float(i) * WorldGrid.TILE_SIZE
			var z0 := -half + float(j) * WorldGrid.TILE_SIZE
			for c in range(4):
				var cx := x0 + (half_tile if (c == Autotile.C_NE or c == Autotile.C_SE) else 0.0)
				var cz := z0 + (half_tile if (c == Autotile.C_SW or c == Autotile.C_SE) else 0.0)
				var r := TerrainAtlas.uv_rect(uv_type, c, corners[c], parity)
				_emit_quad(verts, norms, uvs, idx, cx, cz, y, half_tile, r)
			# L3 侧壁：邻居更低的边，从邻居高度到本 tile 高度逐级发墙 quad
			if h > 0:
				_emit_walls(verts, norms, uvs, idx, t, h, x0, z0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_chunk_meshes[wrapped] = mesh
	return mesh

## 水平角 quad：NW/NE/SE/SW 顶点序，从上往下看顺时针（Godot 正面绕序）。
func _emit_quad(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, idx: PackedInt32Array, cx: float, cz: float, y: float, size: float, r: Rect2) -> void:
	var b := verts.size()
	verts.append(Vector3(cx, y, cz))
	verts.append(Vector3(cx + size, y, cz))
	verts.append(Vector3(cx + size, y, cz + size))
	verts.append(Vector3(cx, y, cz + size))
	for k in range(4):
		norms.append(Vector3.UP)
	uvs.append(r.position)
	uvs.append(Vector2(r.end.x, r.position.y))
	uvs.append(r.end)
	uvs.append(Vector2(r.position.x, r.end.y))
	idx.append_array(PackedInt32Array([b, b + 1, b + 2, b, b + 2, b + 3]))

## tile 四边中「邻居更低」的边发竖直崖壁。每级 = 一个 2m×2m 墙格，
## 墙格对同一墙面的 8 邻墙格（沿墙走向左右 × 层级上下 × 对角）做 corner autotile：
## 有邻墙 = 相连，无邻墙侧出凹缝暗边 + 亮棱线。墙格再切 4 个 1m 角 quad 按变体取 UV。
## tile 局部范围 [x0, x0+2]×[z0, z0+2]，本 tile 高 h 级。
func _emit_walls(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, idx: PackedInt32Array, t: Vector2i, h: int, x0: float, z0: float) -> void:
	var ts := WorldGrid.TILE_SIZE
	var x1 := x0 + ts
	var z1 := z0 + ts
	# 每边：邻居偏移 n / 墙面法线 / 上边两端点 a→b（从法线侧看去 a 在屏幕左）/
	# 沿墙走向的 tile 切向 tang（= a→b 方向，保证掩码的"右"= 画面右）
	var sides := [
		{ "n": Vector2i(0, 1), "normal": Vector3.BACK, "a": Vector3(x0, 0, z1), "b": Vector3(x1, 0, z1), "tang": Vector2i(1, 0) },
		{ "n": Vector2i(0, -1), "normal": Vector3.FORWARD, "a": Vector3(x1, 0, z0), "b": Vector3(x0, 0, z0), "tang": Vector2i(-1, 0) },
		{ "n": Vector2i(1, 0), "normal": Vector3.RIGHT, "a": Vector3(x1, 0, z1), "b": Vector3(x1, 0, z0), "tang": Vector2i(0, -1) },
		{ "n": Vector2i(-1, 0), "normal": Vector3.LEFT, "a": Vector3(x0, 0, z0), "b": Vector3(x0, 0, z1), "tang": Vector2i(0, 1) },
	]
	for s in sides:
		var n_off: Vector2i = s["n"]
		var tang: Vector2i = s["tang"]
		var nh := TerrainMap.tile_height(t + n_off)
		for lvl in range(nh, h):
			# (q.x, q.y) = (沿墙偏移, 视觉上下偏移)；atlas 的 N(-1) = 上一级
			var pred := func(q: Vector2i) -> bool:
				return _wall_exists(t + tang * q.x, n_off, lvl - q.y)
			var corners := Autotile.corners_from_mask(Autotile.mask_of(Vector2i.ZERO, pred))
			var y_top := float(lvl + 1) * TerrainMap.STEP_HEIGHT
			var y_mid := (float(lvl) + 0.5) * TerrainMap.STEP_HEIGHT
			var y_bot := float(lvl) * TerrainMap.STEP_HEIGHT
			var a: Vector3 = s["a"]
			var b_: Vector3 = s["b"]
			var mid := (a + b_) * 0.5
			for c in range(4):
				var right := c == Autotile.C_NE or c == Autotile.C_SE
				var lower := c == Autotile.C_SW or c == Autotile.C_SE
				var h0 := mid if right else a
				var h1 := b_ if right else mid
				var yt := y_mid if lower else y_top
				var yb := y_bot if lower else y_mid
				var r := TerrainAtlas.uv_rect(TerrainAtlas.CLIFF_WALL, c, corners[c], 0)
				var base := verts.size()
				verts.append(Vector3(h0.x, yt, h0.z))
				verts.append(Vector3(h1.x, yt, h1.z))
				verts.append(Vector3(h1.x, yb, h1.z))
				verts.append(Vector3(h0.x, yb, h0.z))
				for k in range(4):
					norms.append(s["normal"])
				uvs.append(r.position)
				uvs.append(Vector2(r.end.x, r.position.y))
				uvs.append(r.end)
				uvs.append(Vector2(r.position.x, r.end.y))
				idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

## 墙格存在性：tile 在 lvl 层朝 n_off 方向有裸露墙面
## （本 tile 高过该层，且该方向邻居的地面在该层或以下）。
func _wall_exists(tile: Vector2i, n_off: Vector2i, lvl: int) -> bool:
	return TerrainMap.tile_height(tile) > lvl and lvl >= TerrainMap.tile_height(tile + n_off)

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

## 确定性散布小装饰（灌木/石头/草丛）：hash 出候选 tile，
## 非空闲草地就跳过（填充物不强求），并让开区块中心（房子/水井占位）。
func _scatter(parent: Node3D, used: Dictionary, wrapped: Vector2i, seed_h: int, count: int) -> void:
	for k in range(count):
		var hk := hash(Vector3i(wrapped.x + 97, wrapped.y, seed_h + k))
		var ti := Vector2i(posmod(hk, CHUNK_TILES), posmod(hk / 1000, CHUNK_TILES))
		var pos := _tile_local(ti, wrapped)
		if Vector2(pos.x, pos.z).length() < CHUNK_WORLD * 0.14:
			continue
		if not _footprint_free(used, wrapped, ti, 0, false):
			continue
		used[ti] = true
		var kind := posmod(hk / 7, 5)
		if kind == 0:
			_spawn(parent, ROCK_SCENES[posmod(hk, ROCK_SCENES.size())], pos, 1.6 + float(posmod(hk, 3)) * 0.4, float(posmod(hk, 360)))
		elif kind <= 2:
			_spawn(parent, BUSH_SCENES[posmod(hk, BUSH_SCENES.size())], pos, 4.0 + float(posmod(hk, 3)), float(posmod(hk, 360)))
		else:
			_spawn(parent, TUFT_SCENES[posmod(hk, TUFT_SCENES.size())], pos, 1.8, float(posmod(hk, 360)))

## L1 摆放核心：把场景吸附到 tile 中心。anchor 是区块内 tile 索引(0..24)²，
## 占地或压路/水时沿螺旋环向外找至多 search 圈；reserve 是占地半径（0→1×1，1→3×3）。
## allow_path 供地标（水井）压路。找不到空位就放弃（确定性，不摆歪）。
func _spawn_on_tile(parent: Node3D, used: Dictionary, wrapped: Vector2i, scene: PackedScene, anchor: Vector2i, scale_f: float, yaw_deg: float, reserve := 0, search := 0, allow_path := false) -> void:
	for r in range(search + 1):
		for ti in _ring(anchor, r):
			if not _footprint_free(used, wrapped, ti, reserve, allow_path):
				continue
			for dz in range(-reserve, reserve + 1):
				for dx in range(-reserve, reserve + 1):
					used[ti + Vector2i(dx, dz)] = true
			_spawn(parent, scene, _tile_local(ti, wrapped), scale_f, yaw_deg)
			return

## 半径 r 的方形环上的 tile（r=0 只有中心），确定性顺序。
func _ring(c: Vector2i, r: int) -> Array:
	if r == 0:
		return [c]
	var out: Array = []
	for d in range(-r, r + 1):
		out.append(c + Vector2i(d, -r))
		out.append(c + Vector2i(d, r))
	for d in range(-r + 1, r):
		out.append(c + Vector2i(-r, d))
		out.append(c + Vector2i(r, d))
	return out

## 以 ti 为中心、半径 reserve 的占地是否全为空闲草地（水永远不可占）。
## 脚印允许越过区块边界——TerrainMap 是全局环面数据，越界索引照常判定。
func _footprint_free(used: Dictionary, wrapped: Vector2i, ti: Vector2i, reserve: int, allow_path: bool) -> bool:
	for dz in range(-reserve, reserve + 1):
		for dx in range(-reserve, reserve + 1):
			var lt := ti + Vector2i(dx, dz)
			if used.has(lt):
				return false
			var ty := TerrainMap.tile_type(wrapped * CHUNK_TILES + lt)
			if ty == TerrainMap.T_WATER or (ty == TerrainMap.T_PATH and not allow_path):
				return false
	return true

## 区块内 tile 索引 → 区块局部坐标（tile 中心，y 抬到 tile 台阶高度）。
func _tile_local(ti: Vector2i, wrapped: Vector2i) -> Vector3:
	var half := CHUNK_WORLD * 0.5
	var y := float(TerrainMap.tile_height(wrapped * CHUNK_TILES + ti)) * TerrainMap.STEP_HEIGHT
	return Vector3(
		-half + (float(ti.x) + 0.5) * WorldGrid.TILE_SIZE,
		y,
		-half + (float(ti.y) + 0.5) * WorldGrid.TILE_SIZE)

## 村庄民居：KayKit 各色小屋（微缩模型放大到 ~6.5m，占地 3×3 tile）。
func _house_on_tile(parent: Node3D, used: Dictionary, wrapped: Vector2i, anchor: Vector2i, h: int) -> void:
	var yaw := float(posmod(h, 4)) * 90.0
	_spawn_on_tile(parent, used, wrapped, HOUSE_SCENES[posmod(h, HOUSE_SCENES.size())], anchor, HOUSE_SCALE, yaw, 1, 4)

func _tree_on_tile(parent: Node3D, used: Dictionary, wrapped: Vector2i, anchor: Vector2i, h: int) -> void:
	var scale_f := 1.1 + float(h % 5) * 0.15
	_spawn_on_tile(parent, used, wrapped, TREE_SCENES[posmod(h, TREE_SCENES.size())], anchor, scale_f, float(posmod(h, 360)), 0, 2)
