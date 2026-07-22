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
const CHUNK_WORLD := float(CHUNK_TILES) * WorldGrid.TILE_SIZE          ## 50.0（TILE_SIZE 恒定）
## 每边区块数 = GRID_TILES / CHUNK_TILES，随场景网格运行时派生（50→2 / 75→3 / 100→4）。
## 曾是编译期 const（锁死 3）；改运行时后由 _ensure_slots 建/重建 CHUNKS_PER_SIDE² 个常驻槽。
var _chunks_per_side := 0                                             ## 0 = 尚未建槽（_ensure_slots 首次填）
const RENDER_RADIUS := 110.0                                          ## 圆形渲染半径（固定视距，远处由雾渐隐）
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

## 布景资产（树/灌木烘焙 mesh、KayKit 石/草/民居、scifi 机器人…）的资源侧绑定已
## 数据驱动化（world-themes P3）：渲染键 → 资源路径/分类/缩放 声明在
## assets/packs/<pack>/pack.json，由 PackRegistry 启动扫描、运行时 load() 建注册表。
## 「加主题包 = 丢个 pack 目录 + index.json 加一行」，本文件零改动。见 scripts/pack_registry.gd。

## 地面贴图（themed-terrain P1）：顶面/侧壁走 TerrainTextures 的 Texture2DArray 按层采样，
## 「哪种地形」由 mesh 顶点 COLOR 层索引承载。水面仍是单张水彩贴图（水 tile 覆盖层，独立 shader）。
const WATER_TEX: Texture2D = preload("res://assets/textures/watercolor/water.png")
## 水贴图全图均值（magick -resize 1x1 实测，sRGB）；shader 用 tex/mean 归一出波纹细节。
const WATER_MEAN := Color(72.0 / 255.0, 122.0 / 255.0, 132.0 / 255.0)
const WATER_DIP := 0.35   ## 水面低于岸沿的落差（米）：露出一小截岸壁 = 可读的水位线

## 边缘贴纸（renderRef 'sticker:<name>'，docs/sticker-items-design.md §3）：
## 贴图路径已随 world-themes 数据驱动进 assets/packs/stickers/pack.json（category "sticker"），
## 这里只留几何常量。合批走 _batch/_flush_batches 同款 MultiMesh 路
## （batch key 用完整 'sticker:<name>' 防与散布键混淆）。
const STICKER_H := 1.0     ## 贴纸竖片世界高（米），宽按贴图比例
const STICKER_LIFT := 0.2  ## 底边离地
const STICKER_OUT := 0.05  ## 沿法线外移，防与台阶立面/崖壁 z-fight
## 边缘中点偏移（半 tile，N/E/S/W 顺序=TerrainMap.EDGE_*）与竖片朝外 yaw。
const EDGE_OFFSETS: Array[Vector2] = [Vector2(0, -0.5), Vector2(0.5, 0), Vector2(0, 0.5), Vector2(-0.5, 0)]
const EDGE_YAWS: Array[float] = [180.0, 90.0, 0.0, 270.0]

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

## 万物基底层（themed-terrain P2）：body tile autotile 过渡子掩码采的底色层。默认草地（0）；
## rebuild() 按当前 TerrainMap 的模态地表刷新——海底场景 → 细沙层，避免边缘露草绿。
## 与 low_detail 同款懒建记忆态：材质可能晚于本值建成，须记住并在建材质时补上。
var _base_layer := TerrainTextures.LAYER_GRASS

func set_terrain_low_detail(on: bool) -> void:
	_terrain_low_detail = on
	if _ground_mat != null:
		_ground_mat.set_shader_parameter("low_detail", on)
	if _water_mat != null:
		_water_mat.set_shader_parameter("low_detail", on)

## 纸艺风（画质页样式键）在地形/水面上的参数档。物品档见 BendMat.PAPER_PROPS。
## 地形无折面化（平面 quad）；水面的 bands 量化深度分层而非光照（见 water_surface.gdshader）。
const PAPER_GROUND := {"paper_bands": 3.0, "paper_edge": 0.7, "paper_grain": 0.6, "paper_tone": 0.4}
const PAPER_WATER := {"paper_bands": 4.0, "paper_grain": 0.4, "paper_tone": 0.3}

## 与 low_detail 同款懒建记忆态；初值认 BendMat 的调试强制位（MALIANG_PAPERCRAFT=1）。
var _papercraft := BendMat.papercraft_on()

## 画质：纸艺风开/关（地形+水面）。调用方（world._apply_graphics_key）先切 BendMat
## 再把 BendMat.papercraft_on() 的解析结果传进来——调试强制位的语义只在 BendMat 一处。
func set_papercraft(on: bool) -> void:
	_papercraft = on
	for pair in [[_ground_mat, PAPER_GROUND], [_water_mat, PAPER_WATER]]:
		var m: ShaderMaterial = pair[0]
		if m == null:
			continue
		for k: String in pair[1]:
			m.set_shader_parameter(k, pair[1][k] if _papercraft else 0.0)

## 设万物基底层并（若材质已建）即时下发。数据源见 _refresh_base_layer()。
func set_base_layer(layer: int) -> void:
	_base_layer = layer
	if _ground_mat != null:
		_ground_mat.set_shader_parameter("base_layer", layer)

