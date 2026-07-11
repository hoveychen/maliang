extends SceneTree
## 地形局部更新（scene-items P5）：apply_patch 增量应用 + rebuild_tiles 精准失效。
## - patch 应用：挖水/放物品（palette 追加）/移除物品，平面与受影响 tile 正确
## - 坏 patch（palette 不衔接/越界/引用非法）整体拒绝，矩阵不半改
## - rebuild_tiles：区块内部 tile 失效 1 块；边界 tile 连带邻块；四角 tile 波及 4 块
## - 占用重派生：patch 放置 blocking 物品后该 tile 被静态占用
## 运行: godot --headless --path . --script res://test/test_terrain_patch.gd

func _init() -> void:
	var fails := 0

	# ── 就位：打包村庄矩阵 ───────────────────────────────────────────────────
	TerrainMap.reset()
	OccupancyMap.clear()
	ItemCatalog.reset()
	ItemCatalog.ensure_builtin()
	var f := FileAccess.open("res://assets/terrain/village.mltr", FileAccess.READ)
	var r: Dictionary = TerrainMap.load_from_bytes(f.get_buffer(f.get_length()))
	fails += _check("打包矩阵载入 ok", r["ok"], true)
	var pal_n := TerrainMap.palette().size()

	# ── patch 应用：挖水 + 放新实体物品（palette 追加）+ 移除已有物品 ─────────
	var clear_tile := _find_empty_grass()
	var tree_tile := _find_item_prefix("tree_puff")
	fails += _check("找到空草地与树", clear_tile.x >= 0 and tree_tile.x >= 0, true)

	var p := TerrainMap.apply_patch({
		"paletteAppend": [{ "index": pal_n + 1, "itemId": "小明的花" }],
		"edits": [
			{ "x": clear_tile.x, "y": clear_tile.y, "t": TerrainMap.T_WATER, "d": 1 },
			{ "x": clear_tile.x + 2, "y": clear_tile.y, "item": [pal_n + 1, 64] },
			{ "x": tree_tile.x, "y": tree_tile.y, "item": null },
		],
	})
	fails += _check("patch 应用 ok", p["ok"], true)
	fails += _check("受影响 3 个 tile", (p["tiles"] as Array).size(), 3)
	fails += _check("挖出水面", TerrainMap.tile_type(clear_tile), TerrainMap.T_WATER)
	fails += _check("水深 1", TerrainMap.tile_depth(clear_tile), 1)
	fails += _check("新实体挂上", TerrainMap.tile_item_id(clear_tile + Vector2i(2, 0)), "小明的花")
	fails += _check("朝向 90°", TerrainMap.tile_item_yaw_deg(clear_tile + Vector2i(2, 0)), 90.0)
	fails += _check("树被移除", TerrainMap.tile_item_id(tree_tile), "")
	fails += _check("palette 扩容", TerrainMap.palette().size(), pal_n + 1)

	# ── 坏 patch 整体拒绝且不半改 ────────────────────────────────────────────
	var before_type := TerrainMap.tile_type(Vector2i(1, 1))
	for bad in [
		{ "why": "palette 不衔接", "patch": { "paletteAppend": [{ "index": 99, "itemId": "x" }], "edits": [{ "x": 1, "y": 1, "t": 1 }] } },
		{ "why": "坐标越界", "patch": { "edits": [{ "x": 1, "y": 1, "t": 1 }, { "x": 99, "y": 0, "t": 1 }] } },
		{ "why": "item 引用越界", "patch": { "edits": [{ "x": 1, "y": 1, "item": [200, 0] }] } },
		{ "why": "edits 为空", "patch": { "edits": [] } },
	]:
		var br: Dictionary = TerrainMap.apply_patch(bad["patch"])
		fails += _check("拒绝：%s" % bad["why"], br["ok"], false)
	fails += _check("拒绝后矩阵未被半改", TerrainMap.tile_type(Vector2i(1, 1)), before_type)

	# ── 占用重派生：新放的 blocking 物品占住 tile ────────────────────────────
	ItemCatalog.apply_static_occupancy()
	var flower_tile := clear_tile + Vector2i(2, 0)
	fails += _check("新物品占位（未知实体保守 blocking）",
		OccupancyMap.is_free_rect(OccupancyMap.tile_to_cell(flower_tile), 2, 2), false)
	fails += _check("被移除的树腾出占位",
		OccupancyMap.is_free_rect(OccupancyMap.tile_to_cell(tree_tile), 2, 2), true)

	# ── rebuild_tiles 精准失效 ───────────────────────────────────────────────
	var cm := ChunkManager.new()
	root.add_child(cm)
	if cm._slots.is_empty():
		cm._ready()
	for i in range(12):
		cm.update(Vector2(75.0, 75.0))
	fails += _check("全部区块铺完", cm.all_skinned(), true)
	fails += _check("9 份地面缓存", cm._chunk_meshes.size(), 9)

	fails += _check("区块内部 tile → 失效 1 块", cm.rebuild_tiles([Vector2i(12, 12)]), 1)
	fails += _check("缓存清掉 1 块", cm._chunk_meshes.size(), 8)
	fails += _check("对应槽位复位", cm._slot_of(Vector2i(0, 0))["skinned"], false)

	for i in range(4):
		cm.update(Vector2(75.0, 75.0)) # 重铺回满
	fails += _check("重铺回满", cm.all_skinned(), true)

	fails += _check("区块边界 tile → 连带邻块（2 块）", cm.rebuild_tiles([Vector2i(24, 12)]), 2)
	for i in range(4):
		cm.update(Vector2(75.0, 75.0))
	fails += _check("区块四角 tile → 波及 4 块", cm.rebuild_tiles([Vector2i(24, 24)]), 4)
	for i in range(8):
		cm.update(Vector2(75.0, 75.0))
	fails += _check("环面角 (0,0) → 也波及 4 块（wrap 邻域）", cm.rebuild_tiles([Vector2i(0, 0)]), 4)

	# 收尾
	cm.queue_free()
	TerrainMap.reset()
	OccupancyMap.clear()
	ItemCatalog.reset()
	print("test_terrain_patch: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## 找一块 3×3 邻域全空的草地（远离水/物品，避免与既有布置纠缠）。
func _find_empty_grass() -> Vector2i:
	var n := WorldGrid.GRID_TILES
	for y in range(2, n - 2):
		for x in range(2, n - 2):
			var ok := true
			for dz in range(-1, 3):
				for dx in range(-1, 4):
					var t := Vector2i(x + dx, y + dz)
					if TerrainMap.tile_type(t) != TerrainMap.T_GRASS or not TerrainMap.tile_item_id(t).is_empty() \
							or TerrainMap.tile_height(t) != 0:
						ok = false
			if ok:
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _find_item_prefix(prefix: String) -> Vector2i:
	var n := WorldGrid.GRID_TILES
	for y in range(n):
		for x in range(n):
			if TerrainMap.tile_item_id(Vector2i(x, y)).begins_with(prefix):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
