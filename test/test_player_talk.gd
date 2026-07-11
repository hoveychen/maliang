extends SceneTree
## 玩家间互动客户端协议层（player-interaction P2）：
## 1) Backend 把 player_emote / player_speech 下行分发成信号（形状透传）。
## 2) send_player_emote / send_player_speech 出站帧形状正确（含统一注入的 playerId）。
## 直接喂 _dispatch / 监听 sent，无需真实 server。
## 运行: godot --headless --path . --script res://test/test_player_talk.gd

func _init() -> void:
	var fails := 0
	var b := Backend.new()
	b.player_id = "pa"

	var emotes: Array = []
	var speeches: Array = []
	var outbound: Array = []
	b.player_emote.connect(func(d: Dictionary) -> void: emotes.append(d))
	b.player_speech.connect(func(d: Dictionary) -> void: speeches.append(d))
	b.sent.connect(func(d: Dictionary) -> void: outbound.append(d))

	# ── 下行 player_emote → 信号透传 ─────────────────────────────────────
	b._dispatch({
		"type": "player_emote", "sceneId": "village",
		"fromPlayerId": "pb", "targetPlayerId": "pa", "action": "wave",
	})
	fails += _check("收到 1 次 emote", emotes.size(), 1)
	if emotes.size() == 1:
		var e: Dictionary = emotes[0]
		fails += _check("emote 带 fromPlayerId", e.get("fromPlayerId", ""), "pb")
		fails += _check("emote 带 targetPlayerId", e.get("targetPlayerId", ""), "pa")
		fails += _check("emote 带 action", e.get("action", ""), "wave")
		fails += _check("emote 带 sceneId", e.get("sceneId", ""), "village")

	# ── 下行 player_speech → 信号透传（含服务端盖章的 voiceId 与 lang） ──
	b._dispatch({
		"type": "player_speech", "sceneId": "village",
		"fromPlayerId": "pb", "targetPlayerId": "pa",
		"text": "你好呀", "lang": "zh", "voiceId": "zh-CN-YunxiaNeural",
	})
	fails += _check("收到 1 次 speech", speeches.size(), 1)
	if speeches.size() == 1:
		var s: Dictionary = speeches[0]
		fails += _check("speech 带 text", s.get("text", ""), "你好呀")
		fails += _check("speech 带 voiceId", s.get("voiceId", ""), "zh-CN-YunxiaNeural")
		fails += _check("speech 带 lang", s.get("lang", ""), "zh")

	# ── 出站 send_player_emote ───────────────────────────────────────────
	b.send_player_emote("w1", "pb", "jump")
	fails += _check("发出 1 帧", outbound.size(), 1)
	if outbound.size() == 1:
		var o: Dictionary = outbound[0]
		fails += _check("出站 type", o.get("type", ""), "player_emote")
		fails += _check("出站 worldId", o.get("worldId", ""), "w1")
		fails += _check("出站 targetPlayerId", o.get("targetPlayerId", ""), "pb")
		fails += _check("出站 action", o.get("action", ""), "jump")
		fails += _check("统一注入 playerId", o.get("playerId", ""), "pa")

	# ── 出站 send_player_speech（lang 缺省 zh） ──────────────────────────
	b.send_player_speech("w1", "pb", "一起玩吗")
	fails += _check("发出第 2 帧", outbound.size(), 2)
	if outbound.size() == 2:
		var o2: Dictionary = outbound[1]
		fails += _check("出站 type=player_speech", o2.get("type", ""), "player_speech")
		fails += _check("出站 text", o2.get("text", ""), "一起玩吗")
		fails += _check("出站 lang 缺省 zh", o2.get("lang", ""), "zh")

	# ── 未知消息不炸、不误发 ─────────────────────────────────────────────
	b._dispatch({ "type": "player_hug", "x": 1 })
	fails += _check("未知消息不误发 emote", emotes.size(), 1)

	b.free()
	print("player_talk: %d 处失败" % fails)
	quit(fails)

func _check(label: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ok %s" % label)
		return 0
	printerr("  FAIL %s: got=%s want=%s" % [label, got, want])
	return 1
