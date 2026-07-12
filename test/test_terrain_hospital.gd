extends SceneTree
## 医院垂直切片验收（themed-terrain P3）：覆盖 + 层映射 + 类型化侧壁（瓷砖/混凝土）+ 模态基底(浅绿地胶)。室内无水。
## 运行: godot --headless --script res://test/test_terrain_hospital.gd

const HOSPITAL := preload("res://tools/export_hospital.gd")
const HEADER := 11
var fails := 0

func _init() -> void:
	_cover(); _maps(); _walls(); _base()
	print("test_terrain_hospital: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _cover() -> void:
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(HOSPITAL.build_terrain_bytes())
	_check("医院种子场景载入 ok", lr["ok"], true)
	var n := WorldGrid.GRID_TILES
	var seen := {}
	for z in range(n):
		for x in range(n):
			seen[TerrainMap.tile_type(Vector2i(x, z))] = true
	for t in [TerrainMap.T_MED_VINYL_GREEN, TerrainMap.T_TILE, TerrainMap.T_ANTISLIP,
			TerrainMap.T_CONCRETE, TerrainMap.T_MED_VINYL_BLUE]:
		_check("出现 tile 类型 %d" % t, seen.has(t), true)
	for t in seen.keys():
		_check("类型 %d 在 VALID_TYPES" % t, t in TerrainMap.VALID_TYPES, true)
	TerrainMap.reset()

func _maps() -> void:
	var TT := TerrainTextures
	_check("top T_MED_VINYL_GREEN", TT.top_layer(TerrainMap.T_MED_VINYL_GREEN), TT.LAYER_MED_VINYL_GREEN)
	_check("top T_MED_VINYL_BLUE", TT.top_layer(TerrainMap.T_MED_VINYL_BLUE), TT.LAYER_MED_VINYL_BLUE)
	_check("top T_ANTISLIP", TT.top_layer(TerrainMap.T_ANTISLIP), TT.LAYER_ANTISLIP)
	_check("side T_TILE = 瓷砖层", TT.side_layer(TerrainMap.T_TILE), TT.LAYER_TILE)
	_check("side T_CONCRETE = 混凝土层", TT.side_layer(TerrainMap.T_CONCRETE), TT.LAYER_CONCRETE)
	_check("LAYER_TEX_PATHS 数 = LAYER_COUNT", TT.LAYER_TEX_PATHS.size(), TT.LAYER_COUNT)

func _walls() -> void:
	TerrainMap.reset()
	TerrainMap.load_from_bytes(_ctrl(TerrainMap.T_TILE, TerrainMap.T_CONCRETE))
	var cm := ChunkManager.new()
	var arrays := cm._chunk_mesh(Vector2i(0, 0)).surface_get_arrays(0)
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var wl := {}
	for i in range(norms.size()):
		if absf(norms[i].y) < 0.01:
			wl[int(round(cols[i].r * 255.0))] = true
	_check("崖壁含瓷砖侧壁层", wl.has(TerrainTextures.LAYER_TILE), true)
	_check("崖壁含混凝土侧壁层", wl.has(TerrainTextures.LAYER_CONCRETE), true)
	_check("崖壁侧壁层 ≥ 2 种", wl.size() >= 2, true)
	cm.free(); TerrainMap.reset()

func _base() -> void:
	var cm := ChunkManager.new()
	TerrainMap.reset(); TerrainMap.load_from_bytes(HOSPITAL.build_terrain_bytes()); cm.rebuild()
	_check("医院场景基底层 = 浅绿地胶", cm._base_layer, TerrainTextures.LAYER_MED_VINYL_GREEN)
	cm.free(); TerrainMap.reset()

func _ctrl(ta: int, tb: int) -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var buf := PackedByteArray(); buf.resize(HEADER + 3 * count)
	for i in range(4):
		buf[i] = "MLTR".unicode_at(i)
	buf[4] = 1; buf[5] = n; buf[6] = n; buf.encode_float(7, WorldGrid.TILE_SIZE)
	var a := 5 * n + 5
	var b := 10 * n + 10
	buf[HEADER + a] = ta; buf[HEADER + count + a] = 1
	buf[HEADER + b] = tb; buf[HEADER + count + b] = 1
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)]); fails += 1
