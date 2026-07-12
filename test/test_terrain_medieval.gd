extends SceneTree
## 中世纪垂直切片验收（themed-terrain P3）：
## ① export_medieval.gd 种子场景含全部中世纪地表（草地/泥土路/鹅卵石/石板/农田垄）+ 水体，可自产自销载入；
## ② TerrainTextures.top_layer/side_layer 对新类型返回正确层；
## ③ 受控地形——抬高的石板走石板侧壁层、抬高的鹅卵石走鹅卵石侧壁层（延续 P1 类型化侧壁）；
## ④ 万物基底层按场景模态地表——中世纪切片(草地为多)→ 草层（村庄不回归）。
## 运行: godot --headless --script res://test/test_terrain_medieval.gd

const MEDIEVAL := preload("res://tools/export_medieval.gd")
const HEADER := 11

var fails := 0

func _init() -> void:
	_test_seed_scene_coverage()
	_test_layer_mappings()
	_test_type_aware_walls()
	_test_base_layer_modal()
	print("test_terrain_medieval: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _test_seed_scene_coverage() -> void:
	var bytes := MEDIEVAL.build_terrain_bytes()
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(bytes)
	_check("中世纪种子场景载入 ok", lr["ok"], true)

	var n := WorldGrid.GRID_TILES
	var seen := {}
	for z in range(n):
		for x in range(n):
			seen[TerrainMap.tile_type(Vector2i(x, z))] = true
	for t in [TerrainMap.T_GRASS, TerrainMap.T_PATH, TerrainMap.T_COBBLE,
			TerrainMap.T_STONE_SLAB, TerrainMap.T_FARM_FURROW, TerrainMap.T_WATER]:
		_check("种子场景出现 tile 类型 %d" % t, seen.has(t), true)
	for t in seen.keys():
		_check("tile 类型 %d 在 VALID_TYPES" % t, t in TerrainMap.VALID_TYPES, true)
	TerrainMap.reset()

func _test_layer_mappings() -> void:
	var TT := TerrainTextures
	_check("top T_COBBLE", TT.top_layer(TerrainMap.T_COBBLE), TT.LAYER_COBBLE)
	_check("top T_STONE_SLAB", TT.top_layer(TerrainMap.T_STONE_SLAB), TT.LAYER_STONE_SLAB)
	_check("top T_FARM_FURROW", TT.top_layer(TerrainMap.T_FARM_FURROW), TT.LAYER_FARM_FURROW)
	_check("side T_STONE_SLAB = 石板层", TT.side_layer(TerrainMap.T_STONE_SLAB), TT.LAYER_STONE_SLAB)
	_check("side T_COBBLE = 鹅卵石层", TT.side_layer(TerrainMap.T_COBBLE), TT.LAYER_COBBLE)
	_check("side T_STONE_SLAB ≠ 兜底岩壁", TT.side_layer(TerrainMap.T_STONE_SLAB) != TT.LAYER_CLIFF_WALL, true)
	_check("LAYER_TEX_PATHS 数 = LAYER_COUNT", TT.LAYER_TEX_PATHS.size(), TT.LAYER_COUNT)

func _test_type_aware_walls() -> void:
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(_controlled_bytes())
	_check("受控地形载入 ok", lr["ok"], true)
	_check("slab tile 抬高", TerrainMap.tile_height(Vector2i(5, 5)), 1)
	_check("cobble tile 抬高", TerrainMap.tile_height(Vector2i(10, 10)), 1)

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
	_check("崖壁含石板侧壁层", wall_layers.has(TerrainTextures.LAYER_STONE_SLAB), true)
	_check("崖壁含鹅卵石侧壁层", wall_layers.has(TerrainTextures.LAYER_COBBLE), true)
	_check("崖壁侧壁层 ≥ 2 种", wall_layers.size() >= 2, true)

	cm.free()
	TerrainMap.reset()

func _test_base_layer_modal() -> void:
	var cm := ChunkManager.new()
	TerrainMap.reset()
	TerrainMap.load_from_bytes(MEDIEVAL.build_terrain_bytes())
	cm.rebuild()
	_check("中世纪场景基底层 = 草", cm._base_layer, TerrainTextures.LAYER_GRASS)
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
	var slab := 5 * n + 5
	var cob := 10 * n + 10
	buf[HEADER + slab] = TerrainMap.T_STONE_SLAB
	buf[HEADER + count + slab] = 1
	buf[HEADER + cob] = TerrainMap.T_COBBLE
	buf[HEADER + count + cob] = 1
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)])
		fails += 1
