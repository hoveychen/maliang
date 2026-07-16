extends SceneTree
## per-tile 贴图层索引验收（themed-terrain P1）：地面 mesh 顶点 COLOR.r*255 = 该 quad 的
## 贴图层索引，顶面按 tile 类型取、崖壁按被抬高 tile 类型取对应侧壁层。不读像素、不建材质，
## 直接内省 _chunk_mesh 产出的 ArrayMesh。构造受控地形：草地里立一块抬高的沙 tile + 一块平瓷砖 tile。
## 运行: godot --headless --script res://test/test_terrain_layers.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

const HEADER := 11

var fails := 0

func _init() -> void:
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(_terrain_bytes())
	_check("受控地形载入 ok", lr["ok"], true)

	# 自证受控地形：sand 抬高、tile 平地、四邻是草
	_check("sand tile 是 T_SAND", TerrainMap.tile_type(Vector2i(5, 5)), TerrainMap.T_SAND)
	_check("sand tile 抬高到 1 级", TerrainMap.tile_height(Vector2i(5, 5)), 1)
	_check("tile tile 是 T_TILE", TerrainMap.tile_type(Vector2i(10, 10)), TerrainMap.T_TILE)
	_check("sand 邻居是草", TerrainMap.tile_type(Vector2i(4, 5)), TerrainMap.T_GRASS)

	var cm := ChunkManager.new()  # 裸实例：_chunk_mesh 不依赖入树 / 材质
	var mesh: ArrayMesh = cm._chunk_mesh(Vector2i(0, 0))
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	_check("地面 mesh 带 COLOR（层索引通道）", cols.size() == verts.size() and not cols.is_empty(), true)

	# 顶面（法线朝上）与崖壁（法线水平）各自出现的层索引集合
	var top_at_raised := {}   # y≈2m（抬高的 sand 顶面）
	var top_flat := {}        # y≈0（草地 + 平瓷砖顶面）
	var wall_layers := {}     # 法线水平的崖壁
	var raised_y := float(TerrainMap.STEP_HEIGHT)  # 1 级 = 2m
	for i in range(verts.size()):
		var layer := int(round(cols[i].r * 255.0))
		if absf(norms[i].y) < 0.01:
			wall_layers[layer] = true
		elif absf(verts[i].y - raised_y) < 0.01:
			top_at_raised[layer] = true
		elif absf(verts[i].y) < 0.01:
			top_flat[layer] = true

	# 顶面：抬高 sand 顶面全是 SAND 层；平地顶面含草(0) 与瓷砖(7)
	_check("抬高 sand 顶面层 = {SAND}", _only(top_at_raised, TerrainTextures.LAYER_SAND), true)
	_check("平地顶面含草层", top_flat.has(TerrainTextures.LAYER_GRASS), true)
	_check("平地顶面含瓷砖层", top_flat.has(TerrainTextures.LAYER_TILE), true)

	# 崖壁：只有 sand tile 被抬高，故所有崖壁侧壁层 = SAND（修 CLIFF_WALL 写死的偷懒）
	_check("有崖壁 quad", not wall_layers.is_empty(), true)
	_check("崖壁侧壁层 = {SAND}（按被抬高 tile 类型）", _only(wall_layers, TerrainTextures.LAYER_SAND), true)

	cm.free()
	TerrainMap.reset()
	print("test_terrain_layers: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## 集合恰好 = {v}
func _only(set: Dictionary, v: int) -> bool:
	return set.size() == 1 and set.has(v)

## 全草平地 v1 .mltr，改：sand(5,5) 抬高 1 级、tile(10,10) 平地。
func _terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var buf := PackedByteArray()
	buf.resize(HEADER + 3 * count)  # resize 清零 = 全草(0)/高度0/深度0
	for i in range(4):
		buf[i] = "MLTR".unicode_at(i)
	buf[4] = 1        # version
	buf[5] = n
	buf[6] = n
	buf.encode_float(7, WorldGrid.TILE_SIZE)
	var sand := 5 * n + 5    # (x=5,z=5) → z*n+x
	var tile := 10 * n + 10
	buf[HEADER + sand] = TerrainMap.T_SAND
	buf[HEADER + count + sand] = 1   # sand 高度 1 级 → 立面
	buf[HEADER + tile] = TerrainMap.T_TILE
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)])
		fails += 1
