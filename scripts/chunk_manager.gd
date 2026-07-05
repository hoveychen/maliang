class_name ChunkManager
extends Node3D
## 区块流送（chunk streaming）。
## 只实例化玩家周围 (2R+1)² 个区块，用对象池复用；每帧按最短环面位移
## 重定位每个 slot，并按「wrap 后的区块索引」决定外观（autotile 地面 + 布景）。
## 越过 GRID 接缝时，区块 (39,·) 之后接 (0,·)，外观连续 → 无缝。
##
## 布景两层：LANDMARKS 手工地标（民居/水井/风车/泉石，全局 tile 锚点）+
## _deco_kind 分区散布（按地形分西南密林/果园/山地岩/岸边苇/村核心/草甸，逐 tile 确定性）。

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

## 水彩地面贴图（CC0，assets/textures/watercolor）：世界 UV 平铺，控制图选域/调色。
const GRASS_TEX: Texture2D = preload("res://assets/textures/watercolor/grass.png")
const DIRT_TEX: Texture2D = preload("res://assets/textures/watercolor/dirt.png")
const STONE_TEX: Texture2D = preload("res://assets/textures/watercolor/stone.png")
const WATER_TEX: Texture2D = preload("res://assets/textures/watercolor/water.png")
## 各贴图全图均值（magick -resize 1x1 实测，sRGB）；shader 用 tex/mean 归一出细节层
const GRASS_MEAN := Color(72.0 / 255.0, 92.0 / 255.0, 39.0 / 255.0)
const DIRT_MEAN := Color(77.0 / 255.0, 48.0 / 255.0, 36.0 / 255.0)
const STONE_MEAN := Color(91.0 / 255.0, 91.0 / 255.0, 97.0 / 255.0)
const WATER_MEAN := Color(72.0 / 255.0, 122.0 / 255.0, 132.0 / 255.0)

## 手工地标（tile 为全局 tile 锚点；reserve=1 → 占地 3×3，找不到空位沿环外扩 search 圈）。
## 村核心 8 栋民居沿广场四角与辐路布置、水井坐镇广场（地标特批压路）、
## 风车立东南瞭望丘 h3 平台、两块泉石守着主峰南麓涌泉。
const LANDMARKS := [
	{ "scene": WELL_SCENE, "tile": Vector2i(37, 37), "scale": 4.5, "yaw": 0.0, "reserve": 1, "search": 0, "path_ok": true },
	{ "scene": WINDMILL_SCENE, "tile": Vector2i(59, 54), "scale": HOUSE_SCALE, "yaw": 180.0, "reserve": 1, "search": 1 },
	{ "scene": HOUSE_SCENES[0], "tile": Vector2i(31, 31), "scale": HOUSE_SCALE, "yaw": 90.0, "reserve": 1, "search": 2 },
	{ "scene": HOUSE_SCENES[1], "tile": Vector2i(44, 31), "scale": HOUSE_SCALE, "yaw": 180.0, "reserve": 1, "search": 2 },
	{ "scene": HOUSE_SCENES[2], "tile": Vector2i(31, 44), "scale": HOUSE_SCALE, "yaw": 90.0, "reserve": 1, "search": 2 },
	{ "scene": HOUSE_SCENES[3], "tile": Vector2i(44, 44), "scale": HOUSE_SCALE, "yaw": 270.0, "reserve": 1, "search": 2 },
	{ "scene": HOUSE_SCENES[1], "tile": Vector2i(27, 40), "scale": HOUSE_SCALE, "yaw": 0.0, "reserve": 1, "search": 2 },
	{ "scene": HOUSE_SCENES[0], "tile": Vector2i(47, 35), "scale": HOUSE_SCALE, "yaw": 180.0, "reserve": 1, "search": 2 },
	{ "scene": HOUSE_SCENES[2], "tile": Vector2i(34, 58), "scale": HOUSE_SCALE, "yaw": 90.0, "reserve": 1, "search": 2 },
	{ "scene": HOUSE_SCENES[3], "tile": Vector2i(33, 23), "scale": HOUSE_SCALE, "yaw": 270.0, "reserve": 1, "search": 2 },
	{ "scene": ROCK_SCENES[2], "tile": Vector2i(30, 12), "scale": 2.4, "yaw": 40.0 },
	{ "scene": ROCK_SCENES[0], "tile": Vector2i(28, 12), "scale": 1.7, "yaw": 210.0 },
]