## 按当前 TerrainMap 的模态地表（出现最多的非水 tile 类型）定基底层：草地世界→草，
## 海底/雪原等单一主题场景→该主题主地表。混合主题公园（P4）取占比最大者（近似，非逐 tile）。
func _refresh_base_layer() -> void:
	var n := WorldGrid.GRID_TILES
	var counts := {}
	for z in range(n):
		for x in range(n):
			var tt := TerrainMap.tile_type(Vector2i(x, z))
			if tt == TerrainMap.T_WATER:
				continue  # 水走湖床/水面 shader，不作基底候选
			counts[tt] = int(counts.get(tt, 0)) + 1
	var best_type := TerrainMap.T_GRASS
	var best_n := -1
	for tt: int in counts:
		if counts[tt] > best_n:
			best_n = counts[tt]
			best_type = tt
	set_base_layer(TerrainTextures.top_layer(best_type))

## 画质开关记忆态：chunk 是 3×3 流送、越界重铺会重建 deco 子节点，新建的贴片影 /
## SDF 物件必须沿用当前开关态，否则重铺一次就打回默认。setter 同时切现有节点。
var _ground_shadows := true  ## 地面斜阳椭圆贴片影（散布 + 建筑）
var _props_shown := true     ## 会动的 SDF 物件

## 室内房间舞台（home-interior 重做）：室内场景不铺无限地形——隐藏各槽的【地面+水面】mesh
## （地板由 world.gd 的 RoomStage 真几何接管），但【保留 deco 层】，好让玩家摆的家具（走
## item_place → 矩阵物品层 → chunk deco）照常渲染并随 update 重定位。故 update() 不跳过，
## 只是 _skin 出的地面/水面 mesh 被置 invisible。换场景切室内/室外时由 world.gd 调用。
var _terrain_hidden := false

## 室内隐藏地面/水面 mesh（RoomStage 接管地板；家具 deco 层不动）。立即对已铺槽应用。
func set_terrain_hidden(on: bool) -> void:
	_terrain_hidden = on
	for slot in _slots:
		var tile: MeshInstance3D = slot["tile"]
		var water: MeshInstance3D = slot["water"]
		if tile != null:
			tile.visible = not on
		if water != null:
			water.visible = not on

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
	_ensure_slots()

## 按当前 WorldGrid.GRID_TILES 建齐 CHUNKS_PER_SIDE² 个常驻槽（每 wrapped 区块一个，恒等绑定）。
## 幂等：网格没变时零成本直接返回；变了（换到不同尺寸场景）则推倒旧槽重建。
##
## 槽位与 wrapped 区块恒等绑定 = 每个 wrapped 只需铺一次内容，之后 update 只挪位置——
## 旧的「跨界换 wrapped 就重铺」在真机上单帧连铺 3~4 块（实测 300~1000ms，移动顿到 1fps）。
## 常驻槽数随网格：50→2×2、75→3×3、100→4×4。update() 每帧把每个槽摆到离焦点最近的
## 环面镜像并按 RENDER_RADIUS 圆形裁剪（不再依赖「奇数窗口恰好覆盖世界」的旧前提，
## 故 100 格的 4×4 偶数边也能无缝——见 update 注释）。
func _ensure_slots() -> void:
	var cps := WorldGrid.GRID_TILES / CHUNK_TILES
	if cps == _chunks_per_side and not _slots.is_empty():
		return
	for slot in _slots:
		var root: Variant = slot.get("root", null)
		if root != null and is_instance_valid(root):
			(root as Node3D).queue_free()
	_slots.clear()
	_chunk_meshes.clear()
	_water_meshes.clear()
	_chunks_per_side = cps
	for x in range(cps):
		for z in range(cps):
			var slot := _make_slot()
			slot["wrapped"] = Vector2i(x, z)
			slot["skinned"] = false
			_slots.append(slot)

## 首屏是否铺完：所有槽位都 skin 过一轮（loading 过场据此判定世界可揭开）。
## update() 每帧铺最近未铺的一块，CHUNKS_PER_SIDE² 帧内全 true（75→9、100→16）。
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

## 恒等索引：wrapped → 槽位（_ensure_slots 的创建顺序 x*边长+z）。
func _slot_of(wrapped: Vector2i) -> Dictionary:
	return _slots[wrapped.x * _chunks_per_side + wrapped.y]

func _make_slot() -> Dictionary:
	if _ground_mat == null:
		_ground_mat = _make_ground_mat()
		_water_mat = _make_water_mat()
		set_terrain_low_detail(_terrain_low_detail)  # 懒建材质沿用当前档（见 setter 注释）
		set_base_layer(_base_layer)                  # 同上：懒建材质补上当前基底层
		set_papercraft(_papercraft)                  # 同上：懒建材质补上纸艺风
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

## 贴图平色化/拼布抖动基线档（Pokopia 化 P2，调参对象）：flatten 把照片纹理往逐层
## 平均色收敛（远看干净色块），tile_jitter 给相邻 tile/墙格轻微色差（拼布感）。
const FLATTEN := 0.65
const TILE_JITTER := 0.5
const WALL_STRATA := 0.55  ## 崖壁逐级地层行带强度（Pokopia 化 P3）
const CAP_TRIM := 0.9      ## 崖顶波浪盖帽强度（Pokopia 化 P4，第一识别特征）
const CORNER_AO := 0.7     ## 墙脚接触暗缝强度（Pokopia 化 P5，内凹角柔和 AO）
## 草地草簇/大头花散布（Pokopia 化 P6）的密度/姿态旋钮在 terrain_deco.gd 顶部常量区。

