class_name ChunkManager
extends Node3D
## 区块流送（chunk streaming）。
## 只实例化玩家周围 (2R+1)² 个区块，用对象池复用；每帧按最短环面位移
## 重定位每个 slot，并按「wrap 后的区块索引」决定外观（autotile 地面 + 布景）。
## 越过 GRID 接缝时，区块 (39,·) 之后接 (0,·)，外观连续 → 无缝。
##
## 布景数据源 = 地形矩阵物品层（万物皆物品，docs/scene-item-refactor-design.md）：
## 逐 tile 读 TerrainMap.tile_item_id → ItemCatalog 实体定义 → 按 renderRef 分发
## （烘焙树/KayKit 走 MultiMesh 合批，建筑独立节点，SDF 物件 from_spec）。
## 布置规则（散布分区/地标表）在导出工具 tools/scene_compose.gd——运行时只吃矩阵，
## 不判定、不找位、不登记占地（静态占用由 ItemCatalog.apply_static_occupancy 派生）。

const CHUNK_TILES := 25
const CHUNK_WORLD := float(CHUNK_TILES) * WorldGrid.TILE_SIZE          ## 50.0
const CHUNKS_PER_SIDE := WorldGrid.GRID_TILES / CHUNK_TILES            ## 3（75/25）
const R := 1                                                          ## 半径(区块)→ 3×3 = 正好整个小世界一遍，无重复
const RENDER_RADIUS := 110.0                                          ## 圆形渲染半径，覆盖全部 3×3（远处由雾渐隐）
## world-bending 在 GPU 位移顶点，但视锥裁剪按原始 AABB → 高处/远处网格会被误剔除。
## 外扩量的推导见 BendMat.CULL_MARGIN（最坏下压 30m，取 35）。
const CULL_MARGIN := BendMat.CULL_MARGIN

## 散布布景脚下贴片阴影（预烘焙假影，非实时投影）：树/灌木脚下一层合并 MultiMesh 暗斑，
## 复用 BlobShadow 同 shader，一次 draw call、零光照计算——补回关掉实时阴影后散布平光、
## 树"浮在地上"的锚定感。石/草太矮太碎不铺（影子小到看不出，徒增几何）。
## 斜阳投影不在物体正下方（会被树冠盖住看不见），而是沿光照射方向拖到背光侧、并被拉成
## 椭圆——方向唯一取自 BlobShadow.sun_ground_dir（场景那盏光），与场景明暗同一个太阳。
const SHADOW_STRENGTH := 0.50    ## 加深到能看清（旧 0.22 又淡又被树冠盖，实测等于没有）
const SHADOW_RADIUS_FACTOR := 0.6  ## 树/灌木短半轴 = 树冠水平半尺寸 × 此（垂直光方向）
const SHADOW_COT := 0.70         ## cot(太阳仰角 55°)：影子沿地面伸出长度 = 物体高 × 此
                                 ## ——偏移/拉长由高度定(不是半径),高树/房影拖远才看得见
const SHADOW_LIFT := 0.2         ## 抬离地面（同 BlobShadow，给深度测试留余量）

## KayKit CC0 资产（见 assets/kaykit/*/License）。Hexagon 建筑是微缩比例，需放大。
## 树/灌木改用 SDF 烘焙棉花糖布景（assets/sdf_props/*.json → tools/bake_sdf_deco.gd 产
## baked/*.res，Pokopia 式圆润树冠）；岩石/草丛仍是 KayKit。
const TREE_MESHES: Array[ArrayMesh] = [
	preload("res://assets/sdf_props/baked/tree_puff_a.res"),
	preload("res://assets/sdf_props/baked/tree_puff_b.res"),
	preload("res://assets/sdf_props/baked/tree_puff_c.res"),
]
const BUSH_MESH: ArrayMesh = preload("res://assets/sdf_props/baked/bush_puff.res")
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
const WATER_DIP := 0.35   ## 水面低于岸沿的落差（米）：露出一小截岸壁 = 可读的水位线

## 渲染绑定：矩阵物品 renderRef 的资源侧（编译期 preload，语义在实体定义里）。
## 合批散布（key = renderRef 冒号后段）：
const BAKED_MESHES := {
	"tree_puff_a": TREE_MESHES[0], "tree_puff_b": TREE_MESHES[1], "tree_puff_c": TREE_MESHES[2],
	"bush_puff": BUSH_MESH,
}
const KAYKIT_SCATTER := {
	"rock_0": ROCK_SCENES[0], "rock_1": ROCK_SCENES[1], "rock_2": ROCK_SCENES[2],
	"tuft_0": TUFT_SCENES[0], "tuft_1": TUFT_SCENES[1],
}
## 独立节点建筑（微缩 KayKit 需放大；缩放是渲染属性，不进矩阵）：
const KAYKIT_NODES := {
	"house_0": { "scene": HOUSE_SCENES[0], "scale": HOUSE_SCALE },
	"house_1": { "scene": HOUSE_SCENES[1], "scale": HOUSE_SCALE },
	"house_2": { "scene": HOUSE_SCENES[2], "scale": HOUSE_SCALE },
	"house_3": { "scene": HOUSE_SCENES[3], "scale": HOUSE_SCALE },
	"well": { "scene": WELL_SCENE, "scale": 4.5 },
	"windmill": { "scene": WINDMILL_SCENE, "scale": HOUSE_SCALE },
}

