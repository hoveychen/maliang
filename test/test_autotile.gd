extends SceneTree
## Autotile 纯函数的独立测试。
## 运行: godot --headless --path . --script res://test/test_autotile.gd

func _init() -> void:
	var fails := 0

	# corner_variant 真值表（8 组合全覆盖）
	fails += _check("hvd=111 FULL", Autotile.corner_variant(true, true, true), Autotile.V_FULL)
	fails += _check("hvd=110 INNER", Autotile.corner_variant(true, true, false), Autotile.V_INNER)
	fails += _check("hvd=101 EDGE_H", Autotile.corner_variant(true, false, true), Autotile.V_EDGE_H)
	fails += _check("hvd=100 EDGE_H", Autotile.corner_variant(true, false, false), Autotile.V_EDGE_H)
	fails += _check("hvd=011 EDGE_V", Autotile.corner_variant(false, true, true), Autotile.V_EDGE_V)
	fails += _check("hvd=010 EDGE_V", Autotile.corner_variant(false, true, false), Autotile.V_EDGE_V)
	fails += _check("hvd=001 OUTER", Autotile.corner_variant(false, false, true), Autotile.V_OUTER)
	fails += _check("hvd=000 OUTER", Autotile.corner_variant(false, false, false), Autotile.V_OUTER)

	# corners_from_mask：孤立 tile → 四角全凸
	fails += _check_corners("isolated", 0,
		[Autotile.V_OUTER, Autotile.V_OUTER, Autotile.V_OUTER, Autotile.V_OUTER])
	# 全邻居 → 四角全内部
	fails += _check_corners("interior", 255,
		[Autotile.V_FULL, Autotile.V_FULL, Autotile.V_FULL, Autotile.V_FULL])
	# 横向走廊（东西相连）→ 四角都是水平边线
	fails += _check_corners("h corridor", Autotile.E | Autotile.W,
		[Autotile.V_EDGE_H, Autotile.V_EDGE_H, Autotile.V_EDGE_H, Autotile.V_EDGE_H])
	# 仅北邻 → 北侧两角垂直边线，南侧两角凸角
	fails += _check_corners("north only", Autotile.N,
		[Autotile.V_EDGE_V, Autotile.V_EDGE_V, Autotile.V_OUTER, Autotile.V_OUTER])
	# 北+东+东北 → NE 角内部，NW 垂直边，SE 水平边，SW 凸角
	fails += _check_corners("ne full", Autotile.N | Autotile.E | Autotile.NE,
		[Autotile.V_EDGE_V, Autotile.V_FULL, Autotile.V_OUTER, Autotile.V_EDGE_H])
	# 北+东但无东北 → NE 角凹角
	fails += _check_corners("ne concave", Autotile.N | Autotile.E,
		[Autotile.V_EDGE_V, Autotile.V_INNER, Autotile.V_OUTER, Autotile.V_EDGE_H])

	# mask_of：谓词式掩码 + 环面 wrap（借 TerrainMap 池塘中心验证）
	var pond := Vector2i(24, 24)
	var is_water := func(t: Vector2i) -> bool: return TerrainMap.tile_type(t) == TerrainMap.T_WATER
	fails += _check("pond center mask", Autotile.mask_of(pond, is_water), 255)
	var lone := func(t: Vector2i) -> bool: return t == Vector2i(5, 5)
	fails += _check("lone mask", Autotile.mask_of(Vector2i(5, 5), lone), 0)
	var north_of := func(t: Vector2i) -> bool: return t == Vector2i(5, 4)
	fails += _check("north mask", Autotile.mask_of(Vector2i(5, 5), north_of), Autotile.N)

	if fails == 0:
		print("autotile tests PASS")
	else:
		printerr("autotile tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: int, want: int) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %d want %d" % [name, got, want])
	return 1

func _check_corners(name: String, mask: int, want: Array) -> int:
	var got := Autotile.corners_from_mask(mask)
	for i in range(4):
		if got[i] != want[i]:
			printerr("  FAIL %s corner %d: got %d want %d" % [name, i, got[i], want[i]])
			return 1
	return 0