## 地形专用材质（themed-terrain P1）：控制图 atlas（域/描边/角色/明暗）+ 顶面/侧壁
## Texture2DArray（世界 UV 平铺，per-tile 层索引选贴图）。逐层 tint/mean 与描边色取自
## TerrainTextures / TerrainAtlas 常量（shaders/terrain_ground.gdshader）。
static func _make_ground_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/terrain_ground.gdshader")
	m.set_shader_parameter("control_tex", TerrainAtlas.texture())
	m.set_shader_parameter("top_array", TerrainTextures.build_texture_array())
	# gl_compatibility（iOS）对 sampler2DArray 不做 source_color 的 sRGB 解码 → 手动补（见 shader 注释）。
	m.set_shader_parameter("srgb_array_manual", RenderingServer.get_current_rendering_method() == "gl_compatibility")
	m.set_shader_parameter("layer_tint", TerrainTextures.layer_tints_linear())
	m.set_shader_parameter("layer_mean", TerrainTextures.layer_means_linear())
	m.set_shader_parameter("layer_flat", TerrainTextures.layer_flats_linear())
	m.set_shader_parameter("flatten", FLATTEN)
	m.set_shader_parameter("tile_jitter", TILE_JITTER)
	m.set_shader_parameter("wall_strata", WALL_STRATA)
	m.set_shader_parameter("cap_trim", CAP_TRIM)
	m.set_shader_parameter("layer_cap", TerrainTextures.layer_cap_trims())
	m.set_shader_parameter("corner_ao", CORNER_AO)
	m.set_shader_parameter("wall_relief", TerrainTextures.layer_wall_reliefs())
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
	_ensure_slots()        # 换场景可能换网格尺寸 → 先按新尺寸建齐槽（尺寸没变则幂等直返）
	_refresh_base_layer()  # 换场景可能换主题 → 按新地形定万物基底层（themed-terrain P2）
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
	_ensure_slots()  # 换到不同尺寸场景后自愈重建槽（幂等，尺寸没变零成本）
	# 室内不 early-return：仍要重定位槽 + 铺 deco（家具）；只是 _skin 出的地面/水面 mesh 被隐藏。
	var pending: Array = []  # 未铺设槽位 [距离, slot, wrapped]，每帧只铺最近的一块
	# 遍历全部常驻槽（每 wrapped 区块一个），把每个摆到离焦点最近的环面镜像、按半径圆形裁剪。
	# 不再用「以焦点为中心的 (2R+1)² 奇数窗口」——那要求 CHUNKS_PER_SIDE==2R+1（奇数）才能
	# 无缝无重复覆盖世界，而 100 格的 4×4 是偶数、奇数窗口永远盖不平。直接遍历所有槽 +
	# shortest_delta 取最近镜像，对任意边长（偶/奇）都无缝，且成本恒为 CHUNKS_PER_SIDE² 次
	# 定位（75→9、100→16，皆廉价）；75 格下与旧窗口逐槽落点完全一致。
	for slot in _slots:
		var wrapped: Vector2i = slot["wrapped"]
		# 该 wrapped 区块的规范逻辑中心（0..CHUNKS_PER_SIDE-1 区块索引）
		var center_logical := Vector2(
			(float(wrapped.x) + 0.5) * CHUNK_WORLD,
			(float(wrapped.y) + 0.5) * CHUNK_WORLD)
		var d := WorldGrid.shortest_delta(player_logical, center_logical)
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
	tile.visible = not _terrain_hidden   # 室内：地板由 RoomStage 接管，隐藏 chunk 地面 mesh
	var water: MeshInstance3D = slot["water"]
	water.mesh = _water_mesh(wrapped)
	water.visible = not _terrain_hidden

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
			var cat := PackRegistry.category(key)  # ""=未注册（sdf_res/sdf_inline 或漏声明）
			if cat == "baked" or cat == "scatter":
				_batch(batches, key, pos, _jitter_scale(key, hk), yaw)
			elif cat == "node":
				var scene: PackedScene = PackRegistry.load_resource(key)
				if scene != null:
					var sc := PackRegistry.scale(key)
					var inst := _spawn(deco, scene, pos, sc, yaw)
					var ext := _visual_extent(inst, sc)
					building_shadows.append([inst.position, ext.x, ext.y])
			elif rref == "sdf_inline" or rref.begins_with("sdf_res:"):
				_spawn_static_sdf(deco, def, rref, pos, yaw, hk)
			elif rref.begins_with("composed:"):
				_spawn_composed(deco, def, pos)
			elif rref.is_empty():
				push_warning("[items] 未知物品实体 %s（catalog 未载入?），跳过渲染" % id)
			else:
				push_warning("[items] renderRef %s 的键未在 PackRegistry 注册，跳过渲染" % rref)
	# 草地装饰散布（Pokopia 化 P6）：厚叶草簇/大头花密植——落点决策与 mesh 见 TerrainDeco
	# （纯函数确定性，重刷不闪），合批走同一个 batches。占地过滤在此层做：房/树/动态物件
	# 脚下不长（占地是世界状态，纯函数管不着）；角色站位不算占地（暂态，与散布重摆同理）。
	for j in range(CHUNK_TILES):
		for i in range(CHUNK_TILES):
			var ti := Vector2i(i, j)
			var gt := wrapped * CHUNK_TILES + ti
			var d := TerrainDeco.pick(gt)
			if d.is_empty():
				continue
			if not OccupancyMap.is_free_rect(OccupancyMap.tile_to_cell(gt), 2, 2):
				continue
			var off: Vector2 = d["off"]
			_batch(batches, d["key"], _tile_local(ti, wrapped) + Vector3(off.x, 0.0, off.y), d["scale"], d["yaw"])
	# 边缘贴纸层：逐 tile 扫四条边（绝大多数为 0，纯 PackedByteArray 读，开销可忽略）。
	for j in range(CHUNK_TILES):
		for i in range(CHUNK_TILES):
			var ti := Vector2i(i, j)
			var gt := wrapped * CHUNK_TILES + ti
			for side in range(4):
				var sid := TerrainMap.edge_item_id(gt, side)
				if sid.is_empty():
					continue
				var skey := String(ItemCatalog.get_def(sid).get("renderRef", "")).get_slice(":", 1)
				# skey 以 '@' 打头 = 造贴纸的网络资产哈希(sticker:@<hash>),合法;否则须是打包贴纸。
				if not skey.begins_with("@") and PackRegistry.category(skey) != "sticker":
					continue # 未注册/未来的墙篱笆类边缘物走独立分支
				var off: Vector2 = EDGE_OFFSETS[side] * WorldGrid.TILE_SIZE
				var out_n := off.normalized() * STICKER_OUT
				var spos := _tile_local(ti, wrapped) + Vector3(off.x + out_n.x, STICKER_LIFT, off.y + out_n.y)
				_batch(batches, "sticker:" + skey, spos, 1.0, EDGE_YAWS[side])
	_flush_batches(deco, batches)
	_flush_shadows(deco, batches)
	_flush_building_shadows(deco, building_shadows)

