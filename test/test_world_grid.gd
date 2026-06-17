extends SceneTree
## WorldGrid 环面坐标数学的独立测试。
## 运行: Godot --headless --path . --script res://test/test_world_grid.gd

func _init() -> void:
	var span := WorldGrid.WORLD_SPAN
	var fails := 0

	# wrap_scalar: 越过上界绕回
	fails += _check("wrap over", WorldGrid.wrap_scalar(span + 5.0), 5.0)
	# wrap_scalar: 负数绕到上界附近
	fails += _check("wrap neg", WorldGrid.wrap_scalar(-5.0), span - 5.0)
	# 边界正好 = span → 0
	fails += _check("wrap exact span", WorldGrid.wrap_scalar(span), 0.0)

	# shortest_delta: 跨接缝走最短路（999.x→0.x 应是 +10 而不是 -(span-10)）
	var d := WorldGrid.shortest_delta(Vector2(span - 5.0, 0.0), Vector2(5.0, 0.0))
	fails += _check("seam delta x", d.x, 10.0)
	# shortest_delta: 同点 = 0
	var d0 := WorldGrid.shortest_delta(Vector2(123.0, 456.0), Vector2(123.0, 456.0))
	fails += _check("zero delta", d0.length(), 0.0)

	# to_tile: 边界绕回 tile 0
	var t := WorldGrid.to_tile(Vector2(span + WorldGrid.TILE_SIZE * 0.5, 0.0))
	fails += _check("tile wrap", float(t.x), 0.0)

	if fails == 0:
		print("world_grid tests PASS (6/6)")
	else:
		printerr("world_grid tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: float, want: float) -> int:
	if is_equal_approx(got, want):
		return 0
	printerr("  FAIL %s: got %f want %f" % [name, got, want])
	return 1
