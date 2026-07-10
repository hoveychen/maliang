extends SceneTree
## 坐标读回（char-position-sync P4）：WorldGrid tile↔world 互逆 + 合法性；
## _restore_logical 读回服务端 tile，越界/缺省回退黄金角散环。
## 运行: godot --headless --path . --script res://test/test_position_restore.gd

const W := preload("res://scripts/world.gd")

func _init() -> void:
	var fails := 0

	# ── WorldGrid：to_tile / from_tile_center 互逆 ─────────────────────────
	for t in [Vector2i(0, 0), Vector2i(37, 37), Vector2i(74, 74), Vector2i(12, 3)]:
		var back := WorldGrid.to_tile(WorldGrid.from_tile_center(t))
		fails += _check("tile %s 往返一致" % t, back, t)

	# 取的是格中心，不是格边界（边界点归属易漂）
	fails += _check("tile(0,0) 中心", WorldGrid.from_tile_center(Vector2i(0, 0)), Vector2(1.0, 1.0))

	# ── is_valid_tile：与服务端 isValidTile 同口径 ────────────────────────
	fails += _check("(0,0) 合法", WorldGrid.is_valid_tile(Vector2i(0, 0)), true)
	fails += _check("(74,74) 合法", WorldGrid.is_valid_tile(Vector2i(74, 74)), true)
	fails += _check("(75,0) 越界", WorldGrid.is_valid_tile(Vector2i(75, 0)), false)
	fails += _check("(-1,0) 越界", WorldGrid.is_valid_tile(Vector2i(-1, 0)), false)
	fails += _check("旧世界 (500,500) 越界", WorldGrid.is_valid_tile(Vector2i(500, 500)), false)

	# ── _restore_logical：读回服务端 tile ─────────────────────────────────
	var w: Node = (W as GDScript).new()

	# 仙子有合法坐标：直接落到该格中心（悬浮不占格，不做避让）
	var fairy_pos: Vector2 = w._restore_logical({ "position": { "tileX": 10, "tileY": 20 } }, true)
	fails += _check("仙子读回格中心", fairy_pos, WorldGrid.from_tile_center(Vector2i(10, 20)))

	# 仙子无坐标：回退世界中心
	var center := Vector2(WorldGrid.WORLD_SPAN, WorldGrid.WORLD_SPAN) * 0.5
	fails += _check("仙子无坐标回退中心", w._restore_logical({}, true), center)

	# 仙子越界坐标（存量角色的 tile 500）：回退世界中心
	fails += _check("仙子越界回退中心", w._restore_logical({ "position": { "tileX": 500, "tileY": 500 } }, true), center)

	# 村民无坐标：走黄金角散环（每调一次 _villager_count++，落点各不相同）
	var v0: Vector2 = w._restore_logical({}, false)
	var v1: Vector2 = w._restore_logical({}, false)
	fails += _check("村民无坐标各自散开", v0 != v1, true)
	fails += _check("村民散环不在中心", v0 != center, true)

	# 村民越界坐标：同样回退黄金角（与改动前行为一致，存量角色不回归）
	var v2: Vector2 = w._restore_logical({ "position": { "tileX": 500, "tileY": 500 } }, false)
	fails += _check("村民越界回退散环", v2 != center, true)
	fails += _check("越界回退与无坐标同一条路", v2 != v1, true)

	# 村民有合法坐标：落在该 tile 附近（_find_free_spot 最多向外挪几格避让）
	var want := WorldGrid.from_tile_center(Vector2i(30, 30))
	var v3: Vector2 = w._restore_logical({ "position": { "tileX": 30, "tileY": 30 } }, false)
	fails += _check("村民读回落在目标附近", WorldGrid.shortest_delta(v3, want).length() < 9.0, true)

	# ── _restore_player_pos：只在引导窗口内搬人 ────────────────────────────
	var home := Vector2(1.0, 1.0)
	w.player = { "logical": home, "id": "player" }

	# 引导窗口已关（断线重连场景）：收到 playerPos 也不动，绝不凭空瞬移
	w._player_restore_pending = false
	w._restore_player_pos({ "tileX": 30, "tileY": 30 })
	fails += _check("重连不搬人", w.player["logical"], home)

	# 引导窗口内 + 越界坐标：不动
	w._player_restore_pending = true
	w._restore_player_pos({ "tileX": 500, "tileY": 500 })
	fails += _check("越界不搬人", w.player["logical"], home)

	# 引导窗口内 + 合法坐标：搬到该 tile 附近
	w._player_restore_pending = true
	w._restore_player_pos({ "tileX": 30, "tileY": 30 })
	var moved_to: Vector2 = w.player["logical"]
	fails += _check("引导窗口内搬人", moved_to != home, true)
	fails += _check("搬到目标附近", WorldGrid.shortest_delta(moved_to, want).length() < 9.0, true)

	# 搬过一次后窗口关闭：同一次进世界不会被第二条 world_state 再搬
	w._restore_player_pos({ "tileX": 5, "tileY": 5 })
	fails += _check("只搬一次", w.player["logical"], moved_to)

	w.free()
	print("test_position_restore: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_VECTOR2 and typeof(want) == TYPE_VECTOR2:
		if (got as Vector2).is_equal_approx(want as Vector2):
			return 0
	elif got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