## 分区散布的判定结果
const DECO_NONE := 0
const DECO_TREE := 1
const DECO_BUSH := 2
const DECO_ROCK := 3
const DECO_TUFT := 4

## slot 数组，每项 { root:Node3D, tile:MeshInstance3D, deco:Node3D, wrapped:Vector2i }
var _slots: Array = []
## wrapped 区块索引 → 逐 tile autotile 地面 ArrayMesh。全世界只有 3×3 个
## wrapped 区块，mesh 各建一次后永久缓存（首帧 9 次，之后零开销）。
var _chunk_meshes: Dictionary = {}
## 所有地面共享一个 atlas 材质（颜色全烘在 TerrainAtlas 里，albedo 置白）。
var _ground_mat: ShaderMaterial = null
## wrapped 区块 → 已向 OccupancyMap 登记的占地 [[origin_tile, w, h], ...]，重刷时释放。
var _claims: Dictionary = {}

func _ready() -> void:
	for i in range(-R, R + 1):
		for j in range(-R, R + 1):
			_slots.append(_make_slot())

func _make_slot() -> Dictionary:
	if _ground_mat == null:
		_ground_mat = _make_ground_mat()
	var root := Node3D.new()
	add_child(root)
	var tile := MeshInstance3D.new()
	tile.material_override = _ground_mat
	tile.extra_cull_margin = CULL_MARGIN
	root.add_child(tile)
	var deco := Node3D.new()
	root.add_child(deco)
	return { "root": root, "tile": tile, "deco": deco, "wrapped": Vector2i(-999, -999) }

## 地形专用材质：控制图 atlas（域/描边/类型/明暗）+ 世界 UV 平铺水彩贴图，
## 调色板 tint 全部取自 TerrainAtlas 常量（shaders/terrain_ground.gdshader）。
static func _make_ground_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/terrain_ground.gdshader")
	m.set_shader_parameter("control_tex", TerrainAtlas.texture())
	m.set_shader_parameter("grass_tex", GRASS_TEX)
	m.set_shader_parameter("dirt_tex", DIRT_TEX)
	m.set_shader_parameter("stone_tex", STONE_TEX)
	m.set_shader_parameter("grass_mean", GRASS_MEAN)
	m.set_shader_parameter("dirt_mean", DIRT_MEAN)
	m.set_shader_parameter("stone_mean", STONE_MEAN)
	m.set_shader_parameter("grass_tint", TerrainAtlas.GRASS_TINT)
	m.set_shader_parameter("path_tint", TerrainAtlas.PATH_TINT)
	m.set_shader_parameter("bed_tint", TerrainAtlas.BED_TINT)
	m.set_shader_parameter("lip_tint", TerrainAtlas.CLIFF_LIP_TINT)
	m.set_shader_parameter("wall_tint", TerrainAtlas.WALL_TINT)
	m.set_shader_parameter("path_rim", TerrainAtlas.PATH_RIM)
	m.set_shader_parameter("cliff_rim", TerrainAtlas.CLIFF_RIM_GRASS)
	m.set_shader_parameter("curvature", BendMat.CURVATURE)
	return m

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

