extends SceneTree
## 4 村民农舍 + 外婆家室内（house-interiors P3 量产）导出/家具/传送门回归。
## 5 栋房子共用一套 cozy 家具（VILLAGER_HOME_FURNITURE，6 件），各自一座进门/返回门。断言：
## - village_forest 现有 8 座门（oz + 玩家家 + 七矮人 + 4 农舍 + 外婆家）
## - 每个村民室内：网格 50、纯平木地板、6 件家具全落房间 [19..30]²
## - 每个村民室内的返回门 (24,30)→village_forest，落点 = 该房子门外一格（与进门 entrance 对上、防弹回）
## 运行: godot --headless --script res://test/test_villager_interiors.gd
const EX := preload("res://tools/export_terrain.gd")
const COMPOSE := preload("res://tools/scene_compose.gd")
const World := preload("res://scripts/world.gd")

func _init() -> void:
	var fails := 0

	# ── village_forest 现有 8 座门（3 老门 + 5 房子）───────────────────────────
	WorldGrid.configure(100)
	var vf := World.parse_server_portals(EX.build_portal_json("village_forest"))
	fails += _check("village_forest 8 座门", vf.size(), 8)
	# 每栋村民房子在 vf 里有一座进门 portal，toTile = 室内后排 (24,22)
	for interior_id in EX.VILLAGER_PORTALS:
		var found := {}
		for p in vf:
			if p["to_scene"] == interior_id:
				found = p
		fails += _check("vf 有进 %s 的门" % interior_id, not found.is_empty(), true)
		if not found.is_empty():
			var ent: Array = EX.VILLAGER_PORTALS[interior_id]["entrance"]
			fails += _check("%s 进门 tile 对" % interior_id, found["tile"], Vector2i(ent[0], ent[1]))
			fails += _check("%s 进门落室内 (24,22)" % interior_id, found["to_tile"], Vector2i(24, 22))

	# ── 每个村民室内：导出/家具/返回门 ───────────────────────────────────────
	for interior_id in COMPOSE.VILLAGER_INTERIOR_IDS:
		var buf := EX.build_terrain_bytes(interior_id)
		var n := WorldGrid.GRID_TILES
		fails += _check("%s 网格 50" % interior_id, n, 50)
		TerrainMap.reset()
		TerrainMap.load_from_bytes(buf)
		var non_floor := 0
		var furn := 0
		var out_of_room := 0
		for y in range(n):
			for x in range(n):
				var t := Vector2i(x, y)
				if TerrainMap.tile_type(t) != TerrainMap.T_WOOD_FLOOR:
					non_floor += 1
				if not TerrainMap.tile_item_id(t).is_empty():
					furn += 1
					if x < 19 or x > 30 or y < 19 or y > 30:
						out_of_room += 1
		fails += _check("%s 全木地板" % interior_id, non_floor, 0)
		fails += _check("%s 6 件家具" % interior_id, furn, 6)
		fails += _check("%s 家具全落房间内" % interior_id, out_of_room, 0)

		# 返回门 (24,30) → village_forest，落点 = 该房子 return
		WorldGrid.configure(50)
		var inside := World.parse_server_portals(EX.build_portal_json(interior_id))
		fails += _check("%s 1 座返回门" % interior_id, inside.size(), 1)
		if not inside.is_empty():
			var ret: Array = EX.VILLAGER_PORTALS[interior_id]["return"]
			fails += _check("%s 返回门→村庄" % interior_id, inside[0]["to_scene"], "village_forest")
			fails += _check("%s 返回门 tile (24,30)" % interior_id, inside[0]["tile"], Vector2i(24, 30))
			fails += _check("%s 返回落点对" % interior_id, inside[0]["to_tile"], Vector2i(ret[0], ret[1]))
			# 进屋落点 (24,22) 离返回门 (24,30) = 8 > radius（防弹回）
			var at_enter := WorldGrid.from_tile_center(Vector2i(24, 22))
			fails += _check("%s 进屋落点不在返回门半径内" % interior_id, World.portal_hit(inside, at_enter).is_empty(), true)
		fails += _check("%s 无 POI" % interior_id, EX.build_poi_json(interior_id).size(), 0)

	TerrainMap.reset()
	print("test_villager_interiors: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
