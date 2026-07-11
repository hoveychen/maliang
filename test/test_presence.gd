extends SceneTree
## 多人 presence 下行协议（mp-sync-gaps P4）：Backend 把 actors_snapshot / actor_join /
## character_spawned 分发成信号，且 actor_leave 仍按老形状（只给 playerId）。
## 直接喂 _dispatch，无需真实 server。
## 运行: godot --headless --path . --script res://test/test_presence.gd

func _init() -> void:
	var fails := 0
	var b := Backend.new()

	var snapshots: Array = []
	var joins: Array = []
	var spawns: Array = []
	var leaves: Array = []
	b.actors_snapshot.connect(func(d: Dictionary) -> void: snapshots.append(d))
	b.actor_join.connect(func(d: Dictionary) -> void: joins.append(d))
	b.character_spawned.connect(func(d: Dictionary) -> void: spawns.append(d))
	b.actor_leave.connect(func(pid: String) -> void: leaves.append(pid))

	# ── actors_snapshot：进场拿到同场景在场名单（含静止的人） ─────────────
	b._dispatch({
		"type": "actors_snapshot", "sceneId": "village",
		"actors": [
			{ "playerId": "pb", "name": "小红", "spriteAsset": "hashB", "tile": { "tileX": 12, "tileY": 34 } },
		],
	})
	fails += _check("收到 1 份快照", snapshots.size(), 1)
	var snap: Dictionary = snapshots[0]
	fails += _check("快照带 sceneId", snap.get("sceneId", ""), "village")
	var actors: Array = snap.get("actors", [])
	fails += _check("名单 1 人", actors.size(), 1)
	var a0: Dictionary = actors[0]
	fails += _check("带 playerId", a0.get("playerId", ""), "pb")
	fails += _check("带真实立绘 hash", a0.get("spriteAsset", ""), "hashB")
	fails += _check("带 tile.tileX", (a0.get("tile", {}) as Dictionary).get("tileX", -1), 12)

	# ── actor_join：新玩家进场 ───────────────────────────────────────────
	b._dispatch({
		"type": "actor_join", "sceneId": "village",
		"actor": { "playerId": "pc", "name": "小刚", "spriteAsset": "hashC" },
	})
	fails += _check("收到 1 次 join", joins.size(), 1)
	var j: Dictionary = joins[0]
	fails += _check("join 带 sceneId", j.get("sceneId", ""), "village")
	fails += _check("join 的 actor", (j.get("actor", {}) as Dictionary).get("playerId", ""), "pc")

	# ── character_spawned：别人造出的新伙伴 ──────────────────────────────
	b._dispatch({
		"type": "character_spawned", "sceneId": "forest",
		"character": { "id": "ch1", "name": "小猫" },
	})
	fails += _check("收到 1 次降生", spawns.size(), 1)
	var s: Dictionary = spawns[0]
	fails += _check("降生带 sceneId", s.get("sceneId", ""), "forest")
	fails += _check("降生带角色 id", (s.get("character", {}) as Dictionary).get("id", ""), "ch1")

	# ── actor_leave：老形状不变（只给 playerId） ─────────────────────────
	b._dispatch({ "type": "actor_leave", "playerId": "pb", "sceneId": "village" })
	fails += _check("收到 1 次离场", leaves.size(), 1)
	fails += _check("离场是 pb", leaves[0], "pb")

	# ── 未知消息不炸 ────────────────────────────────────────────────────
	b._dispatch({ "type": "some_future_msg", "x": 1 })
	fails += _check("未知消息不误发 snapshot", snapshots.size(), 1)

	b.free()
	print("presence: %d 处失败" % fails)
	quit(fails)

func _check(label: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ok %s" % label)
		return 0
	printerr("  FAIL %s: got=%s want=%s" % [label, got, want])
	return 1
