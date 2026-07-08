extends SceneTree
## 基础交互的 world 层集成断言：performer 点名路由 / follow 持续跟随玩家 /
## stop_follow / do_action 契约键 / chat_with 全过程（走位→面对→气泡→散场）/
## 地点名与「玩家」解析。离线 demo 世界（小蓝/小绿/小黄），注入 _on_character_response
## 模拟服务端指令下发，与真实链路同路。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 420 --script res://test/test_visual_interactions.gd

const DT := 0.1

var scene: Node
var frame := 0
var fails := 0
var blue: Dictionary = {}
var green: Dictionary = {}
var yellow: Dictionary = {}
var chat_started := 0
var relay_done := 0

func _initialize() -> void:
	# TEST_SEED 固定全局 RNG（NPC 漫游/相位都吃它）：偶发失败可用同种子确定性复跑
	var s := OS.get_environment("TEST_SEED")
	if not s.is_empty():
		seed(int(s))
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

## 冻结全部 NPC 漫游 + 把角色摆到固定相对位：走位类断言只考走位本身。
## 旁观随机游走曾偶发让到达阈值超限(d=11.8)或传话完成过快抢在断言帧前（同 rewards 病灶）。
func _freeze_and_place(d: Dictionary, anchor: Dictionary, off: Vector2) -> void:
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()
	d["logical"] = WorldGrid.wrap_pos((anchor["logical"] as Vector2) + off)
	OccupancyMap.char_register(String(d.get("id", "")), d["logical"], 2)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
	match frame:
		3:
			_find_npcs()
			_test_resolvers()
		5:
			_inject(blue, { "commands": [{ "type": "follow", "params": { "target_name": "玩家" } }], "loop": false })
		7:
			_check("follow executor attached", _following_of(blue), "玩家")
		80:
			_check("follower caught player (d=%.1f)" % _dist_to_player(blue), _dist_to_player(blue) <= 4.2, true)
			# 玩家瞬移走远：跟随应重新起步追上（占用图重登记，别把旧位置留成幽灵墙）
			var player: Dictionary = scene.get("player")
			var moved := WorldGrid.wrap_pos((player["logical"] as Vector2) + Vector2(14.0, 0.0))
			player["logical"] = moved
			OccupancyMap.char_register(String(player["id"]), moved, int(player["span"]))
		160:
			_check("follower chased moved player (d=%.1f)" % _dist_to_player(blue), _dist_to_player(blue) <= 4.2, true)
			_inject(blue, { "commands": [{ "type": "stop_follow", "params": {} }], "loop": false })
		170:
			_check("stop_follow ends following", _following_of(blue), "")
			_check("stopped follower resumes wander", scene.call("_has_executor_for", blue), true)
		175:
			_inject(green, { "commands": [{ "type": "do_action", "params": { "action": "jump" } }], "loop": false })
		176:
			_check("do_action key set", String(green.get("paper_action", "")), "jump")
		200:
			_check("do_action key cleared after duration", green.has("paper_action"), false)
		205:
			_freeze_and_place(yellow, green, Vector2(8.0, 0.0)) # 小黄定点等着，只考小绿走位
			_inject(green, { "commands": [{ "type": "chat_with", "params": { "character_name": "小黄" } }], "loop": false })
		310:
			_check("chat happened", chat_started > 0, true)
		312:
			# 点名指派传话链路：设玩家正与小绿对话，点名小蓝跳——小绿应跑腿传话，小蓝收到才动。
			# 小蓝固定摆到 10 单位外：距离太近曾让传话在 f316 断言前就完成（假阳"被遥控"）
			_freeze_and_place(blue, green, Vector2(10.0, 0.0))
			scene.set("selected", green["node"])
			_inject(blue, { "commands": [{ "type": "do_action", "params": { "action": "jump" } }], "loop": false })
		315:
			# 收听 HUD 重设计：头顶耳朵已删除（不再有 ear_icon 盖脸）；选中角色时底部 AIGC
			# 边框 HUD（hud_listen）显示，声波柱嵌在边框内板。
			_check("ear_icon removed (no head sprite)", scene.get("ear_icon"), null)
			var vw := scene.get("voice_wave") as Control
			_check("listen HUD shown on select", vw.visible, true)
			var frame := vw.get_child(0) as TextureRect
			_check("HUD frame texture present", frame != null and frame.texture != null, true)
		316:
			_check("performer not remote-controlled", blue.has("paper_action"), false)
			_check("speaker runs errand", scene.call("_has_executor_for", green), true)
		395:
			_check("relay reached performer", relay_done > 0, true)
			scene.set("selected", null)
		400:
			if fails == 0:
				print("visual_interactions PASS")
			else:
				printerr("visual_interactions FAILED: %d" % fails)
			quit(fails)
	# 传话到达时刻不定：小蓝出现动作键（点头应答/跳）即传到，此刻小绿应已跑到小蓝旁。
	# 阈值 = 送达半径 2.6 + 追踪节流 0.5s 内对方闲逛再挪的余量（~8*0.5*漫步占比）
	if frame > 312 and relay_done == 0 and blue.has("paper_action"):
		relay_done = frame
		_check("errand runner adjacent on handoff (d=%.1f)" % _dist(green, blue), _dist(green, blue) <= 4.5, true)
		_check("performer acks with nod", String(blue.get("paper_action", "")), "nod")
	# chat_with 到达时刻不定（起点受闲逛影响）：轮询里程碑
	if frame > 205 and chat_started == 0 and green.has("chat_with"):
		chat_started = frame
	elif chat_started > 0 and frame == chat_started + 20:
		_check("chat keeps partner (in_chat)", yellow.get("in_chat", false), true)
		_check("chat bubble visible", (scene.get("_npc_chat_bubble") as Sprite3D).visible, true)
		# 阈值同传话：送达半径 2.6 + 对方被叫停前追踪节流窗口内的闲逛漂移余量
		_check("chatters adjacent (d=%.1f)" % _dist(green, yellow), _dist(green, yellow) <= 4.5, true)
		var dx := WorldGrid.shortest_delta(green["logical"], yellow["logical"]).x
		_check("green faces yellow", float(green.get("paper_face", -1.0)), 0.0 if dx > 0.0 else PI)
		_check("yellow faces green", float(yellow.get("paper_face", -1.0)), 0.0 if dx <= 0.0 else PI)
	elif chat_started > 0 and frame == chat_started + 75:
		_check("chat ends (key cleared)", green.has("chat_with"), false)
		_check("chat bubble hidden after end", (scene.get("_npc_chat_bubble") as Sprite3D).visible, false)
		_check("partner released (in_chat cleared)", yellow.get("in_chat", false), false)
		_check("partner resumes wander", scene.call("_has_executor_for", yellow), true)

