extends SceneTree
## 奖赏系统 world 层集成断言：world_state 同步与任务 chip / 三类完成判定钩子
## （送达=近身对话目标、带到=相邻轮询、到点=距离轮询）/ task_complete 庆祝与收集册 /
## give 玩家走位交接。离线 demo 世界，注入服务端回包（与真实 WS 同路），
## 出站消息经 Backend.sent 信号捕获。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 260 --script res://test/test_visual_rewards.gd

const DT := 0.1

var scene: Node
var frame := 0
var fails := 0
var blue: Dictionary = {}
var green: Dictionary = {}
var sent: Array = []
var give_done := 0

func _initialize() -> void:
	# TEST_SEED 固定全局 RNG（NPC 漫游/相位都吃它）：偶发失败可用同种子确定性复跑
	var s := OS.get_environment("TEST_SEED")
	if not s.is_empty():
		seed(int(s))
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _task(type: String, over := {}) -> Dictionary:
	var t := {
		"id": "t_%s" % type, "type": type, "npcId": String(green.get("id", "")),
		"npcName": "小绿", "rewardId": "star",
	}
	t.merge(over, true)
	return t

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
		for n in (scene.get("npcs") as Array):
			match (n["node"] as PaperCharacter).char_name:
				"小蓝": blue = n
				"小绿": green = n
		(scene.get("backend") as Backend).sent.connect(func(m: Dictionary) -> void: sent.append(m))
		scene.set("online", true) # 离线世界里启用任务判定钩子（send 由 sent 信号观测）
		return
	match frame:
		3:
			# world_state 同步：背包+进行中委托 → chip 可见、收集册亮起
			scene.call("_on_world_state", { "inventory": { "flower": 2 },
				"activeTask": _task("deliver", { "targetName": "小蓝", "message": "hi" }) })
			var chip := scene.get("task_chip") as HBoxContainer
			_check("task chip visible", chip.visible, true)
			var chip_text := ""
			var chip_icons := 0
			for c in chip.get_children():
				if c is Label:
					chip_text += (c as Label).text
				elif c is TextureRect:
					chip_icons += 1
			_check("task chip shows goal", chip_text.contains("小蓝"), true)
			_check("task chip shows target+reward icons", chip_icons >= 2, true)
			_check("inventory synced", int((scene.get("inventory") as Dictionary).get("flower", 0)), 2)
			scene.call("_toggle_album")
			_check("album opens", (scene.get("album_panel") as PanelContainer).visible, true)
			scene.call("_toggle_album")
		5:
			# deliver 判定：亲自走到目标角色旁开始对话 = 送达
			scene.call("_enter_interaction", blue["node"])
			var ev := _last_of("task_event")
			_check("deliver_done sent on meeting target", String(ev.get("kind", "")), "deliver_done")
			scene.call("_exit_interaction")
		8:
			# task_complete：清 chip、进背包、委托人跳跃庆祝、小仙子欢呼（预制台词）
			var fv := scene.get("fairy_voice") as FairyVoice
			_check("fairy has reward cheer lines", fv.can_play("reward"), true)
			scene.call("_on_task_complete", { "task": _task("deliver"), "rewardId": "star",
				"rewardGlyph": "⭐", "inventory": { "flower": 2, "star": 1 } })
			_check("chip cleared on complete", (scene.get("task_chip") as HBoxContainer).visible, false)
			_check("reward in inventory", int((scene.get("inventory") as Dictionary).get("star", 0)), 1)
			_check("quest giver celebrates (jump)", String(green.get("paper_action", "")), "jump")
			_check("fairy cheers on reward", fv.is_playing(), true)
		12:
			# bring 判定：目标与委托人相邻（直接把小蓝挪到小绿旁）
			scene.call("_set_active_task", _task("bring", { "targetName": "小蓝" }))
			blue["logical"] = WorldGrid.wrap_pos((green["logical"] as Vector2) + Vector2(2.0, 0.0))
			OccupancyMap.char_register(String(blue.get("id", "")), blue["logical"], 2)
		25:
			var ev := _last_of("task_event")
			_check("bring_done sent when adjacent", String(ev.get("kind", "")), "bring_done")
		28:
			# visit 判定：玩家到地点半径内（传送到池塘边）
			scene.call("_set_active_task", _task("visit", { "locationName": "池塘" }))
			var player: Dictionary = scene.get("player")
			var lp: Vector2 = scene.call("_resolve_location", "池塘")
			player["logical"] = WorldGrid.wrap_pos(lp + Vector2(8.0, 0.0))
			OccupancyMap.char_register(String(player["id"]), player["logical"], int(player["span"]))
		65:
			# bring_done 后有 3s 防连发节流，visit 判定最晚 ~f48 触发，留余量到 f65 再查
			var ev := _last_of("task_event")
			_check("visit_done sent near location", String(ev.get("kind", "")), "visit_done")
			scene.call("_set_active_task", null)
		70:
			# give：语音 give 指令 → 玩家走位到受赠者旁交接（拦截不进 NPC 执行器）。
			# 玩家先传送回小蓝附近（从池塘走回去太远且隔水，不是本断言要验的东西）。
			# 先冻结全部 NPC 漫游（同产线 _halt_npc 对受赠者的语义）：本断言只考走位交接，
			# 旁观 NPC 随机游走曾偶发把走位终点挤到到达阈值外→give 被静默放弃→f240 误报
			# （复现诊断:d(player,blue)=18.31 pending=false，受赠者恢复漫游后越走越远）。
			for ex in (scene.get("_executors") as Array):
				(ex as BehaviorExecutor).cancel()
			var player: Dictionary = scene.get("player")
			player["logical"] = WorldGrid.wrap_pos((blue["logical"] as Vector2) + Vector2(7.0, 0.0))
			OccupancyMap.char_register(String(player["id"]), player["logical"], int(player["span"]))
			scene.call("_on_character_response", { "transcript": "把花送给小蓝", "replyText": "好呀",
				"emotion": "happy", "behaviorScript": { "commands": [
					{ "type": "give", "params": { "character_name": "小蓝", "item": "flower" } }], "loop": false } })
		71:
			_check("give not instant when far", _last_of("give_item").is_empty(), true)
			_check("blue not driven by give script", scene.call("_has_executor_for", blue), false)
		240:
			if give_done == 0: # 失败自诊断：定位是走位没到、被放弃、还是执行器没跑完
				var player: Dictionary = scene.get("player")
				var pend: Dictionary = scene.get("_pending_give")
				var ex: Variant = scene.get("_player_executor")
				var d := WorldGrid.shortest_delta(player["logical"], blue["logical"]).length()
				printerr("  DIAG give stuck: d(player,blue)=%.2f pending=%s exec=%s done=%s" % [
					d, str(not pend.is_empty()),
					str(ex != null), str(ex != null and (ex as BehaviorExecutor).is_done())])
			_check("give completed after walk", give_done > 0, true)
		250:
			if fails == 0:
				print("visual_rewards PASS")
			else:
				printerr("visual_rewards FAILED: %d" % fails)
			quit(fails)
	# give 交接时刻不定（走位耗时随距离/绕障）：轮询到 give_item 出现那一帧立即断言演出与记账
	if frame > 71 and give_done == 0:
		var gv := _last_of("give_item")
		if not gv.is_empty():
			give_done = frame
			_check("give_item payload", String(gv.get("itemId", "")), "flower")
			_check("give recipient correct", String(gv.get("toCharacterId", "")), String(blue.get("id", "")))
			_check("inventory pre-deducted", int((scene.get("inventory") as Dictionary).get("flower", 0)), 1)
			_check("recipient acks with nod", String(blue.get("paper_action", "")), "nod")
			var player: Dictionary = scene.get("player")
			var d := WorldGrid.shortest_delta(player["logical"], blue["logical"]).length()
			_check("giver adjacent on handoff (d=%.1f)" % d, d <= 3.4, true)

func _last_of(type: String) -> Dictionary:
	for i in range(sent.size() - 1, -1, -1):
		if String((sent[i] as Dictionary).get("type", "")) == type:
			return sent[i]
	return {}

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