## 按 wrapped 索引刷新区块外观（autotile 地面 + 地标 + 分区散布）。
## 地面棋盘/路/水全部由 TerrainMap+TerrainAtlas 决定，不再逐区块调色。
func _skin(slot: Dictionary, wrapped: Vector2i) -> void:
	var tile: MeshInstance3D = slot["tile"]
	tile.mesh = _chunk_mesh(wrapped)

	var deco: Node3D = slot["deco"]
	for c in deco.get_children():
		c.queue_free()

	# L1 摆放网格化：装饰全部吸附 tile 中心，占地经 OccupancyMap 全局登记
	# （类型/高度检查 + 占用互斥）。重刷先释放本区块旧占地。
	for cl in _claims.get(wrapped, []):
		OccupancyMap.free_rect(OccupancyMap.tile_to_cell(cl[0]), cl[1] * 2, cl[2] * 2)
	_claims[wrapped] = []

	# 先放手工地标（锚点落在本区块的），后散布——地标优先占地。
	for lm in LANDMARKS:
		var anchor: Vector2i = lm["tile"] - wrapped * CHUNK_TILES
		if anchor.x < 0 or anchor.x >= CHUNK_TILES or anchor.y < 0 or anchor.y >= CHUNK_TILES:
			continue
		_spawn_on_tile(deco, wrapped, lm["scene"], anchor, lm["scale"], lm["yaw"],
			int(lm.get("reserve", 0)), int(lm.get("search", 0)), bool(lm.get("path_ok", false)))

	# 分区散布：逐 tile 确定性判定。草丛不占位（可穿行的纯点缀），其余占 1×1。
	for j in range(CHUNK_TILES):
		for i in range(CHUNK_TILES):
			var ti := Vector2i(i, j)
			var gt := wrapped * CHUNK_TILES + ti
			var kind := _deco_kind(gt)
			if kind == DECO_NONE:
				continue
			var hk := hash(gt)
			var pos := _tile_local(ti, wrapped)
			if kind == DECO_TUFT:
				_spawn(deco, TUFT_SCENES[posmod(hk, TUFT_SCENES.size())], pos, 1.5 + float(posmod(hk, 3)) * 0.3, float(posmod(hk, 360)))
				continue
			if not OccupancyMap.prop_area_ok(gt, 1, 1):
				continue
			_claim(wrapped, gt, 1, 1)
			match kind:
				DECO_TREE:
					_spawn(deco, TREE_SCENES[posmod(hk, TREE_SCENES.size())], pos, 1.1 + float(posmod(hk, 5)) * 0.15, float(posmod(hk, 360)))
				DECO_BUSH:
					_spawn(deco, BUSH_SCENES[posmod(hk, BUSH_SCENES.size())], pos, 4.0 + float(posmod(hk, 3)), float(posmod(hk, 360)))
				DECO_ROCK:
					_spawn(deco, ROCK_SCENES[posmod(hk, ROCK_SCENES.size())], pos, 1.6 + float(posmod(hk, 3)) * 0.4, float(posmod(hk, 360)))

## 分区散布判定：全局 tile → 长什么（确定性，只在草地上长）。
## 分区从北往南：山地（松树/岩石随海拔变稀）、西南密林（隔位下种的高密度树）、
## 果园（规则行距的浆果灌木）、瞭望丘坡面、村核心（整洁）、出生空地（开阔）、
## 岸边一圈芦苇灌木、其余草甸疏树。
static func _deco_kind(gt: Vector2i) -> int:
	if TerrainMap.tile_type(gt) != TerrainMap.T_GRASS:
		return DECO_NONE
	var h := TerrainMap.tile_height(gt)
	var roll := posmod(hash(Vector2i(gt.x * 3 + 11, gt.y * 7 + 5)), 100)  # 与外观 hash 解耦
	# 岸边芦苇灌木：紧邻水面一圈
	if _near_water(gt):
		if roll < 26:
			return DECO_BUSH
		return DECO_TUFT if roll < 52 else DECO_NONE
	# 出生林间空地（环面距原点 8 tile 内）：保持开阔便于新手起步
	if _tor_dist(gt, Vector2i.ZERO) <= 8.0:
		return DECO_TUFT if roll < 10 else DECO_NONE
	# 北部山地（主峰 + 东肩丘一带）：低台地松树、中台地岩石、峰顶零星立石
	if gt.y <= 14 and gt.x >= 22:
		if h == 0:
			if roll < 7:
				return DECO_TREE
			if roll < 11:
				return DECO_ROCK
			return DECO_TUFT if roll < 18 else DECO_NONE
		if h <= 2:
			if roll < 11:
				return DECO_TREE
			if roll < 17:
				return DECO_ROCK
			return DECO_NONE
		if h <= 6:
			return DECO_ROCK if roll < 8 else DECO_NONE
		return DECO_ROCK if roll < 4 else DECO_NONE
	# 西南密林（沼泽小潭周边）：隔位下种防挤团，密度仍显著高于草甸
	if gt.x >= 4 and gt.x <= 16 and gt.y >= 36 and gt.y <= 66:
		if posmod(gt.x + gt.y, 2) == 0 and roll < 42:
			return DECO_TREE
		if roll < 10:
			return DECO_BUSH
		return DECO_TUFT if roll < 20 else DECO_NONE
	# 果园：集市东侧规则行距的浆果灌木（一眼看出是人种的）
	if gt.x >= 43 and gt.x <= 50 and gt.y >= 55 and gt.y <= 62:
		if posmod(gt.x, 3) == 1 and posmod(gt.y, 3) == 1:
			return DECO_BUSH
		return DECO_TUFT if roll < 8 else DECO_NONE
	# 瞭望丘等缓坡草面：草丛 + 零星岩石
	if h > 0:
		if roll < 5:
			return DECO_ROCK
		return DECO_TUFT if roll < 16 else DECO_NONE
	# 村核心（切比雪夫距广场 12 tile 内）：保持整洁
	if maxi(absi(gt.x - 37), absi(gt.y - 37)) <= 12:
		if roll < 3:
			return DECO_BUSH
		return DECO_TUFT if roll < 7 else DECO_NONE
	# 其余草甸：疏树 + 灌木 + 石 + 草丛
	if roll < 5:
		return DECO_TREE
	if roll < 9:
		return DECO_BUSH
	if roll < 11:
		return DECO_ROCK
	return DECO_TUFT if roll < 21 else DECO_NONE