## 静态 SDF 物件（矩阵物品层）：spec 来自打包 json（sdf_res:<name>）或实体行内联
## （sdf_inline，语音造物）。wander 来自实体定义；不登记占地（矩阵派生）。
func _spawn_static_sdf(parent: Node3D, def: Dictionary, rref: String, pos: Vector3, yaw: float, seed_v: int) -> void:
	# 预烘焙优先（老板定策：静态 SDF 布景不在 runtime 里烘）：sdf_res 物件若构建期已烘出
	# assets/sdf_props/baked/<name>.res，直接实例化那份静态 mesh（与运行时 bake_and_swap 同款
	# 共享材质），彻底跳过 raymarch + 运行时烘焙。只对无 wander 的静止物件走这条（会游走的仍走 live）。
	if rref.begins_with("sdf_res:") and float(def.get("wander", 0.0)) == 0.0:
		var baked_path := "res://assets/sdf_props/baked/%s.res" % rref.get_slice(":", 1)
		if ResourceLoader.exists(baked_path):
			var mesh := load(baked_path) as Mesh
			if mesh != null:
				var mi := SdfStaticBaker.instance(mesh)
				mi.set_meta("baked_sdf", true)  # 标记：预烘焙的 SDF 物件（test_matrix_skin 据此计入 SDF 节点而非建筑）
				mi.position = pos
				mi.rotation_degrees = Vector3(0.0, yaw, 0.0)
				mi.visible = _props_shown
				parent.add_child(mi)
				# 脚下暗斑与运行时 bake_and_swap._swap 同款（半径公式一致），预烘焙路径也补上免得掉影。
				var ab := mesh.get_aabb()
				BlobShadow.attach(mi, clampf(maxf(ab.size.x, ab.size.z) * 0.4, 0.4, 2.2), true)
				return
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
	# 真静止造物（loco.none∧无spin∧无head∧无ropes）：异步烘焙成零成本静态 mesh 换掉 live，
	# 省掉每帧逐顶点吸附（成本主轴）。会动的造物 bake_and_swap 内部判非静止即原样保留 live。
	# 烘出的静态 mesh 是普通实例、不进 perf_props → 不再被「会动的物件」开关波及（如烘焙树，恒显）。
	# 走绝对节点路径取 autoload 单例（其全局名在 headless --script 编译期不可用，见 sdf_bake_swap.gd）；
	# 取不到（如离屏缩略图渲染无此单例）则不烘焙、prop 保持 live，属安全降级。
	var bake_swap := get_node_or_null(^"/root/SdfBakeSwap")
	if bake_swap != null:
		bake_swap.bake_and_swap(prop)

## 组合物（积木式造物，renderRef 'composed:'）：读 spec 的零件树，画骨架 + 每零件一片子 quad。
## 纸片扁平、正对相机——不套 yaw（纸艺四支柱：正对俯角、禁 yaw 侧摆），底边落在地面。
func _spawn_composed(parent: Node3D, def: Dictionary, pos: Vector3) -> void:
	var spec: Variant = def.get("spec", null)
	if typeof(spec) != TYPE_DICTIONARY:
		return
	var cp := ComposedProp.from_spec(spec)
	cp.position = pos + Vector3(0.0, ComposedProp.HEIGHT * 0.5, 0.0) # 居中骨架抬半高，底边贴地
	cp.visible = _props_shown
	parent.add_child(cp)

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
	var cols := PackedColorArray()    # 顶点 COLOR.r = 本 quad 贴图层索引/255（顶面层 / 崖壁侧壁层）
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
			# cell 种类 = autotile 几何行组；layer = 顶面贴图层索引（写进顶点 COLOR.r）。
			# 路走带描边过渡；沙/雪/瓷砖走无描边 body（几何共享，差异全在 layer）；
			# 水是整格湖床；草地在有效级更低的邻居旁换悬崖边草皮（body 部分 = 崖唇层）。
			var cell_kind := TerrainAtlas.CELL_GRASS
			var layer := TerrainTextures.top_layer(ttype)
			var corners := PackedInt32Array([0, 0, 0, 0])  # 平草地/湖床不看变体
			if ttype == TerrainMap.T_PATH:
				cell_kind = TerrainAtlas.CELL_PATH
				var same := func(q: Vector2i) -> bool: return TerrainMap.tile_type(q) == ttype
				corners = Autotile.corners_from_mask(Autotile.mask_of(t, same))
			elif ttype in TerrainMap.BODY_TYPES:  # 沙/雪/瓷砖：无描边 body，与同类邻居过渡
				cell_kind = TerrainAtlas.CELL_BODY
				var same := func(q: Vector2i) -> bool: return TerrainMap.tile_type(q) == ttype
				corners = Autotile.corners_from_mask(Autotile.mask_of(t, same))
			elif ttype == TerrainMap.T_WATER:
				cell_kind = TerrainAtlas.CELL_WATER  # V_FULL 湖床（岸线由草侧崖缘+岸壁表达）
			elif ttype == TerrainMap.T_GRASS:
				var not_lower := func(q: Vector2i) -> bool: return TerrainMap.tile_floor_level(q) >= fl
				var mask := Autotile.mask_of(t, not_lower)
				if mask != 255:
					cell_kind = TerrainAtlas.CELL_CLIFF_RIM
					layer = TerrainTextures.LAYER_CLIFF_LIP  # body 部分 = 崖唇土色
					corners = Autotile.corners_from_mask(mask)
			var x0 := -half + float(i) * WorldGrid.TILE_SIZE
			var z0 := -half + float(j) * WorldGrid.TILE_SIZE
			# 顶面 4 角 quad（beveled tile 的临崖外缘内缩 + 发 chamfer 斜面倒角）
			_emit_top_face(verts, norms, uvs, uv2s, cols, idx, t, ttype, fl, cell_kind, corners, layer, parity, x0, z0, y, loff)
			# L3 侧壁：邻居有效级更低的边逐级发墙 quad；侧壁贴图层按被抬高 tile（本 tile）类型取
			_emit_walls(verts, norms, uvs, uv2s, cols, idx, t, ttype, fl, x0, z0, loff)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = cols  # 顶点 COLOR.r = 贴图层索引/255（themed-terrain P1）
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