## slot 数组，每项 { root:Node3D, tile:MeshInstance3D, water:MeshInstance3D, deco:Node3D, wrapped:Vector2i }
var _slots: Array = []
## wrapped 区块索引 → 逐 tile autotile 地面 ArrayMesh。全世界只有 3×3 个
## wrapped 区块，mesh 各建一次后永久缓存（首帧 9 次，之后零开销）。
var _chunk_meshes: Dictionary = {}
## wrapped 区块索引 → 水面 ArrayMesh（无水区块存 null），同样永久缓存。
var _water_meshes: Dictionary = {}
## 所有地面共享一个控制图+水彩贴图材质（terrain_ground.gdshader）。
var _ground_mat: ShaderMaterial = null
## 所有水面共享一个半透明水面材质（water_surface.gdshader）。
var _water_mat: ShaderMaterial = null
## wrapped 区块 → 已向 OccupancyMap 登记的占地 [[origin_tile, w, h], ...]，重刷时释放。
var _claims: Dictionary = {}

## 画质旋钮 terrain_detail 调低：地形省掉路/崖壁的第二张细节贴图采样（见 terrain_ground.gdshader），
## 水面省掉第二层错速细节采样（见 water_surface.gdshader）。
## 记忆态：两张材质是懒建的（首个 slot 才建），启动时应用画质档可能早于建材质，
## 且 benchmark 会反复换档——必须记住，否则这一档写空/被重建的材质打回默认。
var _terrain_low_detail := false

func set_terrain_low_detail(on: bool) -> void:
	_terrain_low_detail = on
	if _ground_mat != null:
		_ground_mat.set_shader_parameter("low_detail", on)
	if _water_mat != null:
		_water_mat.set_shader_parameter("low_detail", on)

## 画质开关记忆态：chunk 是 3×3 流送、越界重铺会重建 deco 子节点，新建的贴片影 /
## SDF 物件必须沿用当前开关态，否则重铺一次就打回默认。setter 同时切现有节点。
var _ground_shadows := true  ## 地面斜阳椭圆贴片影（散布 + 建筑）
var _props_shown := true     ## 会动的 SDF 物件

## 画质：地面贴片影开/关。切现有 ScatterShadows/BuildingShadows + 记住供 chunk 重铺沿用。
## （不能按 perf_scatter 组切——那组混了散布植被本体，会连树一起隐藏，只能按节点 name。）
func set_ground_shadows(on: bool) -> void:
	_ground_shadows = on
	for n in get_tree().get_nodes_in_group("perf_scatter"):
		if n is MultiMeshInstance3D and (n.name == "ScatterShadows" or n.name == "BuildingShadows"):
			n.visible = on

## 画质：会动的 SDF 物件显/隐。切现有 perf_props + 记住供 chunk 重铺沿用。
func set_props_shown(on: bool) -> void:
	_props_shown = on
	for n in get_tree().get_nodes_in_group("perf_props"):
		n.visible = on
## 语音生成的动态 SDF 物件（运行时登记，区块重刷幸存）：
## { "spec_data": Dictionary, "tile": Vector2i(全局), "yaw": float, "wander": float }
var _dynamic_props: Array = []

func _ready() -> void:
	# 槽位与 wrapped 区块恒等绑定：3×3 槽位恰好覆盖 3×3 环面世界一遍（CHUNKS_PER_SIDE
	# == 2R+1 是本设计前提），每个 wrapped 只需铺一次内容，之后 update 只挪位置——
	# 旧的「跨界换 wrapped 就重铺」在真机上单帧连铺 3~4 块（实测 300~1000ms，移动顿到 1fps）。
	for x in range(CHUNKS_PER_SIDE):
		for z in range(CHUNKS_PER_SIDE):
			var slot := _make_slot()
			slot["wrapped"] = Vector2i(x, z)
			slot["skinned"] = false
			_slots.append(slot)

## 首屏是否铺完：所有槽位都 skin 过一轮（loading 过场据此判定世界可揭开）。
## update() 每帧铺最近未铺的一块，~9 帧内全 true；槽位数 == 3×3 面世界，恒定。
func all_skinned() -> bool:
	if _slots.is_empty():
		return false # _ready 尚未建槽，未就绪
	for s in _slots:
		if not s["skinned"]:
			return false
	return true

## 首屏铺设进度 [0,1]：已 skin 槽位 / 总槽位。loading 过场用它驱动仙子飞行进度。
## 未建槽（_ready 未跑）返回 0；全铺完返回 1（此时 all_skinned 亦为 true）。
func skinned_fraction() -> float:
	if _slots.is_empty():
		return 0.0
	var n := 0
	for s in _slots:
		if s["skinned"]:
			n += 1
	return float(n) / float(_slots.size())

