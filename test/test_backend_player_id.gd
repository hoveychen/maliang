extends SceneTree
## Backend 玩家身份注入（P2）：_send 统一注入 playerId + send_world_info 带 profile。
## 用 sent 信号离线观测出站消息（连接未开也发射），无需真实 server。
## 运行: godot --headless --path . --script res://test/test_backend_player_id.gd

func _init() -> void:
	var fails := 0
	var b := Backend.new()
	var captured: Array = []
	b.sent.connect(func(m: Dictionary) -> void: captured.append(m))

	# 未设 player_id：不注入
	b.send_voice_transcript("w1", "c1", "你好")
	fails += _check("无 player_id 不注入", (captured[-1] as Dictionary).has("playerId"), false)

	# 设 player_id：后续消息统一注入（语音上行只剩 voice_transcript 一个口）
	b.player_id = "pid-abc"
	b.send_voice_transcript("w1", "c1", "你好")
	fails += _check("voice_transcript 注入 playerId", (captured[-1] as Dictionary).get("playerId", ""), "pid-abc")
	b.send_greeting("w1", "c1")
	fails += _check("其它消息同样注入 playerId", (captured[-1] as Dictionary).get("playerId", ""), "pid-abc")

	# world_info 带 profile + 显式场景
	b.send_world_info("w1", ["风车"], { "name": "朵朵", "spriteAsset": "h1" }, "forest")
	var wi: Dictionary = captured[-1]
	fails += _check("world_info type", wi.get("type", ""), "world_info")
	fails += _check("world_info 带 playerId", wi.get("playerId", ""), "pid-abc")
	fails += _check("world_info 带 profile.name", (wi.get("profile", {}) as Dictionary).get("name", ""), "朵朵")
	fails += _check("world_info 带 sceneId", wi.get("sceneId", ""), "forest")

	# world_info 空 profile：不带 profile 键；scene_id 缺省 village
	b.send_world_info("w1", [])
	fails += _check("空 profile 不带 profile 键", (captured[-1] as Dictionary).has("profile"), false)
	fails += _check("scene_id 缺省 village", (captured[-1] as Dictionary).get("sceneId", ""), "village")

	# leave_world：离开世界显式收尾会话（Visit），带 worldId + playerId
	b.send_leave_world("w1")
	var lw: Dictionary = captured[-1]
	fails += _check("leave_world type", lw.get("type", ""), "leave_world")
	fails += _check("leave_world 带 worldId", lw.get("worldId", ""), "w1")
	fails += _check("leave_world 带 playerId", lw.get("playerId", ""), "pid-abc")

	b.free()
	if fails == 0:
		print("backend_player_id tests PASS")
	else:
		printerr("backend_player_id tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