## 通用 4 顶点 facet（顶面倒角/斜面用）：p0..p3 世界顶点（正面绕序 p0→p1→p2→p3），
## 单一法线 nrm，贴图层 layer（写 COLOR.r），atlas 控制 uv 矩形 r，UV2 = 逻辑世界 xz（loff+xz）。
## 与 _emit_quad 同绕序/同 UV 角点顺序，故可直接替代顶面平铺 quad（beveled tile 用）。
func _emit_facet(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, nrm: Vector3, layer: int, r: Rect2, loff: Vector2) -> void:
	var b := verts.size()
	verts.append(p0); verts.append(p1); verts.append(p2); verts.append(p3)
	var lcol := Color(float(layer) / 255.0, 0.0, 0.0, 1.0)
	for k in range(4):
		norms.append(nrm)
		cols.append(lcol)
	uvs.append(r.position)
	uvs.append(Vector2(r.end.x, r.position.y))
	uvs.append(r.end)
	uvs.append(Vector2(r.position.x, r.end.y))
	uv2s.append(loff + Vector2(p0.x, p0.z))
	uv2s.append(loff + Vector2(p1.x, p1.z))
	uv2s.append(loff + Vector2(p2.x, p2.z))
	uv2s.append(loff + Vector2(p3.x, p3.z))
	idx.append_array(PackedInt32Array([b, b + 1, b + 2, b, b + 2, b + 3]))

## 同 _emit_facet 但逐顶点法线（倒角圆润用）：顶缘顶点法线=向上、底缘=墙面水平，
## 插值后光照从顶面平滑扫到墙面 = 圆润棱观感（非单一平法线的「切一刀」硬斜面）；
## 且顶缘与顶面(UP)、底缘与墙面(水平)法线一致 → 顶面→倒角→墙面无光照接缝。
func _emit_facet4n(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n0: Vector3, n1: Vector3, n2: Vector3, n3: Vector3, layer: int, r: Rect2, loff: Vector2) -> void:
	var b := verts.size()
	verts.append(p0); verts.append(p1); verts.append(p2); verts.append(p3)
	norms.append(n0); norms.append(n1); norms.append(n2); norms.append(n3)
	var lcol := Color(float(layer) / 255.0, 0.0, 0.0, 1.0)
	for k in range(4):
		cols.append(lcol)
	uvs.append(r.position)
	uvs.append(Vector2(r.end.x, r.position.y))
	uvs.append(r.end)
	uvs.append(Vector2(r.position.x, r.end.y))
	uv2s.append(loff + Vector2(p0.x, p0.z))
	uv2s.append(loff + Vector2(p1.x, p1.z))
	uv2s.append(loff + Vector2(p2.x, p2.z))
	uv2s.append(loff + Vector2(p3.x, p3.z))
	idx.append_array(PackedInt32Array([b, b + 1, b + 2, b, b + 2, b + 3]))

## 崖顶圆润倒角（fillet）：沿一条临崖边发 BEVEL_SEGS 段弧面，从顶面(法线 UP)绕 90° 圆弧
## 平滑过渡到墙面(法线 h 水平)——顶点法线取弧的径向，位置沿 1/4 圆弧外凸（非单一平斜面「切一刀」）。
## Ca/Cb = 弧心在边两端的世界点（= 内缩顶缘正下方 bevel 处）；up=Vector3.UP；h=向外水平单位向量。
const BEVEL_SEGS := 3
func _emit_fillet(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, ca: Vector3, cb: Vector3, up: Vector3, h: Vector3, bevel: float, layer: int, r: Rect2, loff: Vector2) -> void:
	var prev_a := ca + up * bevel
	var prev_b := cb + up * bevel
	var prev_n := up
	for s in range(1, BEVEL_SEGS + 1):
		var ang := (float(s) / float(BEVEL_SEGS)) * (PI * 0.5)
		var dir := (up * cos(ang) + h * sin(ang)).normalized()
		var cur_a := ca + dir * bevel
		var cur_b := cb + dir * bevel
		_emit_facet4n(verts, norms, uvs, uv2s, cols, idx,
			prev_a, prev_b, cur_b, cur_a, prev_n, prev_n, dir, dir, layer, r, loff)
		prev_a = cur_a
		prev_b = cur_b
		prev_n = dir