func _find_npcs() -> void:
	for n in (scene.get("npcs") as Array):
		match (n["node"] as PaperCharacter).char_name:
			"小蓝": blue = n
			"小绿": green = n
			"小黄": yellow = n
	_check("demo npcs found", not blue.is_empty() and not green.is_empty() and not yellow.is_empty(), true)

## 地点名 / 角色名解析（语音指令的目标落地基础）。
func _test_resolvers() -> void:
	_check("resolve 池塘", scene.call("_resolve_location", "池塘") != Vector2.INF, true)
	_check("resolve 大池塘 (fuzzy)", scene.call("_resolve_location", "大池塘") != Vector2.INF, true)
	_check("resolve alias 山顶", scene.call("_resolve_location", "山顶") != Vector2.INF, true)
	_check("resolve 月球 fails", scene.call("_resolve_location", "月球") == Vector2.INF, true)
	var player: Dictionary = scene.get("player")
	_check("resolve 玩家", scene.call("_resolve_char_pos", "玩家"), player["logical"])
	_check("resolve npc by name", scene.call("_resolve_char_pos", "小黄"), yellow["logical"])

## 模拟服务端 character_response（performerId 点名路由），与真实 WS 回包同路。
func _inject(target: Dictionary, script: Dictionary) -> void:
	scene.call("_on_character_response", {
		"transcript": "测试", "replyText": "好！", "emotion": "happy",
		"performerId": String(target.get("id", "")), "behaviorScript": script,
	})

func _following_of(d: Dictionary) -> String:
	for ex in (scene.get("_executors") as Array):
		if (ex as BehaviorExecutor).drives(d):
			var fid := (ex as BehaviorExecutor).following_id()
			if not fid.is_empty():
				return fid
	return ""

func _dist_to_player(d: Dictionary) -> float:
	var player: Dictionary = scene.get("player")
	return WorldGrid.shortest_delta(d["logical"], player["logical"]).length()

func _dist(a: Dictionary, b: Dictionary) -> float:
	return WorldGrid.shortest_delta(a["logical"], b["logical"]).length()

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
