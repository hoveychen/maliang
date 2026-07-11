extends SceneTree
## 回归测试（phone-home-app P5）：「穿传送门进森林后卡在落点动不了」的复现+守门。
## 森林落点 = 村庄→森林 portal 的 toTile [20,18]（= 森林返回 portal 同格）。从该 tile 起，
## 按游戏可行走规则（树/灌/石挡路、草丛/空地通、can_step 台阶规则）做 BFS 数可达 tile。
## 曾经森林floor 66% 挡路密度 → 密林把落点空地围成孤岛，从落点只能到 123/2058 tile，玩家
## 落地即卡死。降到 ~37% 挡路（低于连通阈值）后从落点可达 3000+ tile，能穿行整片森林。
## 阈值 REACH_MIN=2000 卡在两者之间：旧密度必挂、新密度必过。
## 运行: godot --headless --path . --script res://test/test_forest_reach.gd

const FOREST := preload("res://tools/export_forest.gd")
const COMPOSE := preload("res://tools/scene_compose.gd")
const REACH_MIN := 2000 # 落点可达 tile 下限（旧 66% 密度只有 123，必须远超）

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES
	TerrainMap.reset()
	var fr: Dictionary = TerrainMap.load_from_bytes(FOREST.build_terrain_bytes())
	fails += _check("森林地形载入 ok", fr["ok"], true)

	var arrive := Vector2i(20, 18) # 村庄→森林落点 / 森林返回 portal 同格
	fails += _check("落点 [20,18] 可行走", _walkable(arrive), true)

	# 单格 BFS：从落点起，只走「可行走且 can_step」的邻格
	var seen := {}
	var q: Array[Vector2i] = [arrive]
	seen[arrive] = true
	var far_reached := false
	while not q.is_empty():
		var cur: Vector2i = q.pop_front()
		if WorldGrid.shortest_delta(WorldGrid.from_tile_center(cur), WorldGrid.from_tile_center(arrive)).length() > 30.0:
			far_reached = true
		for d in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
			var nb := Vector2i(posmod(cur.x + d.x, n), posmod(cur.y + d.y, n))
			if seen.has(nb):
				continue
			if _walkable(nb) and TerrainMap.can_step(cur, nb):
				seen[nb] = true
				q.append(nb)

	var reach := seen.size()
	print("  落点单格可达 tile 数=%d（阈值 >%d），能走到 >30 单位远=%s" % [reach, REACH_MIN, far_reached])
	fails += _check("落点没被密林围死（可达 tile 远超孤岛规模）", reach > REACH_MIN, true)
	fails += _check("落点能走到 30 单位外（不是被困在小空地）", far_reached, true)
	TerrainMap.reset()
	print("test_forest_reach: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1

## 可行走：非水，且该 tile 无 blocking deco（树/灌/石）。草丛(tuft)/空(none) 视为可走。
func _walkable(t: Vector2i) -> bool:
	if TerrainMap.tile_type(t) == TerrainMap.T_WATER:
		return false
	var k := COMPOSE._deco_kind("forest", t)
	return k == COMPOSE.DECO_NONE or k == COMPOSE.DECO_TUFT

func _free_neighbors(t: Vector2i) -> int:
	var n := WorldGrid.GRID_TILES
	var c := 0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var nb := Vector2i(posmod(t.x + dx, n), posmod(t.y + dz, n))
			if _walkable(nb) and TerrainMap.can_step(t, nb):
				c += 1
	return c
