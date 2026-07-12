extends SceneTree
## 真实水面+深度回归（headless，mesh/材质内省，不读像素）：
## (1) 地面材质换 terrain_ground shader（控制图+水彩贴图+世界 UV2），mesh 带 UV2；
## (2) 湖床下沉：池塘区块地面最低顶点 = -MAX_DEPTH 级（深水核心 -4m），
##     且高度 0 的岸边区块出现竖直岸壁 quad（法线水平——之前平地区块不可能有墙）；
## (3) 独立半透明水面层：水面 mesh 存在、水位 = 岸沿 - WATER_DIP、
##     顶点色 R 深度归一覆盖 [浅..1]、G 岸线掩码有 1（泡沫带有料可用）；
##     无水区块水面 mesh 为 null（不发空面）；
## (4) 水面材质是 water_surface shader 且共享给所有 slot。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_visual_water.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame != 10:
		return
	var cm: ChunkManager = scene.get_node_or_null("ChunkManager")
	_check("场景里有 ChunkManager", cm != null, true)
	if cm == null:
		quit(fails)
		return

	# 地面材质与 UV2
	var gm: ShaderMaterial = cm._ground_mat
	_check("地面材质是 terrain_ground shader",
		gm != null and gm.shader.resource_path == "res://shaders/terrain_ground.gdshader", true)
	if gm != null:
		_check("控制图已挂载", gm.get_shader_parameter("control_tex") != null, true)
		_check("顶面贴图数组已挂载", gm.get_shader_parameter("top_array") != null, true)

	# 池塘区块 (0,0)：湖床下沉 + 岸壁
	var pond := Vector2i(0, 0)
	var mesh: ArrayMesh = cm._chunk_mesh(pond)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	_check("地面 mesh 带 UV2（世界平铺坐标）", uv2s.size() == verts.size() and not uv2s.is_empty(), true)
	var min_y := 1e9
	for v in verts:
		min_y = minf(min_y, v.y)
	_check("湖床下沉到深水核心 (-%.0fm)" % (TerrainMap.MAX_DEPTH * TerrainMap.STEP_HEIGHT),
		is_equal_approx(min_y, -float(TerrainMap.MAX_DEPTH) * TerrainMap.STEP_HEIGHT), true)
	var wall_quads := 0
	for nv in norms:
		if absf(nv.y) < 0.01:
			wall_quads += 1
	_check("高度 0 的岸边出现水下岸壁（平地区块历史上无墙）", wall_quads > 0, true)

	# 水面层：池塘区块有、旱区块无
	var wmesh: ArrayMesh = cm._water_mesh(pond)
	_check("池塘区块有水面 mesh", wmesh != null, true)
	_check("旱区块无水面 mesh（东北 (2,0) 无水）", cm._water_mesh(Vector2i(2, 0)) == null, true)
	if wmesh != null:
		var wa := wmesh.surface_get_arrays(0)
		var wv: PackedVector3Array = wa[Mesh.ARRAY_VERTEX]
		var wc: PackedColorArray = wa[Mesh.ARRAY_COLOR]
		var wuv: PackedVector2Array = wa[Mesh.ARRAY_TEX_UV]
		var wuv2: PackedVector2Array = wa[Mesh.ARRAY_TEX_UV2]
		_check("水面 mesh 带 UV(泡沫掩码)/UV2/顶点色",
			wc.size() == wv.size() and wuv.size() == wv.size() and wuv2.size() == wv.size(), true)
		var level_ok := true
		for v in wv:
			if not is_equal_approx(v.y, -ChunkManager.WATER_DIP):
				level_ok = false
		_check("水位 = 岸沿 - WATER_DIP（高度 0 水域）", level_ok, true)
		var max_depth01 := 0.0
		var min_depth01 := 1e9
		for c in wc:
			max_depth01 = maxf(max_depth01, c.r)
			min_depth01 = minf(min_depth01, c.r)
		_check("深水核心顶点色 R=1（深度渐变到满）", is_equal_approx(max_depth01, 1.0), true)
		_check("浅水边缘顶点色 R<1（有深浅对比）", min_depth01 < 0.9, true)
		# 泡沫掩码在 atlas：贴岸角变体 cell 有 G 带、全水 cell 无（窄溪不整条变白的关键）
		var img := TerrainAtlas.build_image()
		var edge_uv := TerrainAtlas.uv_rect(TerrainMap.T_WATER, Autotile.C_NW, Autotile.V_EDGE_H, 0)
		var edge_g := img.get_pixel(int(edge_uv.position.x * TerrainAtlas.W + 16.0),
			int(edge_uv.position.y * TerrainAtlas.H + TerrainAtlas.MARGIN)).g
		var full_uv := TerrainAtlas.uv_rect(TerrainMap.T_WATER, Autotile.C_NW, Autotile.V_FULL, 0)
		var full_g := img.get_pixel(int(full_uv.position.x * TerrainAtlas.W + 16.0),
			int(full_uv.position.y * TerrainAtlas.H + 16.0)).g
		_check("贴岸 cell 有泡沫带 (G>0.9)", edge_g > 0.9, true)
		_check("全水 cell 无泡沫 (G=0)", full_g < 0.05, true)

	# 水面材质共享且是 water_surface shader
	var wmat: ShaderMaterial = cm._water_mat
	_check("水面材质是 water_surface shader",
		wmat != null and wmat.shader.resource_path == "res://shaders/water_surface.gdshader", true)

	if fails == 0:
		print("visual_water PASS")
	else:
		printerr("visual_water FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
