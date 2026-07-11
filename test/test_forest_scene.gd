extends SceneTree
## 第二张地图森林（scene-portal P5）：程序化 .mltr + 场景感知 deco 的验收。
##   1. export_forest 生成的 .mltr 合法、可载入、与村庄地形不同（changed=true）；含小河（水）+
##      高地空地（height>0）。
##   2. chunk_manager._deco_kind 认场景：同一张森林地形上，scene_id=forest 铺满树（树数量远多于
##      village 规则）——证明 deco 场景感知真的生效。
## 运行: godot --headless --path . --script res://test/test_forest_scene.gd

const FOREST := preload("res://tools/export_forest.gd")
const VILLAGE := preload("res://tools/export_terrain.gd")
const HEADER := 11

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES

	# ── 森林 .mltr 合法、与村庄不同 ───────────────────────────────────────
	var forest := FOREST.build_terrain_bytes()
	fails += _check("森林字节长度正确（v2 九平面+palette）", forest.size() >= HEADER + 9 * n * n + 1, true)

	# 先把 TerrainMap 落成村庄地形，再载森林 → 必然 changed
	TerrainMap.reset()
	var vr: Dictionary = TerrainMap.load_from_bytes(VILLAGE.build_terrain_bytes())
	fails += _check("村庄地形载入 ok", vr["ok"], true)
	var fr: Dictionary = TerrainMap.load_from_bytes(forest)
	fails += _check("森林地形载入 ok", fr["ok"], true)
	fails += _check("森林与村庄不同 → changed=true", fr["changed"], true)

	# ── 森林地形特征：有小河（水）+ 有高地空地（height>0）──────────────────
	var water_tiles := 0
	var knoll_tiles := 0
	for z in range(n):
		for x in range(n):
			var t := Vector2i(x, z)
			if TerrainMap.tile_type(t) == TerrainMap.T_WATER:
				water_tiles += 1
			if TerrainMap.tile_height(t) > 0:
				knoll_tiles += 1
	fails += _check("森林有小河（水面 tile > 60）", water_tiles > 60, true)
	fails += _check("森林有高地空地（height>0 tile > 30）", knoll_tiles > 30, true)
	# 水面一律高度 0（河没被 knoll 抬起来）
	var raised_water := false
	for z in range(n):
		for x in range(n):
			var t := Vector2i(x, z)
			if TerrainMap.tile_type(t) == TerrainMap.T_WATER and TerrainMap.tile_height(t) != 0:
				raised_water = true
	fails += _check("水面高度恒 0（河不被高地抬起）", raised_water, false)

	# ── deco 场景感知：森林地形上 forest 规则铺满树，远多于 village 规则 ───────
	var cm := ChunkManager.new() # 裸实例，_deco_kind 只读 scene_id + TerrainMap
	cm.scene_id = "forest"
	var forest_trees := _count_trees(cm, n)
	cm.scene_id = "village"
	var village_trees := _count_trees(cm, n)
	fails += _check("森林规则铺满树（tree > 800）", forest_trees > 800, true)
	fails += _check("森林树数远多于村庄规则（>3×）", forest_trees > village_trees * 3, true)
	cm.free()

	TerrainMap.reset() # 收尾：恢复本地生成
	print("test_forest_scene: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _count_trees(cm: ChunkManager, n: int) -> int:
	var c := 0
	for z in range(n):
		for x in range(n):
			if cm._deco_kind(Vector2i(x, z)) == ChunkManager.DECO_TREE:
				c += 1
	return c

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