## 恒等索引：wrapped → 槽位（_ready 的创建顺序 x*边长+z）。
func _slot_of(wrapped: Vector2i) -> Dictionary:
	return _slots[wrapped.x * CHUNKS_PER_SIDE + wrapped.y]

func _make_slot() -> Dictionary:
	if _ground_mat == null:
		_ground_mat = _make_ground_mat()
		_water_mat = _make_water_mat()
		set_terrain_low_detail(_terrain_low_detail)  # 懒建材质沿用当前档（见 setter 注释）
	var root := Node3D.new()
	add_child(root)
	var tile := MeshInstance3D.new()
	tile.material_override = _ground_mat
	tile.extra_cull_margin = CULL_MARGIN
	# 地面不投影（只接收角色实时阴影）：平地自投无意义，且大网格进 shadow pass 是主开销
	tile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(tile)
	tile.add_to_group("perf_terrain")  # PerfSweep 分解扫频用（debug 诊断）
	var water := MeshInstance3D.new()
	water.material_override = _water_mat
	water.extra_cull_margin = CULL_MARGIN
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # 半透明水面不投影
	root.add_child(water)
	water.add_to_group("perf_water")
	var deco := Node3D.new()
	root.add_child(deco)
	return { "root": root, "tile": tile, "water": water, "deco": deco, "wrapped": Vector2i(-999, -999) }

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

## 半透明水面材质（shaders/water_surface.gdshader）：水彩水贴图双层滚动 + 深度调色。
static func _make_water_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/water_surface.gdshader")
	m.set_shader_parameter("control_tex", TerrainAtlas.texture())
	m.set_shader_parameter("water_tex", WATER_TEX)
	m.set_shader_parameter("water_mean", WATER_MEAN)
	m.set_shader_parameter("shallow_color", TerrainAtlas.WATER_SHALLOW)
	m.set_shader_parameter("deep_color", TerrainAtlas.WATER_DEEP)
	m.set_shader_parameter("foam_color", TerrainAtlas.WATER_FOAM)
	m.set_shader_parameter("curvature", BendMat.CURVATURE)
	return m

## 地形数组换了之后重建全图区块（enter_scene 换场景时调用）。
## 区块外观是首次 _skin 时按当时的 TerrainMap 烘的，地面/水面 ArrayMesh 永久缓存，
## 不会自己跟着地形变——清掉两张 mesh 缓存并把所有槽位复位成未铺，下一批 update()
## 便按新地形逐帧重铺（_skin 开头自带旧区块占地释放，占地无需在此另行处理）。
## 前置：调用前地形必须已就位（TerrainMap 已载入新场景的 .mltr）——见
## docs/multi-scene-design.md 步骤⑤边界1；玩家/角色/动态物件的卸载由换场景流程另管。
## 复位期间槽位仍显示旧网格，直到被 update() 逐帧重铺（换场景走过场遮挡，见步骤⑤）。
func rebuild() -> void:
	_chunk_meshes.clear()
	_water_meshes.clear()
	for slot in _slots:
		slot["skinned"] = false

## 局部重铺（terrain_patch 后调用）：只失效被改 tile 波及的 wrapped 区块——
## autotile 掩码/崖壁/水面角点色都看 ±1 邻居，故按每个 tile 的 3×3 邻域求区块并集
## （tile 在区块边缘时连带邻区块）。清对应 mesh 缓存 + 槽位复位，update() 分帧重铺
## （单块真机 80-200ms，一次编辑最多波及 4 块）。返回失效区块数（测试断言用）。
func rebuild_tiles(tiles: Array) -> int:
	var n := WorldGrid.GRID_TILES
	var affected := {}
	for t: Vector2i in tiles:
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var q := Vector2i(posmod(t.x + dx, n), posmod(t.y + dz, n))
				affected[Vector2i(q.x / CHUNK_TILES, q.y / CHUNK_TILES)] = true
	for w: Vector2i in affected:
		_chunk_meshes.erase(w)
		_water_meshes.erase(w)
		if not _slots.is_empty():
			_slot_of(w)["skinned"] = false
	return affected.size()

## 清空语音生成的动态物件（换场景卸旧时调用）。释放它们登记的占地、free 掉节点、
## 清空运行时清单——否则 rebuild() 后 _skin 会照旧清单把上一个场景的物件重生成到新场景。
## 矩阵物品层的静态布置随新地形重铺自然重摆，不在此列。
func clear_dynamic_props() -> void:
	for dp in _dynamic_props:
		var tile: Vector2i = dp.get("tile", Vector2i(-999, -999))
		if tile.x > -900:
			var wrapped := Vector2i(tile.x / CHUNK_TILES, tile.y / CHUNK_TILES)
			OccupancyMap.free_rect(OccupancyMap.tile_to_cell(tile), 2, 2)
			var claims: Array = _claims.get(wrapped, [])
			for c in range(claims.size() - 1, -1, -1):
				if claims[c][0] == tile:
					claims.remove_at(c)
		var node = dp.get("node", null)
		if node != null and is_instance_valid(node):
			node.queue_free()
	_dynamic_props.clear()

