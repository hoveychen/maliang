extends SceneTree
## OccupancyMap 占用位图的独立测试。
## 运行: godot --headless --path . --script res://test/test_occupancy_map.gd

func _init() -> void:
	var fails := 0

	# 占用/释放/查询基本流
	OccupancyMap.clear()
	fails += _check("fresh map free", OccupancyMap.is_free_rect(Vector2i(10, 10), 4, 4), true)
	OccupancyMap.occupy_rect(Vector2i(10, 10), 4, 4)
	fails += _check("occupied not free", OccupancyMap.is_free_rect(Vector2i(12, 12), 1, 1), false)
	fails += _check("overlap not free", OccupancyMap.is_free_rect(Vector2i(13, 13), 4, 4), false)
	fails += _check("outside still free", OccupancyMap.is_free_rect(Vector2i(14, 10), 2, 4), true)
	OccupancyMap.free_rect(Vector2i(10, 10), 4, 4)
	fails += _check("freed again", OccupancyMap.is_free_rect(Vector2i(10, 10), 4, 4), true)

	# 环面 wrap：角落矩形跨接缝
	var n := OccupancyMap.CELLS
	OccupancyMap.occupy_rect(Vector2i(n - 1, n - 1), 2, 2)
	fails += _check("wrap corner occupied", OccupancyMap.is_free_rect(Vector2i(0, 0), 1, 1), false)
	OccupancyMap.free_rect(Vector2i(n - 1, n - 1), 2, 2)
	fails += _check("wrap corner freed", OccupancyMap.is_free_rect(Vector2i(0, 0), 1, 1), true)

	# 尺寸离散化
	fails += _check("char 1 tile", OccupancyMap.char_span(1.0), 2)
	fails += _check("char 2.5 tile", OccupancyMap.char_span(2.5), 5)
	fails += _check("char clamp low", OccupancyMap.char_span(0.3), 2)
	fails += _check("char clamp high", OccupancyMap.char_span(9.0), 8)
	fails += _check("prop 1 tile", OccupancyMap.prop_span(1), 2)
	fails += _check("prop clamp high", OccupancyMap.prop_span(20), 32)

	# 坐标换算
	fails += _check("to_cell", OccupancyMap.to_cell(Vector2(3.5, 149.2)) == Vector2i(3, 149), true)
	fails += _check("tile_to_cell", OccupancyMap.tile_to_cell(Vector2i(37, 37)) == Vector2i(74, 74), true)

	# prop_area_ok 双层判定（依赖 TerrainMap 默认地形）
	OccupancyMap.clear()
	fails += _check("grass ok", OccupancyMap.prop_area_ok(Vector2i(2, 68), 2, 2), true)
	fails += _check("pond blocked", OccupancyMap.prop_area_ok(Vector2i(23, 23), 2, 2), false)
	fails += _check("path blocked", OccupancyMap.prop_area_ok(Vector2i(37, 37), 1, 1), false)
	fails += _check("path allowed", OccupancyMap.prop_area_ok(Vector2i(37, 37), 1, 1, true), true)
	# 跨崖不放（(37,12) h1 / (37,13) h0 高度不一致）
	fails += _check("cliff blocked", OccupancyMap.prop_area_ok(Vector2i(37, 12), 1, 2), false)
	fails += _check("terrace ok", OccupancyMap.prop_area_ok(Vector2i(37, 12), 1, 1), true)
	# 已占用则不可放
	OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(2, 68)), 4, 4)
	fails += _check("occupied blocked", OccupancyMap.prop_area_ok(Vector2i(2, 68), 2, 2), false)
	OccupancyMap.clear()

	# 角色层：登记/查询/排除自己
	OccupancyMap.clear()
	var pos := TerrainMap.tile_center(Vector2i(5, 68))
	OccupancyMap.char_register("npc_a", pos, 2)
	var org := OccupancyMap.footprint_origin(pos, 2)
	fails += _check("char blocks others", OccupancyMap.char_area_free(org, 2, 2), false)
	fails += _check("char excludes self", OccupancyMap.char_area_free(org, 2, 2, "npc_a"), true)
	fails += _check("char no prop pollution", OccupancyMap.is_free_rect(org, 2, 2), true)
	# 迁移：同 id 再登记，旧脚印释放、新脚印生效
	var pos2 := TerrainMap.tile_center(Vector2i(8, 68))
	OccupancyMap.char_register("npc_a", pos2, 2)
	fails += _check("char moved away", OccupancyMap.char_area_free(org, 2, 2), true)
	fails += _check("char at new pos", OccupancyMap.char_area_free(OccupancyMap.footprint_origin(pos2, 2), 2, 2), false)
	# 释放
	OccupancyMap.char_unregister("npc_a")
	fails += _check("char unregistered", OccupancyMap.char_area_free(OccupancyMap.footprint_origin(pos2, 2), 2, 2), true)
	# 重叠登记防误擦：B 覆盖 A 的 cell 后释放 A，B 仍在
	OccupancyMap.char_register("npc_a", pos, 2)
	OccupancyMap.char_register("npc_b", pos, 2)
	OccupancyMap.char_unregister("npc_a")
	fails += _check("overlap free keeps b", OccupancyMap.char_area_free(org, 2, 2), false)
	OccupancyMap.char_unregister("npc_b")
	# prop_area_ok 不许压角色
	OccupancyMap.char_register("npc_a", TerrainMap.tile_center(Vector2i(5, 68)), 2)
	fails += _check("prop on char blocked", OccupancyMap.prop_area_ok(Vector2i(5, 68), 2, 2), false)
	fails += _check("prop off char ok", OccupancyMap.prop_area_ok(Vector2i(8, 68), 2, 2), true)
	# clear 连角色层一起清
	OccupancyMap.clear()
	fails += _check("clear wipes chars", OccupancyMap.char_area_free(org, 2, 2), true)

	if fails == 0:
		print("occupancy_map tests PASS")
	else:
		printerr("occupancy_map tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
