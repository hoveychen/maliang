extends SceneTree
## 翡翠城堡室内（oz_castle_interior，house-interiors P2）导出/家具/传送门回归。
## oz 无户外家具 → 摆一套新 authored 家具（复用 toy_*）。断言：
## - 网格 50、纯平木地板（*_interior 走 _paint_home_interior）
## - authored 家具进物品层：沙发/书架/灯/桌/2椅/2盆栽 = 8 件，锚点全落房间 [19..30]²
## - oz 侧多一座进城堡门 (58,57)→oz_castle_interior；室内返回门 (24,30)→oz (58,60) 防弹回
## - 空 POI / 空住户
## 运行: godot --headless --script res://test/test_oz_castle_interior.gd
const EX := preload("res://tools/export_terrain.gd")
const World := preload("res://scripts/world.gd")

func _init() -> void:
	var fails := 0
	var buf := EX.build_terrain_bytes("oz_castle_interior")
	var n := WorldGrid.GRID_TILES
	fails += _check("GRID_TILES = 50", n, 50)

	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(buf)
	fails += _check("客户端载入 ok", r["ok"], true)
	var non_floor := 0
	for y in range(n):
		for x in range(n):
			if TerrainMap.tile_type(Vector2i(x, y)) != TerrainMap.T_WOOD_FLOOR:
				non_floor += 1
	fails += _check("全格木地板", non_floor, 0)

	# ── authored 家具：5 件（沙发/书架/灯/桌/盆栽），全在房间 8×8 [19..26]² 内 ──
	var rn := World.room_n_for("oz_castle_interior")
	var lo := 19
	var hi := 19 + rn - 1
	var furn := 0
	var out_of_room := 0
	for y in range(n):
		for x in range(n):
			var id := TerrainMap.tile_item_id(Vector2i(x, y))
			if id.is_empty():
				continue
			furn += 1
			if x < lo or x > hi or y < lo or y > hi:
				out_of_room += 1
	fails += _check("城堡室内 5 件家具", furn, 5)
	fails += _check("家具全落房间 8×8 内", out_of_room, 0)

	# ── oz 侧进城堡门 + 室内返回门（防弹回）─────────────────────────────────
	WorldGrid.configure(75)  # oz 预设
	var oz := World.parse_server_portals(EX.build_portal_json("oz"))
	fails += _check("oz 有 2 座门（回村 + 进城堡）", oz.size(), 2)
	var castle_door := {}
	for p in oz:
		if p["to_scene"] == "oz_castle_interior":
			castle_door = p
	fails += _check("oz 有进城堡的门", not castle_door.is_empty(), true)
	if not castle_door.is_empty():
		fails += _check("城堡门 tile = (58,57)", castle_door["tile"], Vector2i(58, 57))
		var at_castle := WorldGrid.from_tile_center(Vector2i(58, 57))
		fails += _check("踏进城堡门半径命中室内", World.portal_hit(oz, at_castle)["to_scene"], "oz_castle_interior")

	WorldGrid.configure(50)
	var inside := World.parse_server_portals(EX.build_portal_json("oz_castle_interior"))
	fails += _check("室内 1 座返回门", inside.size(), 1)
	if not inside.is_empty():
		fails += _check("返回门 → oz", inside[0]["to_scene"], "oz")
		fails += _check("返回门 tile = 前开口边缘中线", inside[0]["tile"], World.room_front_tile("oz_castle_interior"))
		fails += _check("返回门落点 = (58,60)", inside[0]["to_tile"], Vector2i(58, 60))
		var at_enter := WorldGrid.from_tile_center(World.room_back_landing("oz_castle_interior"))
		fails += _check("进屋落点不在返回门半径内（防弹回）", World.portal_hit(inside, at_enter).is_empty(), true)

	fails += _check("oz_castle_interior 无 POI", EX.build_poi_json("oz_castle_interior").size(), 0)
	fails += _check("oz_castle_interior 无住户", EX.build_homes_json("oz_castle_interior").size(), 0)
	fails += _check("两次导出字节一致", buf == EX.build_terrain_bytes("oz_castle_interior"), true)

	TerrainMap.reset()
	print("test_oz_castle_interior: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