## 8 邻里有水（环面 wrap 由 TerrainMap._idx 兜底）。
static func _near_water(gt: Vector2i) -> bool:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			if TerrainMap.tile_type(gt + Vector2i(dx, dz)) == TerrainMap.T_WATER:
				return true
	return false

## tile 间环面距离（tile 单位）。
static func _tor_dist(a: Vector2i, b: Vector2i) -> float:
	var n := WorldGrid.GRID_TILES
	var dx := absi(a.x - b.x)
	var dz := absi(a.y - b.y)
	return Vector2(float(mini(dx, n - dx)), float(mini(dz, n - dz))).length()

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
	var uv2s := PackedVector2Array()  # 逻辑世界米坐标：贴图平铺锚在环面上，玩家居中重摆不游动
	var idx := PackedInt32Array()
	var base_tile := wrapped * CHUNK_TILES
	var half := CHUNK_WORLD * 0.5
	var half_tile := WorldGrid.TILE_SIZE * 0.5
	var loff := Vector2(wrapped) * CHUNK_WORLD + Vector2(half, half)  # 区块局部 → 逻辑坐标偏移
	for j in range(CHUNK_TILES):
		for i in range(CHUNK_TILES):
			var t := base_tile + Vector2i(i, j)
			var ttype := TerrainMap.tile_type(t)
			var fl := TerrainMap.tile_floor_level(t)
			var y := float(fl) * TerrainMap.STEP_HEIGHT  # 地面 = 有效级：水 tile 湖床下沉
			var parity := posmod(t.x + t.y, 2)
			# 角变体与取图类型：路走同类过渡；水是整格湖床（岸线由草侧崖缘+岸壁表达）；
			# 草地在「有效级更低」的邻居（矮台地或水域湖床）旁换悬崖边草皮
			var uv_type := ttype
			var corners := PackedInt32Array([0, 0, 0, 0])  # 平草地/湖床不看变体
			if ttype == TerrainMap.T_PATH:
				var same := func(q: Vector2i) -> bool: return TerrainMap.tile_type(q) == ttype
				corners = Autotile.corners_from_mask(Autotile.mask_of(t, same))
			elif ttype == TerrainMap.T_GRASS:
				var not_lower := func(q: Vector2i) -> bool: return TerrainMap.tile_floor_level(q) >= fl
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
				_emit_quad(verts, norms, uvs, uv2s, idx, cx, cz, y, half_tile, r, loff)
			# L3 侧壁：邻居有效级更低的边（矮台地或湖床落差），逐级发墙 quad
			_emit_walls(verts, norms, uvs, uv2s, idx, t, fl, x0, z0, loff)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_chunk_meshes[wrapped] = mesh
	return mesh

## 水平角 quad：NW/NE/SE/SW 顶点序，从上往下看顺时针（Godot 正面绕序）。
## UV2 = 逻辑世界米坐标（局部坐标 + loff）。
func _emit_quad(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, idx: PackedInt32Array, cx: float, cz: float, y: float, size: float, r: Rect2, loff: Vector2) -> void:
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
	var lu := loff + Vector2(cx, cz)
	uv2s.append(lu)
	uv2s.append(lu + Vector2(size, 0.0))
	uv2s.append(lu + Vector2(size, size))
	uv2s.append(lu + Vector2(0.0, size))
	idx.append_array(PackedInt32Array([b, b + 1, b + 2, b, b + 2, b + 3]))

