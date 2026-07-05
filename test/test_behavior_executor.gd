extends SceneTree
## BehaviorExecutor 接寻路的集成测试（waypoint 队列/无路回退/互撞等待重算）。
## 运行: godot --headless --path . --script res://test/test_behavior_executor.gd

var _delivered := ""

func _init() -> void:
	var fails := 0
	var dt := 1.0 / 60.0

	# 绕墙 move_to：竖墙挡直线，走 waypoint 绕行到达，且角色层随移动迁移
	OccupancyMap.clear()
	var start := TerrainMap.tile_center(Vector2i(8, 63))
	var goal := TerrainMap.tile_center(Vector2i(12, 63))
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(10, 60)), 2, 14)
	OccupancyMap.char_register("walker", start, 2)
	var d1 := { "logical": start, "id": "walker" }
	var ex1 := BehaviorExecutor.new()
	ex1.setup(d1, { "commands": [ { "type": "move_to", "params": { "target": [goal.x, goal.y] } } ] })
	for i in range(3000):
		if ex1.is_done():
			break
		ex1.step(dt)
	fails += _check("detour done", ex1.is_done(), true)
	fails += _check("detour arrived", WorldGrid.shortest_delta(d1["logical"], goal).length() <= 1.2, true)
	fails += _check("char layer migrated off start", OccupancyMap.char_area_free(OccupancyMap.footprint_origin(start, 2), 2, 2), true)
	fails += _check("char layer at end", OccupancyMap.char_area_free(OccupancyMap.footprint_origin(d1["logical"], 2), 2, 2, "walker"), true)
	fails += _check("char layer occupied at end", OccupancyMap.char_area_free(OccupancyMap.footprint_origin(d1["logical"], 2), 2, 2), false)

	# 送信：路上有静止角色挡道 → 绕开；目标角色占格 → 走到旁边即送达
	OccupancyMap.clear()
	var w_start := TerrainMap.tile_center(Vector2i(16, 68))
	var t_pos := TerrainMap.tile_center(Vector2i(20, 68))
	OccupancyMap.char_register("walker", w_start, 2)
	OccupancyMap.char_register("blocker", TerrainMap.tile_center(Vector2i(18, 68)), 2)
	OccupancyMap.char_register("target", t_pos, 2)
	var d2 := { "logical": w_start, "id": "walker" }
	var ex2 := BehaviorExecutor.new()
	ex2.setup(d2,
		{ "commands": [ { "type": "deliver_message", "params": { "to": "target", "message": "hi" } } ] },
		func(_id: String) -> Vector2: return t_pos,
		func(id: String, msg: String) -> void: _delivered = id + ":" + msg)
	for i in range(3000):
		if ex2.is_done():
			break
		ex2.step(dt)
	fails += _check("deliver done", ex2.is_done(), true)
	fails += _check("delivered", _delivered, "target:hi")
	fails += _check("deliver stopped adjacent", WorldGrid.shortest_delta(d2["logical"], t_pos).length() <= 2.6, true)

	# 围死：四面墙内 move_to 外部 → 有限步内放弃（不死磨），人还在腔内
	OccupancyMap.clear()
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(49, 60)), 8, 2)
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(49, 63)), 8, 2)
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(49, 61)), 2, 4)
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(52, 61)), 2, 4)
	var boxed := TerrainMap.tile_center(Vector2i(50, 61))
	OccupancyMap.char_register("walker", boxed, 2)
	var d3 := { "logical": boxed, "id": "walker" }
	var ex3 := BehaviorExecutor.new()
	var far := TerrainMap.tile_center(Vector2i(60, 61))
	ex3.setup(d3, { "commands": [ { "type": "move_to", "params": { "target": [far.x, far.y] } } ] })
	for i in range(600):
		if ex3.is_done():
			break
		ex3.step(dt)
	fails += _check("boxed gives up", ex3.is_done(), true)
	fails += _check("boxed stays inside", WorldGrid.shortest_delta(d3["logical"], boxed).length() <= 4.0, true)
	OccupancyMap.clear()

	# 玩家指令语义：arrive 覆盖到达半径（走到对象旁停下）+ cancel 中止 + drives 引用判定
	OccupancyMap.clear()
	var p_start := TerrainMap.tile_center(Vector2i(30, 68))
	var p_goal := TerrainMap.tile_center(Vector2i(35, 68))
	OccupancyMap.char_register("walker", p_start, 2)
	var d4 := { "logical": p_start, "id": "walker" }
	var ex4 := BehaviorExecutor.new()
	ex4.setup(d4, { "commands": [ { "type": "move_to", "params": { "target": [p_goal.x, p_goal.y], "arrive": 2.6 } } ] })
	fails += _check("drives same dict", ex4.drives(d4), true)
	fails += _check("drives content-equal dict", ex4.drives({ "logical": p_start, "id": "walker" }), false)
	for i in range(3000):
		if ex4.is_done():
			break
		ex4.step(dt)
	fails += _check("arrive done", ex4.is_done(), true)
	var dist4 := WorldGrid.shortest_delta(d4["logical"], p_goal).length()
	fails += _check("arrive stops adjacent (1.2..2.6)", dist4 <= 2.6 and dist4 >= 1.2, true)

	# cancel：走一半外部中止，之后 step 不再前进
	OccupancyMap.clear()
	OccupancyMap.char_register("walker", p_start, 2)
	var d5 := { "logical": p_start, "id": "walker" }
	var ex5 := BehaviorExecutor.new()
	ex5.setup(d5, { "commands": [ { "type": "move_to", "params": { "target": [p_goal.x, p_goal.y] } } ] })
	for i in range(30):
		ex5.step(dt)
	var mid: Vector2 = d5["logical"]
	fails += _check("moving before cancel", WorldGrid.shortest_delta(p_start, mid).length() > 0.5, true)
	ex5.cancel()
	fails += _check("cancel done", ex5.is_done(), true)
	ex5.step(dt)
	fails += _check("no move after cancel", d5["logical"], mid)
	OccupancyMap.clear()

	# follow：跟随移动目标——追上后保持距离停下（滞回），目标走远重新起步，永不自行完成
	OccupancyMap.clear()
	var f_start := TerrainMap.tile_center(Vector2i(40, 68))
	var leader := { "pos": TerrainMap.tile_center(Vector2i(44, 68)) }
	OccupancyMap.char_register("walker", f_start, 2)
	var d6 := { "logical": f_start, "id": "walker" }
	var ex6 := BehaviorExecutor.new()
	ex6.setup(d6, { "commands": [ { "type": "follow", "params": { "target_name": "leader" } } ] },
		func(_id: String) -> Vector2: return leader["pos"])
	for i in range(600):
		ex6.step(dt)
	var fdist: float = WorldGrid.shortest_delta(d6["logical"], leader["pos"]).length()
	fails += _check("follow catches up (<=3.4)", fdist <= 3.4, true)
	fails += _check("follow never done", ex6.is_done(), false)
	fails += _check("follow reports target", ex6.following_id(), "leader")
	var settle: Vector2 = d6["logical"]
	for i in range(120):
		ex6.step(dt) # 目标不动：滞回内不该抖动挪步
	fails += _check("follow holds distance (no jitter)", d6["logical"], settle)
	leader["pos"] = TerrainMap.tile_center(Vector2i(50, 68)) # 目标走远 → 重新起步追
	for i in range(900):
		ex6.step(dt)
	fdist = WorldGrid.shortest_delta(d6["logical"], leader["pos"]).length()
	fails += _check("follow chases moved target (<=3.4)", fdist <= 3.4, true)
	ex6.cancel()
	fails += _check("follow cancel done", ex6.is_done(), true)

	# stop_follow：立即完成 + 清掉交互叫停记下的 resume_follow 标记
	OccupancyMap.clear()
	OccupancyMap.char_register("walker", f_start, 2)
	var d7 := { "logical": f_start, "id": "walker", "resume_follow": "player" }
	var ex7 := BehaviorExecutor.new()
	ex7.setup(d7, { "commands": [ { "type": "stop_follow", "params": {} } ] })
	ex7.step(dt)
	fails += _check("stop_follow done", ex7.is_done(), true)
	fails += _check("stop_follow clears resume flag", d7.has("resume_follow"), false)

	# move_to character_name：经 resolver 找到角色，走到旁边（对方占格）即到
	OccupancyMap.clear()
	var c_start := TerrainMap.tile_center(Vector2i(60, 68))
	var c_target := TerrainMap.tile_center(Vector2i(64, 68))
	OccupancyMap.char_register("walker", c_start, 2)
	OccupancyMap.char_register("buddy", c_target, 2)
	var d8 := { "logical": c_start, "id": "walker" }
	var ex8 := BehaviorExecutor.new()
	ex8.setup(d8, { "commands": [ { "type": "move_to", "params": { "character_name": "buddy" } } ] },
		func(_id: String) -> Vector2: return c_target)
	for i in range(3000):
		if ex8.is_done():
			break
		ex8.step(dt)
	fails += _check("move_to char done", ex8.is_done(), true)
	fails += _check("move_to char stops adjacent", WorldGrid.shortest_delta(d8["logical"], c_target).length() <= 2.6, true)

	# move_to location_name：经 loc_resolver 解析地点；解析不到 → 跳过不动
	OccupancyMap.clear()
	var l_start := TerrainMap.tile_center(Vector2i(70, 68))
	var l_goal := TerrainMap.tile_center(Vector2i(74, 68))
	OccupancyMap.char_register("walker", l_start, 2)
	var d9 := { "logical": l_start, "id": "walker" }
	var ex9 := BehaviorExecutor.new()
	ex9.setup(d9, { "commands": [ { "type": "move_to", "params": { "location_name": "池塘" } } ] },
		Callable(), Callable(),
		func(loc: String) -> Vector2: return l_goal if loc == "池塘" else Vector2.INF)
	for i in range(3000):
		if ex9.is_done():
			break
		ex9.step(dt)
	fails += _check("move_to location done", ex9.is_done(), true)
	fails += _check("move_to location arrived", WorldGrid.shortest_delta(d9["logical"], l_goal).length() <= 1.2, true)
	var d10 := { "logical": l_start, "id": "walker2" }
	OccupancyMap.char_register("walker2", l_start, 2)
	var ex10 := BehaviorExecutor.new()
	ex10.setup(d10, { "commands": [ { "type": "move_to", "params": { "location_name": "月球" } } ] },
		Callable(), Callable(),
		func(_loc: String) -> Vector2: return Vector2.INF)
	ex10.step(dt)
	fails += _check("unknown location skipped", ex10.is_done(), true)
	fails += _check("unknown location no move", d10["logical"], l_start)
	OccupancyMap.clear()

	if fails == 0:
		print("behavior_executor tests PASS")
	else:
		printerr("behavior_executor tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
