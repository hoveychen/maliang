extends SceneTree
## 坐标回报（char-position-sync P3）：collect_moved 只挑 tile 变过的角色、跳过离线占位 id；
## Backend.send_positions 的报文形状。用 sent 信号离线观测出站消息，无需真实 server。
## 运行: godot --headless --path . --script res://test/test_positions_report.gd

const W := preload("res://scripts/world.gd")

func _init() -> void:
	var fails := 0

	# ── collect_moved：首次全报 ───────────────────────────────────────────
	var reported: Dictionary = {}
	var entries := [
		{ "id": "c1", "tile": Vector2i(10, 20) },
		{ "id": "c2", "tile": Vector2i(3, 4) },
	]
	var moved := W.collect_moved(entries, reported)
	fails += _check("首次全报 2 个", moved.size(), 2)
	fails += _check("报文带 tileX", (moved[0] as Dictionary).get("tileX", -1), 10)
	fails += _check("报文带 tileY", (moved[0] as Dictionary).get("tileY", -1), 20)
	fails += _check("reported 记下 c1", reported.get("c1", Vector2i.ZERO), Vector2i(10, 20))

	# ── 全静止：零上报 ───────────────────────────────────────────────────
	moved = W.collect_moved(entries, reported)
	fails += _check("全静止零上报", moved.size(), 0)

	# ── 只有一个动了：只报那一个 ──────────────────────────────────────────
	entries[1]["tile"] = Vector2i(5, 5)
	moved = W.collect_moved(entries, reported)
	fails += _check("只报动过的那个", moved.size(), 1)
	fails += _check("动的是 c2", (moved[0] as Dictionary).get("id", ""), "c2")
	fails += _check("c2 新 tile", (moved[0] as Dictionary).get("tileX", -1), 5)

	# ── 离线占位 id 永不上报 ──────────────────────────────────────────────
	var local_entries := [
		{ "id": "demo_小蓝", "tile": Vector2i(1, 1) },
		{ "id": "fairy_local", "tile": Vector2i(2, 2) },
		{ "id": "real-uuid", "tile": Vector2i(3, 3) },
	]
	var fresh: Dictionary = {}
	moved = W.collect_moved(local_entries, fresh)
	fails += _check("只报服务端角色", moved.size(), 1)
	fails += _check("报的是真 id", (moved[0] as Dictionary).get("id", ""), "real-uuid")
	fails += _check("占位 id 不进 reported", fresh.has("demo_小蓝"), false)

	# ── Backend.send_positions 报文形状 ──────────────────────────────────
	var b := Backend.new()
	var captured: Array = []
	b.sent.connect(func(m: Dictionary) -> void: captured.append(m))
	b.player_id = "pid-abc"

	b.send_positions("w1", [{ "id": "c1", "tileX": 1, "tileY": 2 }], Vector2i(7, 8))
	var m: Dictionary = captured[-1]
	fails += _check("type", m.get("type", ""), "positions_report")
	fails += _check("worldId", m.get("worldId", ""), "w1")
	fails += _check("注入 playerId", m.get("playerId", ""), "pid-abc")
	fails += _check("chars 长度", (m.get("chars", []) as Array).size(), 1)
	fails += _check("带 player", (m.get("player", {}) as Dictionary).get("tileX", -1), 7)

	# 不带玩家位置时（Vector2i(-1,-1)）不发 player 键
	b.send_positions("w1", [{ "id": "c1", "tileX": 1, "tileY": 2 }])
	fails += _check("无玩家位置不带 player 键", (captured[-1] as Dictionary).has("player"), false)

	# ── send_position_stream 报文形状（P6 高频世界坐标流）──────────────────
	b.send_position_stream("w1", [{ "id": "c1", "x": 100.5, "y": 200.25, "tileX": 10, "tileY": 20 }], { "x": 5.0, "y": 6.0, "tileX": 2, "tileY": 3 }, 987654)
	var sm: Dictionary = captured[-1]
	fails += _check("stream type", sm.get("type", ""), "positions_report")
	fails += _check("stream 带时戳 t", sm.get("t", 0), 987654)
	fails += _check("stream chars 带世界坐标 x", (sm.get("chars", []) as Array)[0].get("x", 0.0), 100.5)
	fails += _check("stream 带 player", (sm.get("player", {}) as Dictionary).get("x", 0.0), 5.0)
	# 空 player 字典不发 player 键
	b.send_position_stream("w1", [{ "id": "c1", "x": 1.0, "y": 1.0, "tileX": 0, "tileY": 0 }], {}, 111)
	fails += _check("空 player 不带 player 键", (captured[-1] as Dictionary).has("player"), false)

	b.free()
	print("test_positions_report: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