func update(player_logical: Vector2) -> void:
	var pcx := int(floor(player_logical.x / CHUNK_WORLD))
	var pcz := int(floor(player_logical.y / CHUNK_WORLD))
	var pending: Array = []  # 未铺设槽位 [距离, slot, wrapped]，每帧只铺最近的一块
	for i in range(-R, R + 1):
		for j in range(-R, R + 1):
			var cx := pcx + i
			var cz := pcz + j
			# 区块中心的逻辑坐标
			var center_logical := Vector2(
				(float(cx) + 0.5) * CHUNK_WORLD,
				(float(cz) + 0.5) * CHUNK_WORLD)
			var d := WorldGrid.shortest_delta(player_logical, center_logical)
			# 槽位按 wrapped 恒等绑定（见 _ready 注释）：内容只铺一次，之后只挪位置
			var wrapped := Vector2i(
				posmod(cx, CHUNKS_PER_SIDE),
				posmod(cz, CHUNKS_PER_SIDE))
			var slot := _slot_of(wrapped)
			var root: Node3D = slot["root"]
			root.position = Vector3(d.x, 0.0, d.y)
			# 圆形裁剪：超出半径的区块隐藏 → 圆形地平线，无正方形四角对角缺口
			root.visible = d.length() < RENDER_RADIUS
			if not slot["skinned"]:
				pending.append([d.length(), slot, wrapped])
	# 入场铺设分帧：单块在平板小核上 80~200ms，一帧铺 9 块曾实测卡 ~1s；
	# 每帧只铺离焦点最近的一块（玩家脚下先有地），~9 帧内铺完
	if not pending.is_empty():
		pending.sort_custom(func(a, b): return a[0] < b[0])
		var e: Array = pending[0]
		e[1]["skinned"] = true
		var t0 := Time.get_ticks_usec()
		_skin(e[1], e[2])
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		if ms > 30.0:
			print("SPIKE chunk skin %s %.0fms" % [e[2], ms])

## 按 wrapped 索引刷新区块外观（autotile 地面 + 矩阵物品层 + 语音动态物件）。
## 地面棋盘/路/水全部由 TerrainMap+TerrainAtlas 决定，不再逐区块调色。
## 静态物品不判定、不找位、不登记占地——矩阵说了算（占用由 ItemCatalog 派生）。
func _skin(slot: Dictionary, wrapped: Vector2i) -> void:
	var tile: MeshInstance3D = slot["tile"]
	tile.mesh = _chunk_mesh(wrapped)
	var water: MeshInstance3D = slot["water"]
	water.mesh = _water_mesh(wrapped)

	var deco: Node3D = slot["deco"]
	for c in deco.get_children():
		c.queue_free()

	# 重刷先释放本区块旧动态占地（语音物件原位重生成时重新登记）。
	for cl in _claims.get(wrapped, []):
		OccupancyMap.free_rect(OccupancyMap.tile_to_cell(cl[0]), cl[1] * 2, cl[2] * 2)
	_claims[wrapped] = []

	# 语音生成的动态物件：落位 tile 归属本区块的，重刷时原位重生成（search 0 钉死）。
	for dp in _dynamic_props:
		var dp_anchor: Vector2i = dp["tile"] - wrapped * CHUNK_TILES
		if dp_anchor.x < 0 or dp_anchor.x >= CHUNK_TILES or dp_anchor.y < 0 or dp_anchor.y >= CHUNK_TILES:
			continue
		_spawn_sdf_on_tile(deco, wrapped, dp, dp_anchor, false)

	# 矩阵物品层：逐 tile 读引用（多 tile 物品只在锚点有值），按实体 renderRef 分发。
	# 散布类不逐个建节点：按渲染键收集变换，每区块每种一个 MultiMesh——
	# 500+ 散布逐个 MeshInstance3D（×阴影 pass 再翻倍）是 DC 2000+ 的主因。
	# 独立节点建筑顺便收集落点+半径+高度，末尾铺一层斜阳椭圆贴片影（与树影同一个太阳）。
	var batches := {}
	var building_shadows: Array = []
	for j in range(CHUNK_TILES):
		for i in range(CHUNK_TILES):
			var ti := Vector2i(i, j)
			var gt := wrapped * CHUNK_TILES + ti
			var id := TerrainMap.tile_item_id(gt)
			if id.is_empty():
				continue
			var yaw := TerrainMap.tile_item_yaw_deg(gt)
			var pos := _tile_local(ti, wrapped)
			var hk := hash(gt) # 外观抖动 hash（缩放/游走种子），与导出组装同款
			var def := ItemCatalog.get_def(id)
			var rref := String(def.get("renderRef", ""))
			var key := rref.get_slice(":", 1)
			if BAKED_MESHES.has(key) or KAYKIT_SCATTER.has(key):
				_batch(batches, key, pos, _jitter_scale(key, hk), yaw)
			elif KAYKIT_NODES.has(key):
				var nb: Dictionary = KAYKIT_NODES[key]
				var inst := _spawn(deco, nb["scene"], pos, float(nb["scale"]), yaw)
				var ext := _visual_extent(inst, float(nb["scale"]))
				building_shadows.append([inst.position, ext.x, ext.y])
			elif rref == "sdf_inline" or rref.begins_with("sdf_res:"):
				_spawn_static_sdf(deco, def, rref, pos, yaw, hk)
			elif rref.is_empty():
				push_warning("[items] 未知物品实体 %s（catalog 未载入?），跳过渲染" % id)
	_flush_batches(deco, batches)
	_flush_shadows(deco, batches)
	_flush_building_shadows(deco, building_shadows)

