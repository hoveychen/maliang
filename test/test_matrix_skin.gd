extends SceneTree
## 矩阵驱动的世界重构（scene-items P4）：「一份地形矩阵 = 完整重构整个世界」的验收。
## 打包 village.mltr → TerrainMap → ItemCatalog 派生占用 + chunk_manager 铺设：
## - 派生占用：水井/民居 footprint 全阻挡、草丛不占位、树占自身 tile
## - 渲染重构：合批实例总数 == 矩阵散布物总数；建筑节点数 == 矩阵建筑数；
##   SDF 物件节点数 == 矩阵 SDF 物件数（渲染层没吞没漏）
## 运行: godot --headless --path . --script res://test/test_matrix_skin.gd

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES

	# ── 就位：打包矩阵 + 实体目录 + 派生占用（world._ready 同款顺序）──────────
	TerrainMap.reset()
	OccupancyMap.clear()
	ItemCatalog.reset()
	ItemCatalog.ensure_builtin()
	var f := FileAccess.open("res://assets/terrain/village.mltr", FileAccess.READ)
	fails += _check("打包矩阵存在", f != null, true)
	var r: Dictionary = TerrainMap.load_from_bytes(f.get_buffer(f.get_length()))
	fails += _check("打包矩阵载入 ok", r["ok"], true)
	ItemCatalog.apply_static_occupancy()

	# ── 派生占用 ───────────────────────────────────────────────────────────
	var well := Vector2i(37, 37)
	fails += _check("矩阵里水井在广场", TerrainMap.tile_item_id(well), "well")
	fails += _check("水井锚点被占", OccupancyMap.is_free_rect(OccupancyMap.tile_to_cell(well), 2, 2), false)
	fails += _check("水井 footprint 角被占", OccupancyMap.is_free_rect(OccupancyMap.tile_to_cell(well - Vector2i(1, 1)), 2, 2), false)
	fails += _check("footprint 外不受井影响+广场留空", OccupancyMap.is_free_rect(OccupancyMap.tile_to_cell(well + Vector2i(2, 2)), 2, 2), true)

	# 统计矩阵物品分类数（合批散布 / 建筑节点 / SDF 物件），顺便验证草丛不占位、树占位
	var batch_n := 0
	var node_n := 0
	var sdf_n := 0
	var tuft_checked := false
	var tree_checked := false
	for y in range(n):
		for x in range(n):
			var t := Vector2i(x, y)
			var id := TerrainMap.tile_item_id(t)
			if id.is_empty():
				continue
			var rref := String(ItemCatalog.get_def(id).get("renderRef", ""))
			var key := rref.get_slice(":", 1)
			if ChunkManager.BAKED_MESHES.has(key) or ChunkManager.KAYKIT_SCATTER.has(key):
				batch_n += 1
			elif ChunkManager.KAYKIT_NODES.has(key):
				node_n += 1
			elif rref.begins_with("sdf_res:") or rref == "sdf_inline":
				sdf_n += 1
			if not tuft_checked and id.begins_with("tuft_"):
				tuft_checked = true
				fails += _check("草丛不占位", OccupancyMap.is_free_rect(OccupancyMap.tile_to_cell(t), 2, 2), true)
			if not tree_checked and id.begins_with("tree_puff"):
				tree_checked = true
				fails += _check("树占自身 tile", OccupancyMap.is_free_rect(OccupancyMap.tile_to_cell(t), 2, 2), false)
	fails += _check("矩阵有散布物（>500）", batch_n > 500, true)
	fails += _check("矩阵建筑 10 座（8 民居+井+风车）", node_n, 10)
	fails += _check("矩阵 SDF 物件 7 个", sdf_n, 7)

	# ── 渲染重构：铺满 3×3 区块，逐层清点 ─────────────────────────────────────
	var cm := ChunkManager.new()
	root.add_child(cm)
	if cm._slots.is_empty():
		cm._ready() # SceneTree._init 阶段 add_child 不触发 _ready，手动建槽
	for i in range(12): # 每次铺一块，12 次必铺完 9 块
		cm.update(Vector2(75.0, 75.0))
	fails += _check("全部区块铺完", cm.all_skinned(), true)

	var mmi_instances := 0
	var kaykit_nodes := 0
	var sdf_nodes := 0
	for slot in cm._slots:
		var deco: Node3D = slot["deco"]
		for c in deco.get_children():
			if c is MultiMeshInstance3D:
				if String(c.name) != "ScatterShadows":
					mmi_instances += (c as MultiMeshInstance3D).multimesh.instance_count
			elif c is SdfProp:
				sdf_nodes += 1
			else:
				kaykit_nodes += 1
	fails += _check("合批实例总数 == 矩阵散布物数", mmi_instances, batch_n)
	fails += _check("建筑节点数 == 矩阵建筑数", kaykit_nodes, node_n)
	fails += _check("SDF 物件节点数 == 矩阵 SDF 数", sdf_nodes, sdf_n)

	# 收尾：不污染同进程后续测试
	cm.queue_free()
	TerrainMap.reset()
	OccupancyMap.clear()
	ItemCatalog.reset()
	print("test_matrix_skin: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