## 顶面 4 角 quad。非 beveled tile 走原 _emit_quad 平铺（零回归）。
## beveled tile（TerrainTextures.tile_bevel>0 且有临崖边）：把每个角 quad 临崖的外缘内缩 bevel，
## 并沿临崖边发一道 45° chamfer 斜面（内缩顶缘 y → 崖壁顶 boundary,y-bevel），外凸角补 miter，
## 把「白方糖」的硬直角切成圆润雪盖棱。chamfer 用顶面雪贴图（雪盖滚过棱）+ body 控制 cell（无描边/无墙浮雕）。
## 崖壁顶缘对应下降 bevel 由 _emit_walls 处理（两者在 boundary,y-bevel 处对齐）。
func _emit_top_face(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, t: Vector2i, ttype: int, fl: int, cell_kind: int, corners: PackedInt32Array, layer: int, parity: int, x0: float, z0: float, y: float, loff: Vector2) -> void:
	var half_tile := WorldGrid.TILE_SIZE * 0.5
	var bevel := TerrainTextures.tile_bevel(ttype)
	var cl_nx := TerrainMap.tile_floor_level(t + Vector2i(-1, 0)) < fl
	var cl_px := TerrainMap.tile_floor_level(t + Vector2i(1, 0)) < fl
	var cl_nz := TerrainMap.tile_floor_level(t + Vector2i(0, -1)) < fl
	var cl_pz := TerrainMap.tile_floor_level(t + Vector2i(0, 1)) < fl
	var beveled := bevel > 0.0 and (cl_nx or cl_px or cl_nz or cl_pz)
	var top_lyr := TerrainTextures.top_layer(ttype)  # chamfer 用顶面贴图（雪盖）
	var body_r := TerrainAtlas.uv_rect(TerrainAtlas.CELL_BODY, Autotile.C_NW, Autotile.V_FULL, parity)
	var lcol := Color(float(layer) / 255.0, 0.0, 0.0, 1.0)
	var yb := y - bevel
	for c in range(4):
		var right := c == Autotile.C_NE or c == Autotile.C_SE
		var down := c == Autotile.C_SW or c == Autotile.C_SE
		var cx := x0 + (half_tile if right else 0.0)
		var cz := z0 + (half_tile if down else 0.0)
		var r := TerrainAtlas.uv_rect(cell_kind, c, corners[c], parity)
		if not beveled:
			_emit_quad(verts, norms, uvs, uv2s, idx, cx, cz, y, half_tile, r, loff)
			for _k in range(4):
				cols.append(lcol)
			continue
		# 本角 quad 的两条外缘（-x/+x 取决 right，-z/+z 取决 down）临崖则内缩
		var ins_nx := (not right) and cl_nx
		var ins_px := right and cl_px
		var ins_nz := (not down) and cl_nz
		var ins_pz := down and cl_pz
		var qx0 := cx + (bevel if ins_nx else 0.0)
		var qx1 := cx + half_tile - (bevel if ins_px else 0.0)
		var qz0 := cz + (bevel if ins_nz else 0.0)
		var qz1 := cz + half_tile - (bevel if ins_pz else 0.0)
		_emit_facet(verts, norms, uvs, uv2s, cols, idx,
			Vector3(qx0, y, qz0), Vector3(qx1, y, qz0), Vector3(qx1, y, qz1), Vector3(qx0, y, qz1),
			Vector3.UP, layer, r, loff)
		var NX := Vector3(-1, 0, 0)
		var PX := Vector3(1, 0, 0)
		var NZ := Vector3(0, 0, -1)
		var PZ := Vector3(0, 0, 1)
		# 圆润倒角 fillet（1/4 圆弧外凸 + 径向平滑法线），四边各一道
		if ins_nx:
			_emit_fillet(verts, norms, uvs, uv2s, cols, idx,
				Vector3(qx0, yb, qz0), Vector3(qx0, yb, qz1), Vector3.UP, NX, bevel, top_lyr, body_r, loff)
		if ins_px:
			_emit_fillet(verts, norms, uvs, uv2s, cols, idx,
				Vector3(qx1, yb, qz1), Vector3(qx1, yb, qz0), Vector3.UP, PX, bevel, top_lyr, body_r, loff)
		if ins_nz:
			_emit_fillet(verts, norms, uvs, uv2s, cols, idx,
				Vector3(qx1, yb, qz0), Vector3(qx0, yb, qz0), Vector3.UP, NZ, bevel, top_lyr, body_r, loff)
		if ins_pz:
			_emit_fillet(verts, norms, uvs, uv2s, cols, idx,
				Vector3(qx0, yb, qz1), Vector3(qx1, yb, qz1), Vector3.UP, PZ, bevel, top_lyr, body_r, loff)
		# 外凸角 miter：两邻边都临崖 → 补角圆润斜面（顶=UP、底=两墙法线对角），否则外角留缺口
		if ins_nx and ins_nz:
			_emit_facet4n(verts, norms, uvs, uv2s, cols, idx,
				Vector3(qx0, y, qz0), Vector3(cx, yb, qz0), Vector3(cx, yb, cz), Vector3(qx0, yb, cz),
				Vector3.UP, NX, (NX + NZ).normalized(), NZ, top_lyr, body_r, loff)
		if ins_px and ins_nz:
			_emit_facet4n(verts, norms, uvs, uv2s, cols, idx,
				Vector3(qx1, y, qz0), Vector3(qx1, yb, cz), Vector3(cx + half_tile, yb, cz), Vector3(cx + half_tile, yb, qz0),
				Vector3.UP, NZ, (PX + NZ).normalized(), PX, top_lyr, body_r, loff)
		if ins_nx and ins_pz:
			_emit_facet4n(verts, norms, uvs, uv2s, cols, idx,
				Vector3(qx0, y, qz1), Vector3(qx0, yb, cz + half_tile), Vector3(cx, yb, cz + half_tile), Vector3(cx, yb, qz1),
				Vector3.UP, PZ, (NX + PZ).normalized(), NX, top_lyr, body_r, loff)
		if ins_px and ins_pz:
			_emit_facet4n(verts, norms, uvs, uv2s, cols, idx,
				Vector3(qx1, y, qz1), Vector3(cx + half_tile, yb, qz1), Vector3(cx + half_tile, yb, cz + half_tile), Vector3(qx1, yb, cz + half_tile),
				Vector3.UP, PX, (PX + PZ).normalized(), PZ, top_lyr, body_r, loff)

