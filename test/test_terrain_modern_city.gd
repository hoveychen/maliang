extends SceneTree
## 现代城市垂直切片验收（themed-terrain P3）：
## ① export_modern_city.gd 种子场景含全部地表（沥青/人行道砖/斑马线/水泥/草坪格）+ 水体，可自产自销载入；
## ② TerrainTextures.top_layer/side_layer 对新类型返回正确层；
## ③ 受控地形——抬高的水泥走水泥侧壁层、抬高的人行道砖走砖侧壁层（延续 P1 类型化侧壁）；
## ④ 万物基底层按场景模态地表——现代城市切片(沥青为多)→ 沥青层。
## 运行: godot --headless --script res://test/test_terrain_modern_city.gd

const CITY := preload("res://tools/export_modern_city.gd")
const HEADER := 11

var fails := 0

func _init() -> void:
	_test_seed_scene_coverage()
	_test_layer_mappings()
	_test_type_aware_walls()
	_test_base_layer_modal()
	print("test_terrain_modern_city: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _test_seed_scene_coverage() -> void:
	var bytes := CITY.build_terrain_bytes()
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(bytes)
	_check("现代城市种子场景载入 ok", lr["ok"], true)

	var n := WorldGrid.GRID_TILES
	var seen := {}
	for z in range(n):
		for x in range(n):
			seen[TerrainMap.tile_type(Vector2i(x, z))] = true
	for t in [TerrainMap.T_ASPHALT, TerrainMap.T_PAVER_BRICK, TerrainMap.T_CROSSWALK,
			TerrainMap.T_CONCRETE, TerrainMap.T_LAWN_GRID, TerrainMap.T_WATER]:
		_check("种子场景出现 tile 类型 %d" % t, seen.has(t), true)
	for t in seen.keys():
		_check("tile 类型 %d 在 VALID_TYPES" % t, t in TerrainMap.VALID_TYPES, true)
	TerrainMap.reset()

func _test_layer_mappings() -> void:
	var TT := TerrainTextures
	_check("top T_ASPHALT", TT.top_layer(TerrainMap.T_ASPHALT), TT.LAYER_ASPHALT)
	_check("top T_PAVER_BRICK", TT.top_layer(TerrainMap.T_PAVER_BRICK), TT.LAYER_PAVER_BRICK)
	_check("top T_CROSSWALK", TT.top_layer(TerrainMap.T_CROSSWALK), TT.LAYER_CROSSWALK)
	_check("top T_CONCRETE", TT.top_layer(TerrainMap.T_CONCRETE), TT.LAYER_CONCRETE)
	_check("top T_LAWN_GRID", TT.top_layer(TerrainMap.T_LAWN_GRID), TT.LAYER_LAWN_GRID)
	_check("side T_CONCRETE = 水泥层", TT.side_layer(TerrainMap.T_CONCRETE), TT.LAYER_CONCRETE)
	_check("side T_PAVER_BRICK = 砖层", TT.side_layer(TerrainMap.T_PAVER_BRICK), TT.LAYER_PAVER_BRICK)
	_check("side T_CONCRETE ≠ 兜底岩壁", TT.side_layer(TerrainMap.T_CONCRETE) != TT.LAYER_CLIFF_WALL, true)
	_check("LAYER_TEX_PATHS 数 = LAYER_COUNT", TT.LAYER_TEX_PATHS.size(), TT.LAYER_COUNT)

func _test_type_aware_walls() -> void:
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(_controlled_bytes())
	_check("受控地形载入 ok", lr["ok"], true)
	_check("concrete tile 抬高", TerrainMap.tile_height(Vector2i(5, 5)), 1)
	_check("brick tile 抬高", TerrainMap.tile_height(Vector2i(10, 10)), 1)

	var cm := ChunkManager.new()
	var mesh: ArrayMesh = cm._chunk_mesh(Vector2i(0, 0))
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]

	var wall_layers := {}
	for i in range(verts.size()):
		if absf(norms[i].y) < 0.01:
			wall_layers[int(round(cols[i].r * 255.0))] = true
	_check("崖壁含水泥侧壁层", wall_layers.has(TerrainTextures.LAYER_CONCRETE), true)
	_check("崖壁含砖侧壁层", wall_layers.has(TerrainTextures.LAYER_PAVER_BRICK), true)
	_check("崖壁侧壁层 ≥ 2 种", wall_layers.size() >= 2, true)

	cm.free()
	TerrainMap.reset()

func _test_base_layer_modal() -> void:
	var cm := ChunkManager.new()
	TerrainMap.reset()
	TerrainMap.load_from_bytes(CITY.build_terrain_bytes())
	cm.rebuild()
	_check("现代城市场景基底层 = 沥青", cm._base_layer, TerrainTextures.LAYER_ASPHALT)
	cm.free()
	TerrainMap.reset()

func _controlled_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var buf := PackedByteArray()
	buf.resize(HEADER + 3 * count)
	for i in range(4):
		buf[i] = "MLTR".unicode_at(i)
	buf[4] = 1
	buf[5] = n
	buf[6] = n
	buf.encode_float(7, WorldGrid.TILE_SIZE)
	var conc := 5 * n + 5
	var brick := 10 * n + 10
	buf[HEADER + conc] = TerrainMap.T_CONCRETE
	buf[HEADER + count + conc] = 1
	buf[HEADER + brick] = TerrainMap.T_PAVER_BRICK
	buf[HEADER + count + brick] = 1
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)])
		fails += 1
