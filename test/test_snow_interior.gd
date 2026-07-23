extends SceneTree
## 七矮人小屋室内（snow_interior）地形导出/家具/传送门回归（house-interiors P1）。
## snow_interior 是首个带 authored 家具的室内（home_interior 是空房、玩家自己摆）。断言：
## - 网格 50、纯平木地板（与 home_interior 同一张地板，走 _paint_home_interior）
## - authored 家具进物品层：7 张单人床 + 1 张餐桌 + 7 个碗，锚点全落房间 [19..30]² 内
## - 返回门在前开口边缘 (24,30) → village_forest 落点 (30,89)（离村里进门 (30,92) > radius 防弹回）
## - 空 POI / 空住户（室内）
## - 确定性：连续两次导出逐字节相同
## 运行: godot --headless --path . --script res://test/test_snow_interior.gd
const EX := preload("res://tools/export_terrain.gd")
const World := preload("res://scripts/world.gd")
const HEADER := 11

func _init() -> void:
	var fails := 0
	var buf := EX.build_terrain_bytes("snow_interior")
	var n := WorldGrid.GRID_TILES

	# ── 网格自描述为 50 ────────────────────────────────────────────────────
	fails += _check("build 后 GRID_TILES = 50", n, 50)
	fails += _check("gridW = 50", buf[5], 50)

	# ── 载入 + 纯平木地板（同 home_interior）───────────────────────────────
	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(buf)
	fails += _check("客户端载入 ok", r["ok"], true)
	var non_floor := 0
	for y in range(n):
		for x in range(n):
			if TerrainMap.tile_type(Vector2i(x, y)) != TerrainMap.T_WOOD_FLOOR:
				non_floor += 1
	fails += _check("全格木地板", non_floor, 0)

	# ── authored 家具：7 床 + 1 桌 + 7 碗，全在房间 [19..30]² 内 ────────────
	var beds := 0
	var tables := 0
	var bowls := 0
	var out_of_room := 0
	for y in range(n):
		for x in range(n):
			var id := TerrainMap.tile_item_id(Vector2i(x, y))
			if id.is_empty():
				continue
			if x < 19 or x > 30 or y < 19 or y > 30:
				out_of_room += 1
			match id:
				"toy_bed_single": beds += 1
				"toy_table": tables += 1
				"dwarf_bowl": bowls += 1
	fails += _check("7 张单人床", beds, 7)
	fails += _check("1 张餐桌", tables, 1)
	fails += _check("7 个碗", bowls, 7)
	fails += _check("所有家具锚点落房间 [19..30]² 内", out_of_room, 0)

	# ── 返回门（前开口边缘 (24,30)）与防弹回 ────────────────────────────────
	WorldGrid.configure(50)
	var portals := World.parse_server_portals(EX.build_portal_json("snow_interior"))
	fails += _check("室内 1 座返回门", portals.size(), 1)
	if not portals.is_empty():
		fails += _check("返回门 → 村庄", portals[0]["to_scene"], "village_forest")
		fails += _check("返回门 tile = (24,30) 前开口边缘", portals[0]["tile"], Vector2i(24, 30))
		fails += _check("返回门落点 = (30,89)", portals[0]["to_tile"], Vector2i(30, 89))
		# 进屋落点 (24,22) 离返回门 8 tile > radius 2.5，不该命中（防弹回）
		var at_enter := WorldGrid.from_tile_center(Vector2i(24, 22))
		fails += _check("进屋落点不在返回门半径内（防弹回）", World.portal_hit(portals, at_enter).is_empty(), true)

	# ── 空 POI / 空住户 ────────────────────────────────────────────────────
	fails += _check("snow_interior 无 POI", EX.build_poi_json("snow_interior").size(), 0)
	fails += _check("snow_interior 无住户", EX.build_homes_json("snow_interior").size(), 0)

	# ── 确定性 ─────────────────────────────────────────────────────────────
	fails += _check("两次导出字节一致（组装纯函数）", buf == EX.build_terrain_bytes("snow_interior"), true)

	TerrainMap.reset()
	print("test_snow_interior: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