## 静态 SDF 物件（矩阵物品层）：spec 来自打包 json（sdf_res:<name>）或实体行内联
## （sdf_inline，语音造物）。wander 来自实体定义；不登记占地（矩阵派生）。
func _spawn_static_sdf(parent: Node3D, def: Dictionary, rref: String, pos: Vector3, yaw: float, seed_v: int) -> void:
	var prop: SdfProp
	if rref == "sdf_inline":
		var spec: Variant = def.get("spec", null)
		if typeof(spec) != TYPE_DICTIONARY:
			return
		prop = SdfProp.from_spec(spec)
	else:
		prop = SdfProp.from_json_file("res://assets/sdf_props/%s.json" % rref.get_slice(":", 1))
	if prop == null:
		return
	prop.position = pos
	prop.rotation_degrees = Vector3(0.0, yaw, 0.0)
	prop.visible = _props_shown  # 沿用画质开关态（chunk 重铺不打回默认）
	parent.add_child(prop)
	prop.enable_wander(float(def.get("wander", 0.0)), seed_v)

## 散布缩放抖动（迁自旧散布逻辑，逐 tile hash 确定性；朝向抖动已烘进矩阵 arg）。
static func _jitter_scale(key: String, hk: int) -> float:
	if key.begins_with("tree_puff"):
		return 0.85 + float(posmod(hk, 5)) * 0.09
	if key == "bush_puff":
		return 1.0 + float(posmod(hk, 3)) * 0.25
	if key.begins_with("rock_"):
		return 1.6 + float(posmod(hk, 3)) * 0.4
	return 1.5 + float(posmod(hk, 3)) * 0.3 # tuft

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

## 构建（或取缓存）一个 wrapped 区块的水面 ArrayMesh；区块内没有水返回 null。
## 每个水 tile 与地面同构切 4 个角 quad，水位 = 岸沿 - WATER_DIP：
## - UV → atlas 水 cell（角变体 = 水-水邻接掩码）：G 通道是沿岸圆角泡沫带，
##   子 tile 精度——窄溪也只在贴岸处起沫，不会整条变白
## - 顶点色 R = 深度归一(depth/MAX_DEPTH，角点四邻水 tile 均值，双线性到子角点)
## - UV2 同地面（逻辑米坐标，波纹滚动锚定环面）
func _water_mesh(wrapped: Vector2i) -> ArrayMesh:
	if _water_meshes.has(wrapped):
		return _water_meshes[wrapped]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var base_tile := wrapped * CHUNK_TILES
	var half := CHUNK_WORLD * 0.5
	var ts := WorldGrid.TILE_SIZE
	var half_tile := ts * 0.5
	var loff := Vector2(wrapped) * CHUNK_WORLD + Vector2(half, half)
	var is_water := func(q: Vector2i) -> bool: return TerrainMap.tile_type(q) == TerrainMap.T_WATER
	for j in range(CHUNK_TILES):
		for i in range(CHUNK_TILES):
			var t := base_tile + Vector2i(i, j)
			if TerrainMap.tile_type(t) != TerrainMap.T_WATER:
				continue
			var y := float(TerrainMap.tile_height(t)) * TerrainMap.STEP_HEIGHT - WATER_DIP
			var x0 := -half + float(i) * ts
			var z0 := -half + float(j) * ts
			var corners := Autotile.corners_from_mask(Autotile.mask_of(t, is_water))
			# tile 四角点的深度色，子角 quad 顶点按 (u,v) 双线性取值
			var c00 := _water_node_color(t + Vector2i(0, 0))
			var c10 := _water_node_color(t + Vector2i(1, 0))
			var c01 := _water_node_color(t + Vector2i(0, 1))
			var c11 := _water_node_color(t + Vector2i(1, 1))
			for c in range(4):
				var cx := x0 + (half_tile if (c == Autotile.C_NE or c == Autotile.C_SE) else 0.0)
				var cz := z0 + (half_tile if (c == Autotile.C_SW or c == Autotile.C_SE) else 0.0)
				var r := TerrainAtlas.uv_rect(TerrainMap.T_WATER, c, corners[c], 0)
				var b := verts.size()
				_emit_quad(verts, norms, uvs, uv2s, idx, cx, cz, y, half_tile, r, loff)
				for k in range(4):
					var v := verts[b + k]
					var u := (v.x - x0) / ts
					var w := (v.z - z0) / ts
					cols.append(c00.lerp(c10, u).lerp(c01.lerp(c11, u), w))
	if verts.is_empty():
		_water_meshes[wrapped] = null
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_water_meshes[wrapped] = mesh
	return mesh

