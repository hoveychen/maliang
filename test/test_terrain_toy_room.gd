extends SceneTree
## 玩具房间垂直切片验收（themed-terrain P3）：
## ① export_toy_room.gd 种子场景含全部地表（木地板/地毯红/地毯蓝/拼图垫/瓷砖），可自产自销载入（室内无水）；
## ② TerrainTextures.top_layer/side_layer 对新类型返回正确层；
## ③ 受控地形——抬高的木地板走木侧壁层、抬高的瓷砖走瓷砖侧壁层（延续 P1 类型化侧壁）；
## ④ 万物基底层按场景模态地表——玩具房间切片(木地板为多)→ 木地板层。
## 运行: godot --headless --script res://test/test_terrain_toy_room.gd

const TOY := preload("res://tools/export_toy_room.gd")
const HEADER := 11

var fails := 0

func _init() -> void:
	_test_seed_scene_coverage()
	_test_layer_mappings()
	_test_type_aware_walls()
	_test_base_layer_modal()
	print("test_terrain_toy_room: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _test_seed_scene_coverage() -> void:
	var bytes := TOY.build_terrain_bytes()
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(bytes)
	_check("玩具房间种子场景载入 ok", lr["ok"], true)

	var n := WorldGrid.GRID_TILES
	var seen := {}
	for z in range(n):
		for x in range(n):
			seen[TerrainMap.tile_type(Vector2i(x, z))] = true
	for t in [TerrainMap.T_WOOD_FLOOR, TerrainMap.T_CARPET_RED, TerrainMap.T_CARPET_BLUE,
			TerrainMap.T_PUZZLE_MAT, TerrainMap.T_TILE, TerrainMap.T_TOY_WALL]:
		_check("种子场景出现 tile 类型 %d" % t, seen.has(t), true)
	# 房间四壁：存在被抬高（h≥2）的 T_TOY_WALL 墙 tile
	var wall_raised := false
	for z in range(n):
		for x in range(n):
			if TerrainMap.tile_type(Vector2i(x, z)) == TerrainMap.T_TOY_WALL and TerrainMap.tile_height(Vector2i(x, z)) >= 2:
				wall_raised = true
	_check("房间墙面 tile 抬高成墙(h≥2)", wall_raised, true)
	for t in seen.keys():
		_check("tile 类型 %d 在 VALID_TYPES" % t, t in TerrainMap.VALID_TYPES, true)
	TerrainMap.reset()

func _test_layer_mappings() -> void:
	var TT := TerrainTextures
	_check("top T_CARPET_RED", TT.top_layer(TerrainMap.T_CARPET_RED), TT.LAYER_CARPET_RED)
	_check("top T_CARPET_BLUE", TT.top_layer(TerrainMap.T_CARPET_BLUE), TT.LAYER_CARPET_BLUE)
	_check("top T_PUZZLE_MAT", TT.top_layer(TerrainMap.T_PUZZLE_MAT), TT.LAYER_PUZZLE_MAT)
	_check("top T_WOOD_FLOOR", TT.top_layer(TerrainMap.T_WOOD_FLOOR), TT.LAYER_WOOD_FLOOR)
	_check("side T_WOOD_FLOOR = 木层", TT.side_layer(TerrainMap.T_WOOD_FLOOR), TT.LAYER_WOOD_FLOOR)
	_check("side T_TILE = 瓷砖层", TT.side_layer(TerrainMap.T_TILE), TT.LAYER_TILE)
	_check("top T_TOY_WALL = 墙面层", TT.top_layer(TerrainMap.T_TOY_WALL), TT.LAYER_TOY_WALL)
	_check("side T_TOY_WALL = 墙面层", TT.side_layer(TerrainMap.T_TOY_WALL), TT.LAYER_TOY_WALL)
	_check("LAYER_TEX_PATHS 数 = LAYER_COUNT", TT.LAYER_TEX_PATHS.size(), TT.LAYER_COUNT)

func _test_type_aware_walls() -> void:
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(_controlled_bytes())
	_check("受控地形载入 ok", lr["ok"], true)
	_check("wood tile 抬高", TerrainMap.tile_height(Vector2i(5, 5)), 1)
	_check("tile tile 抬高", TerrainMap.tile_height(Vector2i(10, 10)), 1)

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
	_check("崖壁含木侧壁层", wall_layers.has(TerrainTextures.LAYER_WOOD_FLOOR), true)
	_check("崖壁含瓷砖侧壁层", wall_layers.has(TerrainTextures.LAYER_TILE), true)
	_check("崖壁侧壁层 ≥ 2 种", wall_layers.size() >= 2, true)

	cm.free()
	TerrainMap.reset()

func _test_base_layer_modal() -> void:
	var cm := ChunkManager.new()
	TerrainMap.reset()
	TerrainMap.load_from_bytes(TOY.build_terrain_bytes())
	cm.rebuild()
	_check("玩具房间场景基底层 = 木地板", cm._base_layer, TerrainTextures.LAYER_WOOD_FLOOR)
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
	var wood := 5 * n + 5
	var tile := 10 * n + 10
	buf[HEADER + wood] = TerrainMap.T_WOOD_FLOOR
	buf[HEADER + count + wood] = 1
	buf[HEADER + tile] = TerrainMap.T_TILE
	buf[HEADER + count + tile] = 1
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)])
		fails += 1