## tile 四边中「邻居有效级更低」的边发竖直崖壁/水下岸壁。每级 = 一个 2m×2m 墙格，
## 墙格对同一墙面的 8 邻墙格（沿墙走向左右 × 层级上下 × 对角）做 corner autotile：
## 有邻墙 = 相连，无邻墙侧出凹缝暗边 + 亮棱线。墙格再切 4 个 1m 角 quad 按变体取 UV。
## tile 局部范围 [x0, x0+2]×[z0, z0+2]，本 tile 有效级 fl（湖床可为负）。
## UV2 = (沿墙逻辑坐标, 世界 y)——竖直面按墙走向平铺贴图。
func _emit_walls(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, t: Vector2i, ttype: int, fl: int, x0: float, z0: float, loff: Vector2) -> void:
	var ts := WorldGrid.TILE_SIZE
	# 侧壁贴图层 = 被抬高 tile（本 tile）类型对应的侧壁层（修 CLIFF_WALL 写死的偷懒）
	var side_layer := float(TerrainTextures.side_layer(ttype)) / 255.0
	# 盖帽涂装（Pokopia 化 P4）用两个空闲顶点色通道：
	# g = 顶面层索引（盖帽取顶面平色，生态身份跟着顶面走）；
	# b = 距崖顶深度 below/2m（clamp 到 [0,1]；shader 只关心 <0.6m 的帽区，8bit 精度 ~8mm 足够；
	#     跨 clamp 的 quad 在 0..2m 内逐段线性，帽区判定不受插值失真影响）。
	var cap_lyr := float(TerrainTextures.top_layer(ttype)) / 255.0
	# beveled tile：最顶一级墙面顶缘下降 bevel，给顶面 chamfer 斜面让位（在 boundary,y-bevel 处对齐）
	var bevel := TerrainTextures.tile_bevel(ttype)
	var wall_top := float(fl) * TerrainMap.STEP_HEIGHT - bevel
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
		# 墙脚 AO（Pokopia 化 P5）：COLOR.a 编码「离墙基高度/2m」（墙基=邻居有效地面=
		# 内凹角所在），shader 对 <0.45m 的墙脚压暗——内凹角的柔和接触暗缝。
		var wall_base := float(nfl) * TerrainMap.STEP_HEIGHT
		for lvl in range(nfl, fl):
			# (q.x, q.y) = (沿墙偏移, 视觉上下偏移)；atlas 的 N(-1) = 上一级
			var pred := func(q: Vector2i) -> bool:
				return _wall_exists(t + tang * q.x, n_off, lvl - q.y)
			var corners := Autotile.corners_from_mask(Autotile.mask_of(Vector2i.ZERO, pred))
			var y_top := float(lvl + 1) * TerrainMap.STEP_HEIGHT
			if lvl == fl - 1:
				y_top -= bevel  # 顶级让位给 chamfer（非 beveled tile bevel=0，无变化）
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
				var col_t := Color(side_layer, cap_lyr, clampf((wall_top - yt) * 0.5, 0.0, 1.0), clampf((yt - wall_base) * 0.5, 0.0, 1.0))
				var col_b := Color(side_layer, cap_lyr, clampf((wall_top - yb) * 0.5, 0.0, 1.0), clampf((yb - wall_base) * 0.5, 0.0, 1.0))
				for k in range(4):
					norms.append(s["normal"])
				cols.append(col_t)
				cols.append(col_t)
				cols.append(col_b)
				cols.append(col_b)
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
		mmi.set_meta("scatter_key", key)  # 散布种类 key（矩阵散布 / TerrainDeco 装饰 / sticker: 三源同池，元数据留痕供测试与调试区分）
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

## 造贴纸的网络资产贴图缓存（hash→Texture2D）：world 侧按 renderRef 'sticker:@<hash>' 预热
## （api.fetch_texture），本类 _scatter_kind 同步读。缓存后 world 触发 rebuild() 用真图重建。
static var _sticker_asset_tex: Dictionary = {}
static var _sticker_placeholder_tex: Texture2D = null

## 1×1 透明占位（资产贴图未到时用，绝不崩；到货后 rebuild 换真图）。
static func _sticker_placeholder() -> Texture2D:
	if _sticker_placeholder_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.set_pixel(0, 0, Color(1, 1, 1, 0))
		_sticker_placeholder_tex = ImageTexture.create_from_image(img)
	return _sticker_placeholder_tex