## 网格角点 node（tile 角点的整格索引）→ 水面顶点色。
## 共享该角点的四个 tile：node 的西北四邻 (node.x-1..node.x)×(node.y-1..node.y)。
## R = 水 tile 深度均值 / MAX_DEPTH（岸角点只有部分邻居是水 → 天然偏浅）。
static func _water_node_color(node: Vector2i) -> Color:
	var depth_sum := 0.0
	var water_n := 0
	for dz in range(-1, 1):
		for dx in range(-1, 1):
			var q := node + Vector2i(dx, dz)
			if TerrainMap.tile_type(q) == TerrainMap.T_WATER:
				depth_sum += float(TerrainMap.tile_depth(q))
				water_n += 1
	var depth01 := (depth_sum / float(water_n)) / float(TerrainMap.MAX_DEPTH) if water_n > 0 else 0.0
	return Color(depth01, 0.0, 0.0)

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

## 散布合批：种类 key → 收集实例变换（_flush_batches 一次性建 MultiMesh）。
func _batch(batches: Dictionary, key: String, pos: Vector3, scale_f: float, yaw_deg: float) -> void:
	var basis := Basis(Vector3.UP, deg_to_rad(yaw_deg)).scaled(Vector3.ONE * scale_f)
	batches.get_or_add(key, []).append(Transform3D(basis, pos))

