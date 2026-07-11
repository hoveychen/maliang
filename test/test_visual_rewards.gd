extends SceneTree
## 奖赏系统 world 层集成断言：world_state 同步钱包与任务 chip / 三类完成判定钩子
## （送达=近身对话目标、带到=相邻轮询、到点=距离轮询）/ task_complete 盖章升花庆祝。
## 离线 demo 世界，注入服务端回包（与真实 WS 同路），出站消息经 Backend.sent 信号捕获。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 120 --script res://test/test_visual_rewards.gd

const DT := 0.1

var scene: Node
var frame := 0
var fails := 0
var blue: Dictionary = {}
var green: Dictionary = {}
var sent: Array = []

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
		"npcName": "灵狐小围巾", "stampStyle": "star",
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
				"舞舞兔": blue = n
				"灵狐小围巾": green = n
		(scene.get("backend") as Backend).sent.connect(func(m: Dictionary) -> void: sent.append(m))
		scene.set("online", true) # 离线世界里启用任务判定钩子（send 由 sent 信号观测）
		return
	match frame:
		3:
			# world_state 同步：钱包+进行中委托 → chip 可见、小红花计数亮起
			scene.call("_on_world_state", { "wallet": { "flowers": 2, "stampProgress": 1, "stampsTotal": 4 },
				"activeTask": _task("deliver", { "targetName": "舞舞兔", "message": "hi" }) })
			var chip := scene.get("task_chip") as HBoxContainer
			_check("task chip visible", chip.visible, true)
			var chip_text := ""
			var chip_icons := 0
			for c in chip.get_children():
				if c is Label:
					chip_text += (c as Label).text
				elif c is TextureRect:
					chip_icons += 1
			_check("task chip shows goal", chip_text.contains("舞舞兔"), true)
			_check("task chip shows target+stamp icons", chip_icons >= 2, true)
			_check("wallet flowers synced", scene.call("_red_flower_count"), 2)
			scene.call("_toggle_album")
			_check("phone opens", (scene.get("paper_phone") as PaperPhone).state != PaperPhone.State.STOWED, true)
			scene.call("_toggle_album")
		5:
			# deliver 判定：亲自走到目标角色旁开始对话 = 送达
			scene.call("_enter_interaction", blue["node"])
			var ev := _last_of("task_event")
			_check("deliver_done sent on meeting target", String(ev.get("kind", "")), "deliver_done")
			scene.call("_exit_interaction")
		8:
			# task_complete（未升花）：清 chip、更新钱包盖章进度、委托人跳跃庆祝、小仙子欢呼
			var fv := scene.get("fairy_voice") as FairyVoice
			_check("fairy has reward cheer lines", fv.can_play("reward"), true)
			scene.call("_on_task_complete", { "task": _task("deliver"), "stampStyle": "star",
				"flowerGained": false, "wallet": { "flowers": 2, "stampProgress": 2, "stampsTotal": 5 } })
			_check("chip cleared on complete", (scene.get("task_chip") as HBoxContainer).visible, false)
			_check("stamp progress synced", int((scene.get("wallet") as Dictionary).get("stampProgress", 0)), 2)
			_check("quest giver celebrates (jump)", String(green.get("paper_action", "")), "jump")
			_check("fairy cheers on reward", fv.is_playing(), true)
		12:
			# bring 判定：目标与委托人相邻（直接把舞舞兔挪到灵狐小围巾旁）
			scene.call("_set_active_task", _task("bring", { "targetName": "舞舞兔" }))
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
		68:
			# task_complete（升花）：集满盖章换到 1 朵小红花 → 计数+1、横幅报喜
			scene.call("_on_task_complete", { "task": _task("visit", { "locationName": "池塘" }),
				"stampStyle": "medal", "flowerGained": true,
				"wallet": { "flowers": 3, "stampProgress": 0, "stampsTotal": 6 } })
			_check("flower count up on flowerGained", scene.call("_red_flower_count"), 3)
			var banner := scene.get("banner") as Label
			_check("banner announces flower", banner.text.contains("小红花"), true)
		72:
			if fails == 0:
				print("visual_rewards PASS")
			else:
				printerr("visual_rewards FAILED: %d" % fails)
			quit(fails)

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
