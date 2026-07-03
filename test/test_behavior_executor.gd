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
