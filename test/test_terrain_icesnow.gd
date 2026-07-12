extends SceneTree
## 冰雪世界垂直切片验收（themed-terrain P3）：
## ① export_icesnow.gd 产出的种子场景含全部冰雪地表（压实雪/雪原/冰面/雪泥/裸岩积雪）+ 水体，
##    且可自产自销载入；
## ② TerrainTextures.top_layer/side_layer 对新类型返回正确层；
## ③ 受控地形——抬高的裸岩 tile 走裸岩侧壁层、抬高的压实雪 tile 走压实雪侧壁层
##    （不同类型抬高块出不同崖壁，延续 P1「按被抬高 tile 类型选侧壁」）；
## ④ 万物基底层按场景模态地表——冰雪切片(压实雪为多)→ 压实雪层。
## 运行: godot --headless --script res://test/test_terrain_icesnow.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

const ICESNOW := preload("res://tools/export_icesnow.gd")
const HEADER := 11

var fails := 0

func _init() -> void:
	_test_seed_scene_coverage()
	_test_layer_mappings()
	_test_type_aware_walls()
	_test_base_layer_modal()
	print("test_terrain_icesnow: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## ① 种子场景：导出字节可载入 + 全部冰雪地表 + 水体全部出现
func _test_seed_scene_coverage() -> void:
	var bytes := ICESNOW.build_terrain_bytes()
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(bytes)
	_check("冰雪种子场景载入 ok", lr["ok"], true)

	var n := WorldGrid.GRID_TILES
	var seen := {}
	for z in range(n):
		for x in range(n):
			seen[TerrainMap.tile_type(Vector2i(x, z))] = true
	for t in [TerrainMap.T_PACKED_SNOW, TerrainMap.T_SNOW, TerrainMap.T_ICE,
			TerrainMap.T_SLUSH, TerrainMap.T_ROCK_SNOW, TerrainMap.T_WATER]:
		_check("种子场景出现 tile 类型 %d" % t, seen.has(t), true)
	for t in seen.keys():
		_check("tile 类型 %d 在 VALID_TYPES" % t, t in TerrainMap.VALID_TYPES, true)
	TerrainMap.reset()

## ② 层映射：新类型 → 正确顶面/侧壁层
func _test_layer_mappings() -> void:
	var TT := TerrainTextures
	_check("top T_PACKED_SNOW", TT.top_layer(TerrainMap.T_PACKED_SNOW), TT.LAYER_PACKED_SNOW)
	_check("top T_ICE", TT.top_layer(TerrainMap.T_ICE), TT.LAYER_ICE)
	_check("top T_SLUSH", TT.top_layer(TerrainMap.T_SLUSH), TT.LAYER_SLUSH)
	_check("top T_ROCK_SNOW", TT.top_layer(TerrainMap.T_ROCK_SNOW), TT.LAYER_ROCK_SNOW)
	# 侧壁：可抬高的裸岩/压实雪有专属侧壁（= 各自顶面层），非兜底岩壁
	_check("side T_ROCK_SNOW = 裸岩层", TT.side_layer(TerrainMap.T_ROCK_SNOW), TT.LAYER_ROCK_SNOW)
	_check("side T_PACKED_SNOW = 压实雪层", TT.side_layer(TerrainMap.T_PACKED_SNOW), TT.LAYER_PACKED_SNOW)
	_check("side T_ROCK_SNOW ≠ 兜底岩壁", TT.side_layer(TerrainMap.T_ROCK_SNOW) != TT.LAYER_CLIFF_WALL, true)
	_check("LAYER_TEX_PATHS 数 = LAYER_COUNT", TT.LAYER_TEX_PATHS.size(), TT.LAYER_COUNT)

## ③ 受控地形：裸岩(5,5) 抬高、压实雪(10,10) 抬高，各自崖壁层不同
func _test_type_aware_walls() -> void:
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(_controlled_bytes())
	_check("受控地形载入 ok", lr["ok"], true)
	_check("rock tile 抬高", TerrainMap.tile_height(Vector2i(5, 5)), 1)
	_check("packed tile 抬高", TerrainMap.tile_height(Vector2i(10, 10)), 1)

	var cm := ChunkManager.new()
	var mesh: ArrayMesh = cm._chunk_mesh(Vector2i(0, 0))
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]

	var wall_layers := {}   # 法线水平的崖壁层集合
	for i in range(verts.size()):
		if absf(norms[i].y) < 0.01:
			wall_layers[int(round(cols[i].r * 255.0))] = true
	_check("崖壁含裸岩侧壁层", wall_layers.has(TerrainTextures.LAYER_ROCK_SNOW), true)
	_check("崖壁含压实雪侧壁层", wall_layers.has(TerrainTextures.LAYER_PACKED_SNOW), true)
	_check("崖壁侧壁层 ≥ 2 种", wall_layers.size() >= 2, true)

	cm.free()
	TerrainMap.reset()

## ④ 万物基底层按场景模态地表：冰雪切片(压实雪为多)→ 压实雪层、全草世界→ 草层。
func _test_base_layer_modal() -> void:
	var cm := ChunkManager.new()
	TerrainMap.reset()
	TerrainMap.load_from_bytes(ICESNOW.build_terrain_bytes())
	cm.rebuild()
	_check("冰雪场景基底层 = 压实雪", cm._base_layer, TerrainTextures.LAYER_PACKED_SNOW)
	TerrainMap.reset()
	TerrainMap.load_from_bytes(_grass_bytes())
	cm.rebuild()
	_check("全草世界基底层 = 草", cm._base_layer, TerrainTextures.LAYER_GRASS)
	cm.free()
	TerrainMap.reset()

## 全草平地 v1 .mltr（HEADER + 3 平面清零 = 全草/高0/深0）。
func _grass_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var buf := PackedByteArray()
	buf.resize(HEADER + 3 * n * n)
	for i in range(4):
		buf[i] = "MLTR".unicode_at(i)
	buf[4] = 1
	buf[5] = n
	buf[6] = n
	buf.encode_float(7, WorldGrid.TILE_SIZE)
	return buf

## 全草平地 v1 .mltr，改：rock_snow(5,5) 抬高 1 级、packed_snow(10,10) 抬高 1 级。
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
	var rock := 5 * n + 5
	var packed := 10 * n + 10
	buf[HEADER + rock] = TerrainMap.T_ROCK_SNOW
	buf[HEADER + count + rock] = 1
	buf[HEADER + packed] = TerrainMap.T_PACKED_SNOW
	buf[HEADER + count + packed] = 1
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)])
		fails += 1
