extends SceneTree
## BallBody C 档球物理原语的独立单测：踢击赋速 / 摩擦衰减到停 / 撞墙反弹 / 环面 wrap 不变式。
## 纯逻辑推进（不建节点、不渲染），复用 Mover + TerrainMap 默认地形 + OccupancyMap（同 test_mover）。
## 运行: godot --headless --path . --script res://test/test_ball_body.gd

func _init() -> void:
	var fails := 0
	var span := WorldGrid.WORLD_SPAN

	# --- kick：归一化方向 × power 赋速；零向量/非正 power 不动 ---
	var b := BallBody.new()
	b.place(TerrainMap.tile_center(Vector2i(2, 68)))
	b.kick(Vector2(3, 0), 8.0)  # 方向未归一，应被归一到东
	fails += _approx("kick 速度大小", b.velocity.length(), 8.0, 0.001)
	fails += _approx("kick 方向东", b.velocity.normalized().x, 1.0, 0.001)
	fails += _check("kick 后在滚", b.is_rolling(), true)
	var v_before := b.velocity
	b.kick(Vector2.ZERO, 8.0)
	fails += _check("零方向 kick 不改速", b.velocity == v_before, true)
	b.kick(Vector2(1, 0), 0.0)
	fails += _check("零 power kick 不改速", b.velocity == v_before, true)

	# --- MAX_SPEED 硬顶 ---
	b.kick(Vector2(1, 0), 9999.0)
	fails += _approx("MAX_SPEED 钳制", b.velocity.length(), BallBody.MAX_SPEED, 0.001)

	# --- 平地自由滚动：摩擦匀减速、速度单调不增、最终滚停并清零、净位移朝东 ---
	OccupancyMap.clear()
	var ball := BallBody.new()
	var start := TerrainMap.tile_center(Vector2i(2, 68))
	ball.place(start)
	ball.kick(Vector2(1, 0), 5.0)
	var prev_speed := ball.velocity.length()
	var monotonic := true
	var steps := 0
	while ball.is_rolling() and steps < 2000:
		ball.step(0.05)
		var s := ball.velocity.length()
		if s > prev_speed + 0.0001:  # 平地无外力，速度不该回升
			monotonic = false
		prev_speed = s
		steps += 1
	fails += _check("平地速度单调不增", monotonic, true)
	fails += _check("最终滚停", ball.is_rolling(), false)
	fails += _check("停后速度清零", ball.velocity == Vector2.ZERO, true)
	fails += _check("步数有限（未死循环）", steps < 2000, true)
	var disp := WorldGrid.shortest_delta(start, ball.logical)
	fails += _check("净位移朝东（x>0）", disp.x > 0.5, true)
	fails += _check("横向几乎无漂移", absf(disp.y) < 0.2, true)

	# --- 撞墙反弹：朝北滚入水（同 test_mover 的池塘南岸）→ 到边界被挡，被挡轴速度反号、球始终不进水格 ---
	# 一小步不会跨出所在 tile（不碰水），故需多帧把球推到 tile 边界才触发 Mover 撞墙——这正是真实滚动。
	OccupancyMap.clear()
	var wb := BallBody.new()
	var shore := TerrainMap.tile_center(Vector2i(24, 29))  # 池塘正南岸
	wb.place(shore)
	wb.kick(Vector2(0, -1), 6.0)  # 向北（-y）入水
	fails += _check("入水前速度朝北", wb.velocity.y < 0.0, true)
	var bounced := false
	var entered_water := false
	for _i in range(60):
		wb.step(0.05)
		if wb.velocity.y > 0.0:  # y 速度反号朝南 = 撞到水墙反弹了
			bounced = true
		if WorldGrid.to_tile(wb.logical) == Vector2i(24, 28):  # 水格
			entered_water = true
		if bounced:
			break
	fails += _check("滚到水边缘发生反弹（y 速度反号）", bounced, true)
	fails += _check("全程未进水格", entered_water, false)
	OccupancyMap.clear()

	# --- 环面 wrap：place 把越界坐标 wrap 回 [0, WORLD_SPAN)；滚动全程逻辑坐标不越界 ---
	var wrapb := BallBody.new()
	wrapb.place(Vector2(span + 3.0, -2.0))
	fails += _check("place x wrap", wrapb.logical.x >= 0.0 and wrapb.logical.x < span, true)
	fails += _check("place y wrap", wrapb.logical.y >= 0.0 and wrapb.logical.y < span, true)
	fails += _approx("place x wrap 值", wrapb.logical.x, 3.0, 0.001)
	var invariant := true
	wrapb.place(TerrainMap.tile_center(Vector2i(2, 68)))
	wrapb.kick(Vector2(1, 0.3), 9.0)
	for _i in range(400):
		wrapb.step(0.05)
		if wrapb.logical.x < 0.0 or wrapb.logical.x >= span or wrapb.logical.y < 0.0 or wrapb.logical.y >= span:
			invariant = false
			break
		if not wrapb.is_rolling():
			break
	fails += _check("滚动全程逻辑坐标不越界", invariant, true)

	# --- STOP_SPEED：踢一个低于滚停阈值的初速 → 立刻不滚，step 一帧清零 ---
	var sb := BallBody.new()
	sb.place(TerrainMap.tile_center(Vector2i(2, 68)))
	sb.kick(Vector2(1, 0), BallBody.STOP_SPEED * 0.5)
	fails += _check("低于阈值 kick 不算滚", sb.is_rolling(), false)
	var rolling := sb.step(0.05)
	fails += _check("step 返回未在滚", rolling, false)
	fails += _check("残速清零", sb.velocity == Vector2.ZERO, true)

	# --- place 复位速度 ---
	var pb := BallBody.new()
	pb.kick(Vector2(1, 1), 10.0)
	pb.place(TerrainMap.tile_center(Vector2i(5, 60)))
	fails += _check("place 清零速度", pb.velocity == Vector2.ZERO, true)

	if fails == 0:
		print("ball_body tests PASS")
	else:
		printerr("ball_body tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _approx(name: String, got: float, want: float, tol: float) -> int:
	if absf(got - want) <= tol:
		return 0
	printerr("  FAIL %s: got %f want %f (±%f)" % [name, got, want, tol])
	return 1