## tile 四边中「邻居有效级更低」的边发竖直崖壁/水下岸壁。每级 = 一个 2m×2m 墙格，
## 墙格对同一墙面的 8 邻墙格（沿墙走向左右 × 层级上下 × 对角）做 corner autotile：
## 有邻墙 = 相连，无邻墙侧出凹缝暗边 + 亮棱线。墙格再切 4 个 1m 角 quad 按变体取 UV。
## tile 局部范围 [x0, x0+2]×[z0, z0+2]，本 tile 有效级 fl（湖床可为负）。
## UV2 = (沿墙逻辑坐标, 世界 y)——竖直面按墙走向平铺贴图。
func _emit_walls(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, idx: PackedInt32Array, t: Vector2i, fl: int, x0: float, z0: float, loff: Vector2) -> void:
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
		var nfl := TerrainMap.tile_floor_level(t + n_off)
		for lvl in range(nfl, fl):
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
				# 沿墙逻辑坐标：东西向墙取 x、南北向墙取 z（+loff 对应轴分量）
				var a0 := (loff.x + h0.x) if n_off.x == 0 else (loff.y + h0.z)
				var a1 := (loff.x + h1.x) if n_off.x == 0 else (loff.y + h1.z)
				uv2s.append(Vector2(a0, yt))
				uv2s.append(Vector2(a1, yt))
				uv2s.append(Vector2(a1, yb))
				uv2s.append(Vector2(a0, yb))
				idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

## 墙格存在性：tile 在 lvl 层朝 n_off 方向有裸露墙面
## （本 tile 有效级高过该层，且该方向邻居的有效地面在该层或以下）。
func _wall_exists(tile: Vector2i, n_off: Vector2i, lvl: int) -> bool:
	return TerrainMap.tile_floor_level(tile) > lvl and lvl >= TerrainMap.tile_floor_level(tile + n_off)

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

## L1 摆放核心：把场景吸附到 tile 中心。anchor 是区块内 tile 索引(0..24)²，
## 占地或压路/水时沿螺旋环向外找至多 search 圈；reserve 是占地半径（0→1×1，1→3×3）。
## allow_path 供地标（水井）压路。找不到空位就放弃（确定性，不摆歪）。
## 占地经 OccupancyMap.prop_area_ok 判定（类型+高度一致+占用）并全局登记。
func _spawn_on_tile(parent: Node3D, wrapped: Vector2i, scene: PackedScene, anchor: Vector2i, scale_f: float, yaw_deg: float, reserve := 0, search := 0, allow_path := false) -> void:
	var span := reserve * 2 + 1
	for r in range(search + 1):
		for ti in _ring(anchor, r):
			var origin: Vector2i = wrapped * CHUNK_TILES + ti - Vector2i(reserve, reserve)
			if not OccupancyMap.prop_area_ok(origin, span, span, allow_path):
				continue
			_claim(wrapped, origin, span, span)
			_spawn(parent, scene, _tile_local(ti, wrapped), scale_f, yaw_deg)
			return

## 向 OccupancyMap 登记 w×h tile 占地，并记入 _claims 供区块重刷时释放。
func _claim(wrapped: Vector2i, origin_tile: Vector2i, w: int, h: int) -> void:
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(origin_tile), w * 2, h * 2)
	_claims[wrapped].append([origin_tile, w, h])

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

## 区块内 tile 索引 → 区块局部坐标（tile 中心，y 抬到 tile 台阶高度）。
func _tile_local(ti: Vector2i, wrapped: Vector2i) -> Vector3:
	var half := CHUNK_WORLD * 0.5
	var y := float(TerrainMap.tile_height(wrapped * CHUNK_TILES + ti)) * TerrainMap.STEP_HEIGHT
	return Vector3(
		-half + (float(ti.x) + 0.5) * WorldGrid.TILE_SIZE,
		y,
		-half + (float(ti.y) + 0.5) * WorldGrid.TILE_SIZE)
