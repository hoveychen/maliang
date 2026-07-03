extends SceneTree
## 移动规则（TerrainMap.step_allowed / Mover.attempt）的独立测试。
## 运行: godot --headless --path . --script res://test/test_mover.gd

func _init() -> void:
	var fails := 0

	# step_allowed 纯函数：升 1 可、升 2 不可；降 4 可、降 5 空气墙；水禁入
	fails += _check("flat ok", TerrainMap.step_allowed(0, 0, TerrainMap.T_GRASS), true)
	fails += _check("up 1 ok", TerrainMap.step_allowed(3, 4, TerrainMap.T_GRASS), true)
	fails += _check("up 2 blocked", TerrainMap.step_allowed(3, 5, TerrainMap.T_GRASS), false)
	fails += _check("down 4 ok", TerrainMap.step_allowed(6, 2, TerrainMap.T_GRASS), true)
	fails += _check("down 5 airwall", TerrainMap.step_allowed(6, 1, TerrainMap.T_GRASS), false)
	fails += _check("water blocked", TerrainMap.step_allowed(0, 0, TerrainMap.T_WATER), false)
	fails += _check("path ok", TerrainMap.step_allowed(0, 0, TerrainMap.T_PATH), true)

	# can_step 接默认地形：南坡 (37,13)h0→(37,12)h1 可上；(37,10)h3→(37,9)h5 跳 2 级不可
	fails += _check("climb terrace", TerrainMap.can_step(Vector2i(37, 13), Vector2i(37, 12)), true)
	fails += _check("steep blocked", TerrainMap.can_step(Vector2i(37, 10), Vector2i(37, 9)), false)
	fails += _check("hop down 2 ok", TerrainMap.can_step(Vector2i(37, 9), Vector2i(37, 10)), true)

	# Mover.attempt：平地正常走
	OccupancyMap.clear()
	var flat := TerrainMap.tile_center(Vector2i(2, 68))
	var moved := Mover.attempt(flat, Vector2(0.5, 0.0))
	fails += _check("flat move", moved != flat, true)

	# 池塘边直行入水被挡（垂直方向无滑动分量 → 原地）
	var shore := TerrainMap.tile_center(Vector2i(24, 29))  # 池塘正南岸（最南水排 z=28）
	var into := Mover.attempt(shore, Vector2(0.0, -2.0))   # 向北入水
	fails += _check("water wall", into == shore, true)
	# 斜向入水 → 沿岸滑动（x 分量成功）
	var slide := Mover.attempt(shore, Vector2(1.0, -2.0))
	fails += _check("slide along shore", slide != shore and WorldGrid.to_tile(slide) != Vector2i(24, 28), true)

	# 物件占地阻挡：占住目标脚印后移动被挡
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(3, 68)), 2, 2)
	var at := TerrainMap.tile_center(Vector2i(2, 68))
	var into_prop := Mover.attempt(at, Vector2(2.0, 0.0))
	fails += _check("prop wall", WorldGrid.to_tile(into_prop) != Vector2i(3, 68), true)
	OccupancyMap.clear()

	# 角色层阻挡：他人站位挡路；排除自己后原地小步不被自己脚印挡
	var me := TerrainMap.tile_center(Vector2i(2, 68))
	OccupancyMap.char_register("me", me, 2)
	OccupancyMap.char_register("other", TerrainMap.tile_center(Vector2i(3, 68)), 2)
	fails += _check("self not wall", Mover.attempt(me, Vector2(0.2, 0.0), 2, "me") != me, true)
	fails += _check("no exclude self-blocked", Mover.attempt(me, Vector2(0.2, 0.0)) == me, true)
	var into_char := Mover.attempt(me, Vector2(2.0, 0.0), 2, "me")
	fails += _check("char wall", WorldGrid.to_tile(into_char) != Vector2i(3, 68), true)
	OccupancyMap.clear()

	if fails == 0:
		print("mover tests PASS")
	else:
		printerr("mover tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
