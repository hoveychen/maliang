extends SceneTree
## NpcWishVoice 调度与 3D 定位音契约（见 docs/wish-leak-design.md）。
## 漏话是环境音：必须按距离衰减、必须稀、必须能被交互打断，且绝不占用对话的 _tts_player。
## 运行: godot --headless --path . --script res://test/test_npc_wish_voice.gd

var nv: NpcWishVoice
var _ran := false

func _initialize() -> void:
	nv = NpcWishVoice.new()
	root.add_child(nv)
	process_frame.connect(_run_once)

## 造一个假村民（带 3D 节点，模块要往它身上挂 AudioStreamPlayer3D）。
func _npc(id: String, logical: Vector2) -> Dictionary:
	var node := Node3D.new()
	root.add_child(node)
	return { "id": id, "node": node, "logical": logical }

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	nv.set_wishes([
		{ "characterId": "npc1", "voiceId": "v1", "lines": ["要是有棵树就好啦。", "我家门口空落落的。"] },
		{ "characterId": "npc2", "voiceId": "v2", "lines": ["一个人踢球好没意思。"] },
	])

	# 台词入库：只认服务端下发的村民
	fails += _check("wishes loaded", nv._wishes.size(), 2)
	fails += _check("unknown npc has no lines", nv._wishes.has("npc3"), false)

	# 空 lines 的条目丢弃（服务端异常/老客户端）：宁可不说，不能崩
	nv.set_wishes([
		{ "characterId": "npc1", "voiceId": "v1", "lines": ["要是有棵树就好啦。", "我家门口空落落的。"] },
		{ "characterId": "bad", "voiceId": "v3", "lines": [] },
	])
	fails += _check("empty lines dropped", nv._wishes.has("bad"), false)
	fails += _check("整份替换：旧的 npc2 作废", nv._wishes.has("npc2"), false)

	# ── 选句：连着说同一句最出戏，要避开上次那句 ──
	var lines := PackedStringArray(["A", "B"])
	nv._last_line["npc1"] = "A"
	fails += _check("avoids repeating last line", nv._pick_line("npc1", lines), "B")
	# 只有一句可选时才允许重复
	fails += _check("single line may repeat", nv._pick_line("npc1", PackedStringArray(["A"])), "A")

	# ── 忙碌判定：正在对话/正在演动作的村民不该自言自语 ──
	fails += _check("in_chat is busy", nv._busy({ "in_chat": true }), true)
	fails += _check("acting is busy", nv._busy({ "paper_action": "wave" }), true)
	fails += _check("idle npc not busy", nv._busy({ "in_chat": false, "paper_action": "" }), false)

	# ── 3D 定位音：音源必须挂在【村民自己身上】，且带衰减 ──
	# 这是老板的硬要求：全音量播 = 一屋子人在聊天房喊话。
	var n1 := _npc("npc1", Vector2(1, 1))
	var node := n1["node"] as Node3D
	var p := nv._player_for("npc1", node)
	fails += _check("音源是 3D 的（不是 2D 全音量）", p is AudioStreamPlayer3D, true)
	fails += _check("音源挂在村民节点下（跟着他走）", p.get_parent() == node, true)
	fails += _check("有衰减距离上限", p.max_distance, NpcWishVoice.MAX_DISTANCE)
	fails += _check("漏话比对话轻", p.volume_db < 0.0, true)
	fails += _check("同一村民复用同一音源", nv._player_for("npc1", node) == p, true)

	# ── 调度门禁 ──
	nv.set_wishes([{ "characterId": "npc1", "voiceId": "v1", "lines": ["要是有棵树就好啦。"] }])
	var far := _npc("npc1", Vector2(100, 100)) # 听不见的距离
	var near := _npc("npc1", Vector2(1, 1))

	# engaged（玩家在对话/录音/听角色说话）→ 全员闭嘴，不插话
	nv._t = 1000.0
	nv._global_next_ok = 0.0
	nv.update(0.1, [near], Vector2(0, 0), true)
	fails += _check("engaged 时不漏话", nv._next_ok.has("npc1"), false)

	# 太远 → 不触发（省一次白合成的 TTS）
	nv.update(0.1, [far], Vector2(0, 0), false)
	fails += _check("超出听力半径不漏话", nv._next_ok.has("npc1"), false)

	# 全局间隔内 → 闭嘴（同一时刻全世界只有一个人在自言自语）
	nv._global_next_ok = nv._t + 10.0
	nv.update(0.1, [near], Vector2(0, 0), false)
	fails += _check("全局间隔内不漏话", nv._next_ok.has("npc1"), false)

	# 冷却未过 → 闭嘴（一个村民两分钟才嘟囔一句，密了就是唠叨）
	nv._global_next_ok = 0.0
	nv._next_ok["npc1"] = nv._t + 60.0
	nv.update(0.1, [near], Vector2(0, 0), false)
	fails += _check("冷却内不再漏", nv._t < float(nv._next_ok["npc1"]), true)

	# 无 edge_tts（离线/未探活）→ 不崩、不出声（漏话是可有可无的环境音，不值得走降级通道）
	nv._next_ok.clear()
	nv._global_next_ok = 0.0
	nv.edge_tts = null
	nv.update(0.1, [near], Vector2(0, 0), false)
	fails += _check("没有 edge_tts 也不崩", true, true)

	if fails == 0:
		print("npc_wish_voice tests PASS")
	else:
		printerr("npc_wish_voice tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
