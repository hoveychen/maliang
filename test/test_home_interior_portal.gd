extends SceneTree
## 室内系统 MVP（home-interior P2）客户端 portal 接线：用真实 build_portal_json 输出喂
## World.parse_server_portals（客户端解析）+ World.portal_hit（_step_portal 每帧判定用的纯函数），
## 断言村里家门口/室内出口两座门都能被踏进触发，且落点处不在半径内（防落地即弹回）。
## 服务端 BFS/防弹回对拍见 server/test/home_interior_portal.test.ts。
## 运行: godot --headless --path . --script res://test/test_home_interior_portal.gd
const EX := preload("res://tools/export_terrain.gd")
const World := preload("res://scripts/world.gd")

func _init() -> void:
	var fails := 0

	# ── village_forest 侧（100 格）：家门口那座门进室内 ──────────────────────
	WorldGrid.configure(100)
	var vf := World.parse_server_portals(EX.build_portal_json("village_forest"))
	fails += _check("VF 解析出 3 座门（oz + 玩家家室内 + 七矮人小屋室内）", vf.size(), 3)
	var home_door := _find(vf, "home_interior")
	fails += _check("VF 有进玩家家室内的门", not home_door.is_empty(), true)
	if not home_door.is_empty():
		fails += _check("家门 tile = (24,26)", home_door["tile"], Vector2i(24, 26))
		fails += _check("家门落点 = (24,22)", home_door["to_tile"], Vector2i(24, 22))
		# 站在家门 tile 上 → 命中该门
		var at_door := WorldGrid.from_tile_center(Vector2i(24, 26))
		fails += _check("踏进家门半径命中室内门", World.portal_hit(vf, at_door)["to_scene"], "home_interior")
		# 站在出室内的落点 (24,31) → 离家门 5 tile > radius 3，不该命中（防弹回）
		var at_land := WorldGrid.from_tile_center(Vector2i(24, 31))
		fails += _check("出屋落点不在家门半径内（防弹回）", World.portal_hit(vf, at_land).is_empty(), true)
	# 七矮人小屋进门（house-interiors P1）：门口 (30,92) → snow_interior，落点 (24,22)
	var snow_door := _find(vf, "snow_interior")
	fails += _check("VF 有进七矮人小屋的门", not snow_door.is_empty(), true)
	if not snow_door.is_empty():
		fails += _check("小屋门 tile = (30,92)", snow_door["tile"], Vector2i(30, 92))
		var at_cottage := WorldGrid.from_tile_center(Vector2i(30, 92))
		fails += _check("踏进小屋门半径命中室内", World.portal_hit(vf, at_cottage)["to_scene"], "snow_interior")
		# 出小屋落点 (30,89) 离进门 3 tile > radius 2.5，不该命中（防弹回）
		var at_snow_land := WorldGrid.from_tile_center(Vector2i(30, 89))
		fails += _check("出小屋落点不在进门半径内（防弹回）", World.portal_hit(vf, at_snow_land).is_empty(), true)

	# ── home_interior 侧（50 格）：房间前开口边缘出口回村 ───────────────────
	WorldGrid.configure(50)
	var hi := World.parse_server_portals(EX.build_portal_json("home_interior"))
	fails += _check("室内解析出 1 座返回门", hi.size(), 1)
	if not hi.is_empty():
		fails += _check("室内门 → 村庄", hi[0]["to_scene"], "village_forest")
		fails += _check("室内门 tile = (24,30) 前开口边缘（房间 [19..30]）", hi[0]["tile"], Vector2i(24, 30))
		fails += _check("室内门落点 = (24,31)", hi[0]["to_tile"], Vector2i(24, 31))
		var at_exit := WorldGrid.from_tile_center(Vector2i(24, 30))
		fails += _check("踏进出口半径命中村庄门", World.portal_hit(hi, at_exit)["to_scene"], "village_forest")
		# 进室内的落点 (24,22) → 离出口 6 tile > radius 2.5，不该命中（防弹回）
		var at_enter := WorldGrid.from_tile_center(Vector2i(24, 22))
		fails += _check("进屋落点不在出口半径内（防弹回）", World.portal_hit(hi, at_enter).is_empty(), true)

	print("test_home_interior_portal: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _find(portals: Array, to_scene: String) -> Dictionary:
	for p in portals:
		if p["to_scene"] == to_scene:
			return p
	return {}

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
