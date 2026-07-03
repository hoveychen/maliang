extends SceneTree
## Pathfinder（0.5 格 A*）的独立测试。
## 运行: godot --headless --path . --script res://test/test_pathfinder.gd

func _init() -> void:
	var fails := 0

	# 平地直线：路径存在、终点落在目标格、全程 Mover 可执行
	OccupancyMap.clear()
	var a := TerrainMap.tile_center(Vector2i(2, 68))
	var b := TerrainMap.tile_center(Vector2i(10, 68))
	var p := Pathfinder.find_path(a, b, 2, "", false)
	fails += _check("flat found", p.size() > 0, true)
	fails += _check("flat reaches", _near(p[p.size() - 1], b, 1.0), true)
	fails += _check("flat mover-executable", _executable(a, p), true)

	# 拉直版（string-pulling）：平地无遮挡 → 单段直线；终点一致
	var ps := Pathfinder.find_path(a, b)
	fails += _check("smooth flat single segment", ps.size(), 1)
	fails += _check("smooth same end", ps[ps.size() - 1] == p[p.size() - 1], true)
	fails += _check("smooth fine-walkable", _fine_walkable(a, ps), true)

	# 绕池塘：南岸→北岸，无 waypoint 踩水，全程可执行
	var south := TerrainMap.tile_center(Vector2i(24, 31))
	var north := TerrainMap.tile_center(Vector2i(24, 17))
	var pond := Pathfinder.find_path(south, north, 2, "", false)
	fails += _check("pond found", pond.size() > 0, true)
	fails += _check("pond no water", _no_water(pond), true)
	fails += _check("pond mover-executable", _executable(south, pond), true)
	# 拉直后：路长不增、waypoint 更少、0.13m 细步（运行时步长）照样走得通
	var pond_s := Pathfinder.find_path(south, north)
	fails += _check("pond smooth shorter", _path_len(south, pond_s) <= _path_len(south, pond) + 0.01, true)
	fails += _check("pond smooth fewer wp", pond_s.size() < pond.size(), true)
	fails += _check("pond smooth fine-walkable", _fine_walkable(south, pond_s), true)

	# 绕物件：竖墙 x=10, z=60..66 挡直线，绕行且可执行；全封死 → 空
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(10, 60)), 2, 14)
	var w_from := TerrainMap.tile_center(Vector2i(8, 63))
	var w_to := TerrainMap.tile_center(Vector2i(12, 63))
	var wall := Pathfinder.find_path(w_from, w_to, 2, "", false)
	fails += _check("wall found", wall.size() > 0, true)
	fails += _check("wall mover-executable", _executable(w_from, wall), true)
	fails += _check("wall smooth fine-walkable", _fine_walkable(w_from, Pathfinder.find_path(w_from, w_to)), true)
	# 把角色围死在 4 面墙里（2×2 tile 空腔，四周全占用）
	OccupancyMap.clear()
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(49, 60)), 8, 2)  # 北墙
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(49, 63)), 8, 2)  # 南墙
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(49, 61)), 2, 4)  # 西墙
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(52, 61)), 2, 4)  # 东墙
	var boxed := Pathfinder.find_path(TerrainMap.tile_center(Vector2i(50, 61)), TerrainMap.tile_center(Vector2i(60, 61)), 2, "", false)
	fails += _check("boxed no path", boxed.size() == 0, true)
	OccupancyMap.clear()

	# 环面 wrap：x=1 → x=73（跨接缝 6m << 全图 144m），总路长必须走短边
	var t_from := TerrainMap.tile_center(Vector2i(1, 68))
	var t_to := TerrainMap.tile_center(Vector2i(73, 68))
	var torus := Pathfinder.find_path(t_from, t_to, 2, "", false)
	fails += _check("torus found", torus.size() > 0, true)
	fails += _check("torus short side", _path_len(t_from, torus) < 20.0, true)
	fails += _check("torus mover-executable", _executable(t_from, torus), true)

	# 防穿角：对角步在任一正交邻居被挡时不可行
	OccupancyMap.clear()
	OccupancyMap.occupy_rect(Vector2i(90, 90), 1, 1)  # 挡住 (45,45) 半格
	fails += _check("corner cut blocked",
		Pathfinder.step_ok(Vector2i(90, 91), Vector2i(91, 90), 2), false)
	OccupancyMap.clear()

	# 目标格被占（如送信目标角色所在）→ 落到最近可通行格
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(20, 68)), 2, 2)
	var d_from := TerrainMap.tile_center(Vector2i(16, 68))
	var d_to := TerrainMap.tile_center(Vector2i(20, 68))
	var deliver := Pathfinder.find_path(d_from, d_to, 2, "", false)
	fails += _check("blocked goal found", deliver.size() > 0, true)
	fails += _check("blocked goal near", _near(deliver[deliver.size() - 1], d_to, 3.0), true)
	fails += _check("blocked goal executable", _executable(d_from, deliver), true)
	OccupancyMap.clear()

	# 角色层：绕开挡路的他人（排除自己）；送信目标是角色 → 落到其旁边
	OccupancyMap.clear()
	var c_from := TerrainMap.tile_center(Vector2i(16, 68))
	var c_to := TerrainMap.tile_center(Vector2i(20, 68))
	OccupancyMap.char_register("walker", c_from, 2)
	OccupancyMap.char_register("blocker", TerrainMap.tile_center(Vector2i(18, 68)), 2)
	OccupancyMap.char_register("target", c_to, 2)
	var around := Pathfinder.find_path(c_from, c_to, 2, "walker", false)
	fails += _check("char detour found", around.size() > 0, true)
	fails += _check("char detour near target", _near(around[around.size() - 1], c_to, 3.0), true)
	var okc := true
	var cur := c_from
	for wp in around:
		var moved := Mover.attempt(cur, WorldGrid.shortest_delta(cur, wp), 2, "walker")
		if not _near(moved, wp, 0.01):
			okc = false
			break
		cur = moved
	fails += _check("char detour executable", okc, true)
	OccupancyMap.clear()

	# 上山：西坡缓坡逐级爬到 8 级山顶（南北陡崖不可直上，Mover 可执行性即证明合规）
	var base := TerrainMap.tile_center(Vector2i(24, 6))
	var summit := TerrainMap.tile_center(Vector2i(37, 6))
	var climb := Pathfinder.find_path(base, summit, 2, "", false)
	fails += _check("climb found", climb.size() > 0, true)
	fails += _check("climb reaches summit", TerrainMap.tile_height(WorldGrid.to_tile(climb[climb.size() - 1])) == 8, true)
	fails += _check("climb mover-executable", _executable(base, climb), true)
	# 南麓正对山顶出发也必须能到（绕上坡而非撞崖）
	var s_base := TerrainMap.tile_center(Vector2i(37, 14))
	var s_climb := Pathfinder.find_path(s_base, summit, 2, "", false)
	fails += _check("south climb found", s_climb.size() > 0, true)
	fails += _check("south climb executable", _executable(s_base, s_climb), true)

	if fails == 0:
		print("pathfinder tests PASS")
	else:
		printerr("pathfinder tests FAILED: %d" % fails)
	quit(fails)

