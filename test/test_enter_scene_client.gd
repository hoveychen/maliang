extends SceneTree
## 换场景客户端协议（scene-portal P4）：Backend.send_enter_scene 报文 + scene_entered 派发。
## 用 sent 信号离线观测出站消息、直接喂 _dispatch 验入站派发，无需真实 server。
## 运行: godot --headless --path . --script res://test/test_enter_scene_client.gd

func _init() -> void:
	var fails := 0

	var b := Backend.new()
	var captured: Array = []
	b.sent.connect(func(m: Dictionary) -> void: captured.append(m))
	b.player_id = "pid-abc"

	# ── send_enter_scene 报文形状 ─────────────────────────────────────────
	b.send_enter_scene("w1", "forest")
	var m: Dictionary = captured[-1]
	fails += _check("type", m.get("type", ""), "enter_scene")
	fails += _check("worldId", m.get("worldId", ""), "w1")
	fails += _check("sceneId", m.get("sceneId", ""), "forest")
	fails += _check("注入 playerId", m.get("playerId", ""), "pid-abc")

	# ── scene_entered 入站派发到信号 ──────────────────────────────────────
	var got: Array = []
	b.scene_entered.connect(func(d: Dictionary) -> void: got.append(d))
	b._dispatch({
		"type": "scene_entered",
		"worldId": "w1",
		"sceneId": "forest",
		"scene": null,
		"characters": [{ "id": "tree-spirit", "name": "树精" }],
		"props": [],
		"playerPos": { "tileX": 12, "tileY": 34 },
	})
	fails += _check("派发一次", got.size(), 1)
	var d: Dictionary = got[-1] if not got.is_empty() else {}
	fails += _check("载荷带 sceneId", d.get("sceneId", ""), "forest")
	fails += _check("载荷带 characters", (d.get("characters", []) as Array).size(), 1)
	fails += _check("载荷带 playerPos.tileX", (d.get("playerPos", {}) as Dictionary).get("tileX", -1), 12)

	# 别的消息不误触 scene_entered
	got.clear()
	b._dispatch({ "type": "world_state", "world": {} })
	fails += _check("world_state 不触发 scene_entered", got.size(), 0)

	b.free()
	print("test_enter_scene_client: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