## 每种散布一个 MultiMeshInstance3D（共享 mesh + 共享 bend 材质 = 一次 draw call）。
func _flush_batches(parent: Node3D, batches: Dictionary) -> void:
	for key: String in batches:
		var info := _scatter_kind(key)
		var arr: Array = batches[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = info["mesh"]
		mm.instance_count = arr.size()
		for i in range(arr.size()):
			mm.set_instance_transform(i, arr[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = info["mat"]
		mmi.extra_cull_margin = CULL_MARGIN
		# 散布物一律不投影：真机（Mali-G76）瓶颈是顶点吞吐，shadow pass 重画全部散布
		# 几何是 7fps 的主因（关阴影实测 18fps）。树冠平光贴合 Pokopia 风；
		# 影子锚定感由角色/建筑/可动物件保留投影承担（shadow max distance 45）。
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)
		mmi.add_to_group("perf_scatter")  # PerfSweep 分解扫频用（debug 诊断）

## 单个贴片影的实例变换（树/灌木/建筑共用）：斜阳椭圆，从物体脚沿光方向拖出。
## reach = 物体高 × cot(仰角)。关键：影心必须挪到物体半径**之外**才露得出来——否则矮胖树
## (半径 2.3 > 影长一半)影心还压在树冠正下方、被自己盖住看不见（实测踩坑）。故取
## 长半轴 = offset = short_r + reach/2：影从脚(pos)拖到 pos+2·offset，中心落在物体边外。
## 方向唯一取 sun_ground_dir（场景那盏光）；rot * scale（local 轴缩放再旋转）——Basis.scaled
## 是 diag*R（世界轴缩放）椭圆长轴不跟 yaw 转、方向错。纯函数、CPU 侧可单测。
func _shadow_xform(pos: Vector3, short_r: float, height: float) -> Transform3D:
	var sun := BlobShadow.sun_ground_dir
	var yaw := atan2(sun.x, sun.z)  # 使 local +Z 对齐光方向 → 长轴沿光方向
	var reach := height * SHADOW_COT             # 影子沿地面伸出的长度（由高度定，不是半径）
	var half := short_r + reach * 0.5            # 长半轴 = 影心偏移：影从脚拖到 2·half，心在物体边外
	var b := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(short_r * 2.0, 1.0, half * 2.0))
	var center := pos + sun * half + Vector3(0.0, SHADOW_LIFT, 0.0)
	return Transform3D(b, center)

## 散布树/灌木影斑变换（CPU 侧、可单测——headless 下 MultiMesh 的 transform 走
## RenderingServer dummy 后端读不回，几何断言必须在这里做）：只收树/灌木，石/草跳过。
## 短半径从各 mesh 静止 AABB 的水平尺寸推、再乘该实例散布缩放。
func _shadow_xforms(batches: Dictionary) -> Array[Transform3D]:
	var xforms: Array[Transform3D] = []
	for key: String in batches:
		if not (key.begins_with("tree_puff") or key == "bush_puff"):
			continue  # 石/草太矮太碎，不铺影
		var aabb: AABB = _scatter_kind(key)["mesh"].get_aabb()
		var base_r := maxf(aabb.size.x, aabb.size.z) * 0.5 * SHADOW_RADIUS_FACTOR
		var base_h := aabb.size.y
		for t: Transform3D in batches[key]:
			var s := t.basis.get_scale().x
			xforms.append(_shadow_xform(t.origin, base_r * s, base_h * s))
	return xforms

## 散布树/灌木脚下贴片阴影：把落点收成一层合并 MultiMesh 暗斑（一次 draw call、
## 不投实时阴影），补回关实时阴影后散布平光、树"浮在地上"的锚定感。
func _flush_shadows(parent: Node3D, batches: Dictionary) -> void:
	var xforms := _shadow_xforms(batches)
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BlobShadow.multimesh_mesh(SHADOW_STRENGTH)
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "ScatterShadows"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = CULL_MARGIN
	mmi.visible = _ground_shadows  # 沿用画质开关态（chunk 重铺不打回默认）
	parent.add_child(mmi)
	mmi.add_to_group("perf_scatter")  # 与散布同组，PerfSweep 一并可切

## 建筑影用的水平半径 + 高度：遍历 inst 的 MeshInstance3D 取最大 mesh 水平/竖直 AABB ×
## 实例缩放（近似，忽略部件相对偏移；影子不需精确）。短轴用实际半径（不缩 factor，房子
## 影要盖住占地）。返回 Vector2(short_r, height)。没 mesh 兜底 (1, 3)。
func _visual_extent(inst: Node3D, scale_f: float) -> Vector2:
	var span := 0.0
	var hgt := 0.0
	for mi: MeshInstance3D in inst.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh != null:
			var a := mi.mesh.get_aabb()
			span = maxf(span, maxf(a.size.x, a.size.z))
			hgt = maxf(hgt, a.size.y)
	if span <= 0.0:
		return Vector2(1.0, 3.0) * scale_f
	return Vector2(span * 0.5, hgt) * scale_f

## 地标建筑脚下同款斜阳椭圆贴片影：入参 [[落点, 短半径, 高度], ...]，一层合并 MultiMesh
## （一次 draw call、不投实时阴影），方向/椭圆走 _shadow_xform（与树影同一个太阳）。
func _flush_building_shadows(parent: Node3D, centers: Array) -> void:
	if centers.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BlobShadow.multimesh_mesh(SHADOW_STRENGTH)
	mm.instance_count = centers.size()
	for i in range(centers.size()):
		mm.set_instance_transform(i, _shadow_xform(centers[i][0], centers[i][1], centers[i][2]))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "BuildingShadows"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = CULL_MARGIN
	mmi.visible = _ground_shadows  # 沿用画质开关态（chunk 重铺不打回默认）
	parent.add_child(mmi)
	mmi.add_to_group("perf_scatter")

## 散布种类注册表（懒建）：渲染键（renderRef 冒号后段）→ { mesh, mat }。
## 树/灌木用烘焙 mesh + SdfStaticBaker 共享材质；石/草从 KayKit 场景剥出
## mesh 和 bend 包裹后的材质（_wrap_material 有缓存，同调色板 atlas 只建一份）。
static var _scatter_kinds: Dictionary = {}

func _scatter_kind(key: String) -> Dictionary:
	if _scatter_kinds.has(key):
		return _scatter_kinds[key]
	var info := {}
	if BAKED_MESHES.has(key):
		info = { "mesh": BAKED_MESHES[key], "mat": SdfStaticBaker.material() }
	else:
		var scene: PackedScene = KAYKIT_SCATTER[key]
		var inst := scene.instantiate()
		var mi: MeshInstance3D = inst.find_children("*", "MeshInstance3D", true, false)[0]
		info = { "mesh": mi.mesh, "mat": BendMat.wrap_material(mi.get_active_material(0)) }
		inst.free()
	_scatter_kinds[key] = info
	return info

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
		# 建筑不投实时阴影：CHARACTER_SHADOWS 实验聚焦「只角色投影」，建筑靠自身明暗立体
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst

## SDF 语音物件摆放：占地判定 + 螺旋找位，实例化 SdfProp 并启用锚点游走。
## 材质自带 world-bend 项（sdf_field.gdshaderinc），不走 BendMat.wrap_scene。
## 语音生成的物件进世界：围绕 want_tile 螺旋找空位（钳在区块内防跨块归属混乱），
## 成功则登记运行时清单（此后区块重刷自动原位重生成）并返回落位 tile；失败返回 (-1,-1)。
## id 供拾起/挪位按物件寻址；search=0 表示精确落位（拖拽摆放 tile 吸附，不螺旋）。
func add_dynamic_prop(spec_data: Dictionary, want_tile: Vector2i, yaw := 0.0, wander := 0.0, id := "", search := 3) -> Vector2i:
	var n := WorldGrid.GRID_TILES
	want_tile = Vector2i(posmod(want_tile.x, n), posmod(want_tile.y, n))
	var wrapped := Vector2i(want_tile.x / CHUNK_TILES, want_tile.y / CHUNK_TILES)
	# 找当前持有该 wrapped 区块的 slot（3×3 池覆盖全图，必在）
	var deco: Node3D = null
	for slot in _slots:
		if slot["wrapped"] == wrapped:
			deco = slot["deco"]
			break
	if deco == null:
		return Vector2i(-1, -1)
	# 不预钳 anchor：贴区块边的 tile 也要能精确命中（重载恢复保真），
	# 螺旋出界的候选由 _spawn_sdf_on_tile 逐个跳过（防跨块归属混乱）。
	var anchor := want_tile - wrapped * CHUNK_TILES
	# 同一 dict 既传给 spawn（记 node 引用）又进清单：重刷/拾起都认得它
	var entry := { "id": id, "spec_data": spec_data, "yaw": yaw, "wander": wander, "reserve": 0, "search": search }
	var placed := _spawn_sdf_on_tile(deco, wrapped, entry, anchor)
	if placed.x >= 0:
		entry["tile"] = placed
		entry["search"] = 0 # 落定后重刷钉死原位
		_dynamic_props.append(entry)
	return placed

## 指定 tile 上（或紧邻一圈，容忍游走漂移）的语音物件 id；没有返回 ""。
func dynamic_prop_at(tile: Vector2i) -> String:
	for r in range(2):
		for ti in _ring(tile, r):
			for dp in _dynamic_props:
				if dp["tile"] == ti:
					return String(dp.get("id", ""))
	return ""

## 只读取节点（不摘除，与 pickup_dynamic_prop 相对）：拿来做特效锚点（如把答案「扔」进占位符时
## 求它的屏幕投影、给它一个弹动）。区块重刷后节点会换新，故每次现取，不许缓存。
func dynamic_prop_node(id: String) -> Node3D:
	if id.is_empty():
		return null
	for dp in _dynamic_props:
		if String(dp.get("id", "")) != id:
			continue
		var node = dp.get("node", null)
		return node if node is Node3D and is_instance_valid(node) else null
	return null

## 拾起：释放占地、从清单摘除（重刷不再重生成），交出节点给调用方拖拽。
## 返回 { id, spec_data, yaw, wander, tile, node }；找不到返回空字典。
func pickup_dynamic_prop(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	for i in range(_dynamic_props.size()):
		var dp: Dictionary = _dynamic_props[i]
		if String(dp.get("id", "")) != id:
			continue
		var tile: Vector2i = dp["tile"]
		var wrapped := Vector2i(tile.x / CHUNK_TILES, tile.y / CHUNK_TILES)
		OccupancyMap.free_rect(OccupancyMap.tile_to_cell(tile), 2, 2)
		var claims: Array = _claims.get(wrapped, [])
		for c in range(claims.size()):
			if claims[c][0] == tile:
				claims.remove_at(c)
				break
		_dynamic_props.remove_at(i)
		return dp
	return {}

## entry 支持两种 spec 来源："spec"=res:// JSON 路径（手工锚点表）或 "spec_data"=已解析字典
## （语音生成）。返回实际落位的全局 tile；找不到空位/坏 spec 返回 (-1,-1)。
func _spawn_sdf_on_tile(parent: Node3D, wrapped: Vector2i, entry: Dictionary, anchor: Vector2i, check_chars := true) -> Vector2i:
	var reserve := int(entry.get("reserve", 0))
	var search := int(entry.get("search", 0))
	var span := reserve * 2 + 1
	for r in range(search + 1):
		for ti in _ring(anchor, r):
			if ti.x < 0 or ti.x >= CHUNK_TILES or ti.y < 0 or ti.y >= CHUNK_TILES:
				continue # 螺旋越出本区块的候选跳过（占地/归属都按本区块记）
			var origin: Vector2i = wrapped * CHUNK_TILES + ti - Vector2i(reserve, reserve)
			# 重刷路径 check_chars=false（钉死原位重生成）；语音造物首次落位保持查角色
			if not OccupancyMap.prop_area_ok(origin, span, span, false, check_chars):
				continue
			var prop: SdfProp
			if entry.has("spec_data"):
				prop = SdfProp.from_spec(entry["spec_data"])
			else:
				prop = SdfProp.from_json_file(str(entry["spec"]))
			if prop == null:
				return Vector2i(-1, -1)  # spec 坏了：占地不登记，直接放弃
			_claim(wrapped, origin, span, span)
			prop.position = _tile_local(ti, wrapped)
			prop.rotation_degrees = Vector3(0.0, float(entry.get("yaw", 0.0)), 0.0)
			prop.visible = _props_shown  # 沿用画质开关态（chunk 重铺不打回默认）
			parent.add_child(prop)
			prop.enable_wander(float(entry.get("wander", 0.0)), hash(str(entry.get("spec", prop.name))) + hash(ti))
			if entry.has("id"): # 动态物件（语音造物）：记节点引用供拾起拖拽
				entry["node"] = prop
			return wrapped * CHUNK_TILES + ti
	return Vector2i(-1, -1)

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