## world 预热完成后灌入资产贴图：存缓存 + 失效该键的散布种类（下次 rebuild 用真图+真宽高比重建）。
static func cache_sticker_asset(hash: String, tex: Texture2D) -> void:
	if tex == null:
		return
	_sticker_asset_tex[hash] = tex
	_scatter_kinds.erase("sticker:@" + hash) # 丢掉占位版本，逼 _scatter_kind 用真图重建

## world 预热前查重：已缓存就不重复拉网络。
static func has_sticker_asset(hash: String) -> bool:
	return _sticker_asset_tex.has(hash)

## 同步取已缓存的造贴纸资产贴图（角色锚点贴纸盘用）；未预热到 → null。
static func get_sticker_asset(hash: String) -> Texture2D:
	return _sticker_asset_tex.get(hash) as Texture2D

func _scatter_kind(key: String) -> Dictionary:
	if _scatter_kinds.has(key):
		return _scatter_kinds[key]
	var info := {}
	if key.begins_with("sticker:"):
		# 贴纸竖片：QuadMesh 底边对齐原点（center_offset 上移半高），宽按贴图比例；
		# 打包贴纸经 PackRegistry 运行时 load；造贴纸(skey '@<hash>')从资产缓存取，未到用透明占位。
		var skey := key.get_slice(":", 1)
		var tex: Texture2D
		if skey.begins_with("@"):
			tex = _sticker_asset_tex.get(skey.substr(1)) as Texture2D
			if tex == null:
				tex = _sticker_placeholder()
		else:
			tex = PackRegistry.load_resource(skey) as Texture2D
		var q := QuadMesh.new()
		var w := STICKER_H * (float(tex.get_width()) / float(tex.get_height()) if tex != null else 1.0)
		q.size = Vector2(w, STICKER_H)
		q.center_offset = Vector3(0.0, STICKER_H * 0.5, 0.0)
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/sticker_edge.gdshader")
		m.set_shader_parameter("albedo_tex", tex)
		m.set_shader_parameter("curvature", BendMat.CURVATURE)
		info = { "mesh": q, "mat": m }
	elif key.begins_with("deco_"):
		# 草地装饰散布（Pokopia 化 P6）：程序化低模 mesh + 烘焙布景共享顶点色材质
		info = { "mesh": TerrainDeco.mesh(key), "mat": SdfStaticBaker.material() }
	elif PackRegistry.category(key) == "baked":
		info = { "mesh": PackRegistry.load_resource(key), "mat": SdfStaticBaker.material() }
	else:  # scatter：KayKit 场景剥出 mesh + bend 包裹材质
		var scene: PackedScene = PackRegistry.load_resource(key)
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
	_activate_prop_animation(inst)
	_spawn_fan_spinner(inst)
	return inst

## node 类 glb 自带的骨骼/关键帧动画不会自播（Godot 导入默认不置 AnimationPlayer.autoplay）——
## 历史上恐龙/机器人/鱼等摆件都揣着现成动画却僵在第 0 帧。此处兜底：实例化后若树内有
## AnimationPlayer 且带 clip，就把首个 clip 设循环并 play()。无 AnimationPlayer 的静态建筑
## （KayKit 六边形集：风车/树/井）此函数是空操作，零开销；风车的转动走 _spawn_fan_spinner（P2）。
func _activate_prop_animation(inst: Node3D) -> void:
	for ap in inst.find_children("*", "AnimationPlayer", true, false):
		var anim: AnimationPlayer = ap
		var names := anim.get_animation_list()
		if names.is_empty():
			continue
		# 跳过 Godot 导入内建的 "RESET" 姿态轨（非真动画），取第一个真 clip
		var clip := ""
		for nm in names:
			if String(nm) != "RESET":
				clip = String(nm)
				break
		if clip.is_empty():
			continue
		var a := anim.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		anim.play(clip)

## 风车扇叶匀速转（models-play-animation P2）：KayKit 六边形集的风车 glb 不带动画轨，
## 但把扇叶做成独立命名子节点（building_windmill_top_fan_*）。给每个这样的子节点挂一个
## PropSpinner 程序化绕盘面法线自转。非风车 glb（名里无 _top_fan_）此函数是空操作。
func _spawn_fan_spinner(inst: Node3D) -> void:
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		if not String(mi.name).contains("_top_fan_"):
			continue
		var spinner := PropSpinner.new()
		mi.add_child(spinner)

## SDF 语音物件摆放：占地判定 + 螺旋找位，实例化 SdfProp 并启用锚点游走。
## 材质自带 world-bend 项（sdf_field.gdshaderinc），不走 BendMat.wrap_scene。
## 语音生成的物件进世界：围绕 want_tile 螺旋找空位（钳在区块内防跨块归属混乱），
## 成功则登记运行时清单（此后区块重刷自动原位重生成）并返回落位 tile；失败返回 (-1,-1)。
## id 供拾起/挪位按物件寻址；search=0 表示精确落位（拖拽摆放 tile 吸附，不螺旋）。
func add_dynamic_prop(spec_data: Dictionary, want_tile: Vector2i, yaw := 0.0, wander := 0.0, id := "", search := 3) -> Vector2i:
	var n := WorldGrid.GRID_TILES
	want_tile = Vector2i(posmod(want_tile.x, n), posmod(want_tile.y, n))
	var wrapped := Vector2i(want_tile.x / CHUNK_TILES, want_tile.y / CHUNK_TILES)
	# 找当前持有该 wrapped 区块的 slot（常驻槽池覆盖全部 wrapped 区块，必在）
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
