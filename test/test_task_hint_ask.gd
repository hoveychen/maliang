extends SceneTree
## 点委托 chip → 问点点「这个任务怎么做呀」走对话通道（合成转写发给小仙子），
## + guard（没委托不发）+ 服务端 taskCleared → 撤 chip。
## 离线 demo 世界，出站消息经 Backend.sent 信号捕获。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_task_hint_ask.gd

var scene: Node
var frame := 0
var fails := 0
var sent: Array = []

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _fairy() -> Dictionary:
	for n in (scene.get("npcs") as Array):
		if (n as Dictionary).get("is_fairy", false):
			return n
	return {}

func _task() -> Dictionary:
	return {
		"id": "t1", "type": "deliver", "npcId": "someone", "npcName": "小兔",
		"targetName": "舞舞兔", "message": "hi", "stampStyle": "star",
	}

func _last_of(type: String) -> Dictionary:
	for i in range(sent.size() - 1, -1, -1):
		if String((sent[i] as Dictionary).get("type", "")) == type:
			return sent[i]
	return {}

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
		(scene.get("backend") as Backend).sent.connect(func(m: Dictionary) -> void: sent.append(m))
		scene.set("online", true) # 启用真对话通道（send 由 sent 观测）
		return
	match frame:
		3:
			var fairy := _fairy()
			_check("有小仙子", not fairy.is_empty(), true)
			# 有进行中委托 → 点 chip → 走 approach，模拟到位进对话（_pending_task_hint 已置）时发问句
			scene.call("_set_active_task", _task())
			sent.clear()
			scene.set("_pending_task_hint", true)
			scene.call("_enter_interaction", fairy["node"])
			var m := _last_of("voice_transcript")
			_check("进对话发了提示问句给点点", String(m.get("transcript", "")).length() > 0, true)
			_check("问句发给的是点点", String(m.get("characterId", "")), String(fairy.get("id", "")))
			_check("发的是 TASK_HINT_QUESTION", String(m.get("transcript", "")), scene.get("TASK_HINT_QUESTION"))
			scene.call("_exit_interaction")
		5:
			# guard：没有进行中委托时点 chip 不发问句
			scene.call("_set_active_task", null)
			sent.clear()
			scene.call("_ask_fairy_about_task")
			_check("没委托不发问句", _last_of("voice_transcript").is_empty(), true)
		7:
			# 已在跟点点说话时点 chip：直接发问句（不靠 approach）
			var fairy := _fairy()
			scene.call("_set_active_task", _task())
			scene.set("selected", fairy["node"])
			sent.clear()
			scene.call("_ask_fairy_about_task")
			_check("已选中点点时点 chip 直接发问句", String(_last_of("voice_transcript").get("characterId", "")), String(fairy.get("id", "")))
			scene.set("selected", null)
		9:
			# 服务端 taskCleared（小朋友说「不想做了」）→ 撤 chip
			scene.call("_set_active_task", _task())
			_check("chip 先可见", (scene.get("task_chip") as HBoxContainer).visible, true)
			scene.call("_on_character_response", {
				"characterId": String(_fairy().get("id", "")), "replyText": "好呀那我们做点别的吧",
				"emotion": "happy", "taskCleared": true,
			})
			_check("taskCleared 后 chip 撤掉", (scene.get("task_chip") as HBoxContainer).visible, false)
		11:
			if fails == 0:
				print("task_hint_ask PASS")
			else:
				printerr("task_hint_ask FAILED: %d" % fails)
			quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