## 逐格路径每一跳交给 Mover.attempt，必须原样到达（寻路输出与移动规则一致性）。
func _executable(start: Vector2, path: PackedVector2Array) -> bool:
	var cur := start
	for wp in path:
		var moved := Mover.attempt(cur, WorldGrid.shortest_delta(cur, wp))
		if not _near(moved, wp, 0.01):
			printerr("  not executable at %s -> %s (got %s)" % [str(cur), str(wp), str(moved)])
			return false
		cur = moved
	return true

## 拉直路径按运行时步长（0.13m ≈ SPEED 8 / 60fps）细步走完，每步 Mover.attempt 必须前进。
func _fine_walkable(start: Vector2, path: PackedVector2Array) -> bool:
	var cur := start
	for wp in path:
		var guard := 0
		while WorldGrid.shortest_delta(cur, wp).length() > 0.14:
			var d := WorldGrid.shortest_delta(cur, wp)
			var step := d.normalized() * minf(0.13, d.length())
			var moved := Mover.attempt(cur, step)
			if WorldGrid.shortest_delta(moved, WorldGrid.wrap_pos(cur + step)).length() > 0.001:
				printerr("  fine-walk blocked at %s toward %s" % [str(cur), str(wp)])
				return false
			cur = moved
			guard += 1
			if guard > 4000:
				printerr("  fine-walk stuck toward %s" % str(wp))
				return false
		cur = wp
	return true

func _no_water(path: PackedVector2Array) -> bool:
	for wp in path:
		if TerrainMap.type_at(wp) == TerrainMap.T_WATER:
			printerr("  waypoint on water: %s" % str(wp))
			return false
	return true

func _path_len(start: Vector2, path: PackedVector2Array) -> float:
	var cur := start
	var total := 0.0
	for wp in path:
		total += WorldGrid.shortest_delta(cur, wp).length()
		cur = wp
	return total

func _near(a: Vector2, b: Vector2, eps: float) -> bool:
	return WorldGrid.shortest_delta(a, b).length() <= eps

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
