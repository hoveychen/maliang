extends SceneTree
## 进对话对方先打招呼的 world 层集成断言（离线 demo 世界）：
##  1) 点普通 NPC 进对话 → 客户端发出 voice_greeting(带该 NPC id)（服务端招呼走 character_response）；
##  2) 点小仙子进对话 → 走预制 fairy_voice greet（离线可用），不发 voice_greeting；
##  3) 招呼是进对话即触发（麦已开但招呼播放期间 _step_voice 自动闭麦，说完再放开——半双工既有逻辑）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_visual_greeting.gd

var scene: Node
var frame := 0
var fails := 0
var sent_msgs: Array = []

func _initialize() -> void:
	var s := OS.get_environment("TEST_SEED")
	if not s.is_empty():
		seed(int(s))
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
	match frame:
		3:
			# 观测后端出站消息（sent 信号连接未开也发射）
			var backend: Node = scene.get("backend")
			if backend != null:
				backend.connect("sent", Callable(self, "_on_sent"))
		4:
			_enter_npc_and_check()
		8:
			scene.call("_exit_interaction")
		10:
			_enter_fairy_and_check()
		18:
			if fails == 0:
				print("visual_greeting PASS")
			else:
				printerr("visual_greeting FAILED: %d" % fails)
			quit(fails)

func _on_sent(msg: Dictionary) -> void:
	sent_msgs.append(msg)

## 点普通 NPC：进对话应发出 voice_greeting，带该 NPC 的 id。
func _enter_npc_and_check() -> void:
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()
	var npc: Dictionary = (scene.get("npcs") as Array)[0]
	var npc_id := String(npc.get("id", ""))
	sent_msgs.clear()
	scene.call("_enter_interaction", npc["node"])
	var greet := sent_msgs.filter(func(m: Dictionary) -> bool: return String(m.get("type", "")) == "voice_greeting")
	_check("NPC 进对话发出 voice_greeting", greet.size() >= 1, true)
	if greet.size() >= 1:
		_check("voice_greeting 带该 NPC id", String(greet[0].get("characterId", "")), npc_id)
	# 招呼期间开放麦已就绪但未在录音（半双工：对方说话时闭麦）
	_check("进对话即开放麦(vad 就绪)", scene.get("_vad") != null, true)
	_check("招呼期间不在录玩家", scene.get("_recording"), false)

## 点小仙子：走预制 fairy_voice greet（离线可用），不发 voice_greeting。
func _enter_fairy_and_check() -> void:
	var fairy: Dictionary = scene.call("_find_fairy")
	if fairy.is_empty():
		_check("找到小仙子", false, true)
		return
	sent_msgs.clear()
	scene.call("_enter_interaction", fairy["node"])
	var fv: Object = scene.get("fairy_voice")
	_check("小仙子进对话播预制 greet(离线可用)", fv != null and fv.call("is_playing"), true)
	var greet := sent_msgs.filter(func(m: Dictionary) -> bool: return String(m.get("type", "")) == "voice_greeting")
	_check("小仙子不走服务端招呼(不发 voice_greeting)", greet.size(), 0)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [str(name), str(got), str(want)])
