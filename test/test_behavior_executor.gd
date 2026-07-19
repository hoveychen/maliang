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

	# flee：逃离威胁——威胁进 FLEE_NEAR(5) 就沿背离方向逃，拉开到 FLEE_FAR(8) 停下歇着，永不自完成
	OccupancyMap.clear()
	var flee_start := TerrainMap.tile_center(Vector2i(37, 37))
	var threat := { "pos": TerrainMap.tile_center(Vector2i(39, 37)) } # 起手 ~4 单位, 在威胁半径内
	OccupancyMap.char_register("runner", flee_start, 2)
	var d_flee := { "logical": flee_start, "id": "runner" }
	var ex_flee := BehaviorExecutor.new()
	ex_flee.setup(d_flee, { "commands": [ { "type": "flee", "params": { "target_id": "threat" } } ] },
		func(_id: String) -> Vector2: return threat["pos"])
	for i in range(1200):
		ex_flee.step(dt)
	var flee_dist: float = WorldGrid.shortest_delta(d_flee["logical"], threat["pos"]).length()
	fails += _check("flee escapes threat (>=5)", flee_dist >= 5.0, true)
	fails += _check("flee never done", ex_flee.is_done(), false)
	var flee_settle: Vector2 = d_flee["logical"]
	for i in range(120):
		ex_flee.step(dt) # 已在安全距离外：滞回内不再挪步
	fails += _check("flee holds when safe (no jitter)", WorldGrid.shortest_delta(d_flee["logical"], flee_settle).length() <= 1.5, true)
	# 威胁追近 → 重新开逃，进一步拉开
	threat["pos"] = WorldGrid.wrap_pos(d_flee["logical"] + Vector2(3.0, 0.0))
	var near_dist: float = WorldGrid.shortest_delta(d_flee["logical"], threat["pos"]).length()
	for i in range(900):
		ex_flee.step(dt)
	fails += _check("flee re-escapes approaching threat", WorldGrid.shortest_delta(d_flee["logical"], threat["pos"]).length() > near_dist, true)
	ex_flee.cancel()
	fails += _check("flee cancel done", ex_flee.is_done(), true)
	_drain_orphans() # flee 的在途寻路任务收尾（防泄漏/关停崩）

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

	# do_action：写 paper_action 契约键（world 动画层演出），阻塞动作时长后完成
	var d11 := { "logical": l_start, "id": "actor" }
	var ex11 := BehaviorExecutor.new()
	ex11.setup(d11, { "commands": [ { "type": "do_action", "params": { "action": "jump" } } ] })
	ex11.step(dt)
	fails += _check("do_action sets key", String(d11.get("paper_action", "")), "jump")
	fails += _check("do_action blocks", ex11.is_done(), false)
	for i in range(80): # jump 时长 1.0s + 余量
		ex11.step(dt)
	fails += _check("do_action done after duration", ex11.is_done(), true)
	var d12 := { "logical": l_start, "id": "actor2" }
	var ex12 := BehaviorExecutor.new()
	ex12.setup(d12, { "commands": [ { "type": "do_action", "params": { "action": "moonwalk" } } ] })
	ex12.step(dt)
	fails += _check("unknown action falls back to wave", String(d12.get("paper_action", "")), "wave")

	# 20 种动作全在时长表里、且每种都能原样写进契约键（不被 fallback 吞掉）
	fails += _check("action table has 26 entries", BehaviorExecutor.ACTION_DUR.size(), 26)
	for a in BehaviorExecutor.ACTION_DUR:
		var da := { "logical": l_start, "id": "actor_%s" % a }
		var exa := BehaviorExecutor.new()
		exa.setup(da, { "commands": [ { "type": "do_action", "params": { "action": a } } ] })
		exa.step(dt)
		fails += _check("do_action passes through %s" % a, String(da.get("paper_action", "")), a)

	# chat_with：走到聊天对象旁 → 写 chat_with/chat_t 契约键 → 停留 CHAT_DUR 后完成
	OccupancyMap.clear()
	var ch_start := TerrainMap.tile_center(Vector2i(80, 68))
	var ch_target := TerrainMap.tile_center(Vector2i(84, 68))
	OccupancyMap.char_register("walker", ch_start, 2)
	OccupancyMap.char_register("buddy", ch_target, 2)
	var d13 := { "logical": ch_start, "id": "walker" }
	var ex13 := BehaviorExecutor.new()
	ex13.setup(d13, { "commands": [ { "type": "chat_with", "params": { "character_name": "buddy" } } ] },
		func(_id: String) -> Vector2: return ch_target)
	for i in range(3000):
		if d13.has("chat_with"):
			break
		ex13.step(dt)
	fails += _check("chat_with reaches and sets key", String(d13.get("chat_with", "")), "buddy")
	fails += _check("chat_with stops adjacent", WorldGrid.shortest_delta(d13["logical"], ch_target).length() <= 2.6, true)
	fails += _check("chat_with lingers", ex13.is_done(), false)
	var chat_pos: Vector2 = d13["logical"]
	for i in range(int(BehaviorExecutor.CHAT_DUR * 60.0) + 10):
		ex13.step(dt)
	fails += _check("chat_with done after CHAT_DUR", ex13.is_done(), true)
	fails += _check("chat_with stays put while chatting", d13["logical"], chat_pos)

	# relay_command：跑腿传指令——走到执行者旁才把脚本交出去（点名指派不隔空遥控）
	OccupancyMap.clear()
	var r_start := TerrainMap.tile_center(Vector2i(90, 68))
	var r_target := TerrainMap.tile_center(Vector2i(94, 68))
	OccupancyMap.char_register("runner", r_start, 2)
	OccupancyMap.char_register("performer", r_target, 2)
	var d14 := { "logical": r_start, "id": "runner" }
	var relayed := {}
	var jump_script := { "commands": [ { "type": "do_action", "params": { "action": "jump" } } ], "loop": false }
	var ex14 := BehaviorExecutor.new()
	ex14.setup(d14, { "commands": [ { "type": "relay_command", "params": { "to": "performer", "script": jump_script } } ] },
		func(_id: String) -> Vector2: return r_target,
		Callable(), Callable(),
		func(id: String, s: Dictionary) -> void:
			relayed["id"] = id
			relayed["script"] = s)
	ex14.step(dt)
	fails += _check("relay not fired at start", relayed.is_empty(), true)
	for i in range(3000):
		if ex14.is_done():
			break
		ex14.step(dt)
	fails += _check("relay done", ex14.is_done(), true)
	fails += _check("relay walked adjacent", WorldGrid.shortest_delta(d14["logical"], r_target).length() <= 2.6, true)
	fails += _check("relay handed to performer", String(relayed.get("id", "")), "performer")
	fails += _check("relay passes script", (relayed.get("script", {}) as Dictionary).get("commands", []), jump_script["commands"])
	# 解析不到执行者 → 跳过不触发
	var d15 := { "logical": r_start, "id": "runner2" }
	OccupancyMap.char_register("runner2", r_start, 2)
	var relayed2 := {}
	var ex15 := BehaviorExecutor.new()
	ex15.setup(d15, { "commands": [ { "type": "relay_command", "params": { "to": "ghost", "script": jump_script } } ] },
		func(_id: String) -> Vector2: return Vector2.INF,
		Callable(), Callable(),
		func(id: String, _s: Dictionary) -> void: relayed2["id"] = id)
	ex15.step(dt)
	fails += _check("relay unknown performer skipped", ex15.is_done(), true)
	fails += _check("relay unknown performer not fired", relayed2.is_empty(), true)
	OccupancyMap.clear()

	# wander 锚定：圆心必须是首次 wander 的位置（出生锚）而非当前位置——否则 radius
	# 只是步长不是活动范围，随机游走漂满全图（M2 实拍：radius 3 的小猪漫游全地图，
	# 「把话带给猪小弟」变大海捞针）。锚记在角色字典上，交互后重建执行器仍沿用。
	OccupancyMap.clear()
	var w_anchor := TerrainMap.tile_center(Vector2i(30, 30))
	OccupancyMap.char_register("pig", w_anchor, 2)
	var dw := { "logical": w_anchor, "id": "pig" }
	var wander_script := { "commands": [ { "type": "wander", "params": { "radius": 3, "duration": 8 } }, { "type": "wait", "params": { "duration": 0.1 } } ], "loop": true }
	var exw := BehaviorExecutor.new()
	exw.setup(dw, wander_script)
	exw.step(dt) # 首次 wander 启动：建锚 + 选目标
	fails += _check("wander sets anchor on first start", dw.has("wander_anchor"), true)
	fails += _check("wander anchor is spawn pos", dw.get("wander_anchor", Vector2.INF), w_anchor)
	# off 是 [-r,r]² 方形采样，角上距离可达 r·√2≈4.24——界取 4.25（修前圆心=当前位置时距锚 ~20，红绿区分依然悬殊）
	fails += _check("wander target within radius of anchor",
		WorldGrid.shortest_delta(exw._move_to, w_anchor).length() <= 4.25, true)
	exw.cancel()
	# 角色被挪远（模拟已漂移/被剧情带走）后重建执行器：wander 必须拉回锚圈，而非以新位置为圆心继续漂
	dw["logical"] = WorldGrid.wrap_pos(w_anchor + Vector2(20, 0))
	var exw2 := BehaviorExecutor.new()
	exw2.setup(dw, wander_script)
	exw2.step(dt)
	fails += _check("wander re-centers on anchor after displacement",
		WorldGrid.shortest_delta(exw2._move_to, w_anchor).length() <= 4.25, true)
	exw2.cancel()
	OccupancyMap.clear()

	# --- 异步寻路机制（P2）：派发/直线兜底/完成回填/孤儿回收 ---
	# 断言用真实等待（_drain_orphans/_wait_plan 内含 OS.delay_msec），不依赖循环快慢——
	# 合成紧循环里主线程微秒级空转会跑赢 worker 的毫秒级 A*，必须给 worker 真实墙上时间。
	_drain_orphans()  # 先排干上文各用例遗留的在途任务，隔离本段
	fails += _check("orphans drained before async block", BehaviorExecutor._orphans.is_empty(), true)

	# 派发 + 直线兜底：首帧 step 末尾 _begin_move 派发 worker 任务；此刻尚无 waypoint，
	# 走直线兜底（_direct=true），且任务在途（_plan_task!=-1）——主线程没被 A* 阻塞
	OccupancyMap.clear()
	var az := TerrainMap.tile_center(Vector2i(2, 68))
	var bz := TerrainMap.tile_center(Vector2i(12, 68))
	OccupancyMap.char_register("aw", az, 2)
	var da := { "logical": az, "id": "aw" }
	var exa := BehaviorExecutor.new()
	exa.setup(da, { "commands": [ { "type": "move_to", "params": { "target": [bz.x, bz.y] } } ] })
	exa.step(dt)
	fails += _check("async task dispatched on first step", exa._plan_task != -1, true)
	fails += _check("direct fallback before path arrives", exa._direct, true)
	# 只泵 _poll_plan（不移动，避免直线兜底先抵达）等 worker 完成回填 waypoint
	_wait_plan(exa)
	fails += _check("async task completed", exa._plan_task, -1)
	fails += _check("waypoints filled from worker", exa._waypoints.size() > 0 and not exa._direct, true)
	# 再泵到抵达：异步算出的路径照样把 NPC 送到目标
	for i in range(3000):
		if exa.is_done():
			break
		exa.step(dt)
	fails += _check("async move arrived", WorldGrid.shortest_delta(da["logical"], bz).length() <= 1.2, true)

	# 单飞：任务在途时再调 _plan_path 不叠新任务（同一 task id）
	OccupancyMap.clear()
	OccupancyMap.char_register("aw", az, 2)
	var db := { "logical": az, "id": "aw" }
	var exb := BehaviorExecutor.new()
	exb.setup(db, { "commands": [ { "type": "move_to", "params": { "target": [bz.x, bz.y] } } ] })
	exb.step(dt) # 派发
	var tid: int = exb._plan_task
	exb._plan_path() # 在途重复调用
	fails += _check("single-flight: no stacked task", exb._plan_task, tid)
	exb.cancel()

	# 孤儿回收：在途取消 → 任务转孤儿、_plan_task 归 -1 → 集中回收后清空（不泄漏）
	OccupancyMap.clear()
	OccupancyMap.char_register("aw", az, 2)
	var dc := { "logical": az, "id": "aw" }
	var exc := BehaviorExecutor.new()
	exc.setup(dc, { "commands": [ { "type": "move_to", "params": { "target": [bz.x, bz.y] } } ] })
	exc.step(dt) # 派发
	fails += _check("task in flight before cancel", exc._plan_task != -1, true)
	exc.cancel()
	fails += _check("cancel clears own task slot", exc._plan_task, -1)
	fails += _check("cancelled task became orphan", BehaviorExecutor._orphans.size() >= 1, true)
	_drain_orphans()
	fails += _check("orphan reaped, no leak", BehaviorExecutor._orphans.is_empty(), true)
	OccupancyMap.clear()
	_drain_orphans()  # 收尾：任何遗留任务全部回收，避免引擎关停时销毁在途 Callable 崩溃

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

## 等一个执行器的在途寻路任务完成回填（只泵 _poll_plan，不移动角色）。
## 用 OS.delay_msec 给 worker 真实墙上时间——不靠循环次数猜时序。
func _wait_plan(ex: BehaviorExecutor) -> void:
	for i in range(2000): # 上限 ~2s 兜底防挂
		ex._poll_plan()
		if ex._plan_task == -1:
			return
		OS.delay_msec(1)

## 排干所有孤儿在途任务（同样给 worker 真实时间），收尾防泄漏 + 防关停崩溃。
func _drain_orphans() -> void:
	for i in range(2000):
		BehaviorExecutor._reap_orphans()
		if BehaviorExecutor._orphans.is_empty():
			return
		OS.delay_msec(1)
