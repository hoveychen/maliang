extends SceneTree
## 海底垂直切片验收（themed-terrain P2）：
## ① export_seafloor.gd 产出的种子场景含全部 6 种海底地表 + 水体，且可自产自销载入；
## ② TerrainTextures.top_layer/side_layer 对新类型返回正确层；
## ③ 受控地形——抬高的礁岩 tile 走礁岩侧壁层、抬高的粗沙 tile 走粗沙侧壁层
##    （不同类型抬高块出不同崖壁，延续 P1「按被抬高 tile 类型选侧壁」的修复到海底类型）。
## 运行: godot --headless --script res://test/test_terrain_seafloor.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

const SEAFLOOR := preload("res://tools/export_seafloor.gd")
const HEADER := 11

var fails := 0

func _init() -> void:
	_test_seed_scene_coverage()
	_test_layer_mappings()
	_test_type_aware_walls()
	print("test_terrain_seafloor: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## ① 种子场景：导出字节可载入 + 6 种海底地表 + 水体全部出现
func _test_seed_scene_coverage() -> void:
	var bytes := SEAFLOOR.build_terrain_bytes()
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(bytes)
	_check("海底种子场景载入 ok", lr["ok"], true)

	var n := WorldGrid.GRID_TILES
	var seen := {}
	for z in range(n):
		for x in range(n):
			seen[TerrainMap.tile_type(Vector2i(x, z))] = true
	for t in [TerrainMap.T_SAND, TerrainMap.T_COARSE_SAND, TerrainMap.T_CORAL_SAND,
			TerrainMap.T_REEF, TerrainMap.T_SEAGRASS, TerrainMap.T_DEEP_BED, TerrainMap.T_WATER]:
		_check("种子场景出现 tile 类型 %d" % t, seen.has(t), true)
	# 全部类型均在合法白名单内（校验层不会拒收）
	for t in seen.keys():
		_check("tile 类型 %d 在 VALID_TYPES" % t, t in TerrainMap.VALID_TYPES, true)
	TerrainMap.reset()

## ② 层映射：新类型 → 正确顶面/侧壁层
func _test_layer_mappings() -> void:
	var TT := TerrainTextures
	_check("top T_COARSE_SAND", TT.top_layer(TerrainMap.T_COARSE_SAND), TT.LAYER_COARSE_SAND)
	_check("top T_CORAL_SAND", TT.top_layer(TerrainMap.T_CORAL_SAND), TT.LAYER_CORAL_SAND)
	_check("top T_REEF", TT.top_layer(TerrainMap.T_REEF), TT.LAYER_CORAL)
	_check("top T_SEAGRASS", TT.top_layer(TerrainMap.T_SEAGRASS), TT.LAYER_SEAGRASS)
	_check("top T_DEEP_BED", TT.top_layer(TerrainMap.T_DEEP_BED), TT.LAYER_DEEP_BED)
	# 侧壁：可抬高的礁岩/粗沙有专属侧壁（= 各自顶面层），非兜底岩壁
	_check("side T_REEF = 礁岩层", TT.side_layer(TerrainMap.T_REEF), TT.LAYER_CORAL)
	_check("side T_COARSE_SAND = 粗沙层", TT.side_layer(TerrainMap.T_COARSE_SAND), TT.LAYER_COARSE_SAND)
	_check("side T_REEF ≠ 兜底岩壁", TT.side_layer(TerrainMap.T_REEF) != TT.LAYER_CLIFF_WALL, true)
	# 层贴图路径表长度与 LAYER_COUNT 一致（顺序敏感，缺一层会错位采样）
	_check("LAYER_TEX_PATHS 数 = LAYER_COUNT", TT.LAYER_TEX_PATHS.size(), TT.LAYER_COUNT)

## ③ 受控地形：礁岩(5,5) 抬高、粗沙(10,10) 抬高，各自崖壁层不同
func _test_type_aware_walls() -> void:
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(_controlled_bytes())
	_check("受控地形载入 ok", lr["ok"], true)
	_check("reef tile 抬高", TerrainMap.tile_height(Vector2i(5, 5)), 1)
	_check("coarse tile 抬高", TerrainMap.tile_height(Vector2i(10, 10)), 1)

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
	_check("崖壁含礁岩侧壁层", wall_layers.has(TerrainTextures.LAYER_CORAL), true)
	_check("崖壁含粗沙侧壁层", wall_layers.has(TerrainTextures.LAYER_COARSE_SAND), true)
	# 两块不同类型抬高 → 崖壁层至少 2 种（不再一堵通用墙）
	_check("崖壁侧壁层 ≥ 2 种", wall_layers.size() >= 2, true)

	cm.free()
	TerrainMap.reset()

## 全草平地 v1 .mltr，改：reef(5,5) 抬高 1 级、coarse(10,10) 抬高 1 级。
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
	var reef := 5 * n + 5
	var coarse := 10 * n + 10
	buf[HEADER + reef] = TerrainMap.T_REEF
	buf[HEADER + count + reef] = 1
	buf[HEADER + coarse] = TerrainMap.T_COARSE_SAND
	buf[HEADER + count + coarse] = 1
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)])
		fails += 1
