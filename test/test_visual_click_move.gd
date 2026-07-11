extends SceneTree
## 点击移动的视觉+行为验证：模拟两次点击——先点空地（玩家寻路走过去、相机跟随、
## 黄色落点标记），再点 NPC（对象叫停、玩家跑到旁边、进近身视图）。
## 断言打印 PASS/FAIL；配合 --write-movie 出截帧做视觉 QA。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie screenshots/click/f.png \
##       --fixed-fps 10 --quit-after 110 --script res://test/test_visual_click_move.gd
## headless 回测（无截图，仅断言）：把 --write-movie <路径> 换成 --headless，或直接跑
## scripts/test-headless.sh；退出码 = 失败断言数。

const DT := 0.1  ## 与 --fixed-fps 10 对应

var scene: Node
var frame := 0
var fails := 0
var ground_target := Vector2.ZERO
var npc_node: Node = null
var villager: Dictionary = {} ## 非仙子的普通村民：验「说完再走」要拿真会走路的角色

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		# headless 的假窗口视口只有 64×64，80px 拾取半径会罩住全屏、点空地必中角色；
		# 强制成与带窗一致的尺寸（_initialize 阶段设置会被窗口初始化覆盖，须在首帧设）。
		root.size = Vector2i(1280, 720)
	match frame:
		10:
			_tap_ground()
		45:
			_check_walked()
			_tap_npc()
		100:
			_check_interaction()
		102:
			_test_voice_short_burst()
		105:
			_test_voice_utterance()
		107:
			_test_think_bubble()
		109:
			_test_emotion_pop()
		111:
			_test_speak_bob_start()
		113:
			_test_speak_bob_active()
		116:
			_test_command_move_defers_exit()
		123:
			_check_leave_after_speech()
		127:
			_test_command_action_keeps_chat()
		129:
			_test_fairy_move_keeps_chat()
		131:
			_test_fairy_relays_without_errand()
		133:
			_check_fairy_relay_landed()
		135:
			if fails == 0:
				print("visual_click_move PASS")
			else:
				printerr("visual_click_move FAILED: %d" % fails)
			quit(fails)

## 点玩家东北方向一块空地：走 _tap_pick 全链路（屏幕→地面拾取→寻路移动→落点标记）。
func _tap_ground() -> void:
	var player: Dictionary = scene.get("player")
	# 方向避开 demo NPC（它们在玩家北侧环面另一头），否则 80px 拾取半径会点中角色
	ground_target = WorldGrid.wrap_pos((player["logical"] as Vector2) + Vector2(12.0, 8.0))
	var sp := _screen_of(ground_target, 0.2)
	scene.call("_tap_pick", sp)
	var marker: Node = scene.get("_tap_marker")
	_check("tap marker shown", marker != null and marker.get("visible") == true, true)

func _check_walked() -> void:
	var player: Dictionary = scene.get("player")
	var dist := WorldGrid.shortest_delta(player["logical"], ground_target).length()
	# 拾取有半格级误差（射线离散步进），到达半径 1.0 + 拾取误差 → 放宽到 2.0
	_check("player walked to tap (dist=%.2f)" % dist, dist <= 2.0, true)
	var focus: Vector2 = scene.get("focus_logical")
	_check("camera follows player", WorldGrid.shortest_delta(focus, player["logical"]).length() <= 2.0, true)

## 点最近的 NPC：对象应叫停等待，玩家跑到旁边进近身视图。
func _tap_npc() -> void:
	var npcs: Array = scene.get("npcs")
	var player: Dictionary = scene.get("player")
	var best_d := 1e9
	var best: Dictionary = {}
	for n in npcs:
		var d := WorldGrid.shortest_delta(player["logical"], n["logical"]).length()
		if d < best_d:
			best_d = d
			best = n
	if best.is_empty():
		fails += 1
		printerr("  FAIL no npc to tap")
		return
	npc_node = best["node"]
	var sp := _screen_of(best["logical"], 1.6)
	scene.call("_tap_pick", sp)
	_check("approach started", not (scene.get("_approach") as Dictionary).is_empty(), true)

func _check_interaction() -> void:
	var player: Dictionary = scene.get("player")
	var sel: Variant = scene.get("selected")
	_check("entered interaction with tapped npc", sel == npc_node, true)
	if npc_node != null:
		var d := _dict_of(npc_node)
		if not d.is_empty():
			# 站桩：进对话后玩家跳到 NPC 对应侧、离 NPC 恰好 STAGE_GAP(5.0) 处（不再贴身）
			var dist := WorldGrid.shortest_delta(player["logical"], d["logical"]).length()
			_check("player staged at STAGE_GAP from npc (dist=%.2f)" % dist, absf(dist - 5.0) < 0.6, true)
	_check("banner visible", (scene.get("banner") as Label).visible, true)

## 开放麦·短促噪声：触发开口但有声段太短 → 静默取消（不进思考、继续聆听）。
## 注入合成 PCM 走 VoiceCapture._feed 全链路（VAD 事件 → 会话开/取消），与真实麦克风同路。
func _test_voice_short_burst() -> void:
	var vc: Object = scene.get("_vc")
	_check("open mic on enter (vad ready)", vc.is_open(), true)
	vc.call("_feed", _voice_pcm(150))
	_check("burst opens utterance", vc.is_recording(), true)
	vc.call("_feed", _silence_pcm(1200))
	_check("burst cancels silently", vc.is_recording(), false)
	_check("burst no thinking", (scene.get("thinking_label") as Label).visible, false)

## 开放麦·正常说话：说完静音自动断句发送——退出录音、进入思考态、横幅收起。
func _test_voice_utterance() -> void:
	var vc: Object = scene.get("_vc")
	vc.call("_feed", _voice_pcm(800))
	_check("speech opens utterance", vc.is_recording(), true)
	vc.call("_feed", _silence_pcm(1200))
	_check("silence auto-commits", vc.is_recording(), false)
	_check("auto-commit enters thinking", (scene.get("thinking_label") as Label).visible, true)
	_check("auto-commit hides banner", (scene.get("banner") as Label).visible, false)

## 思考态演出：thinking 期间角色头顶应有动画冒泡气泡（幼儿可读的「在想」信号）。
func _test_think_bubble() -> void:
	var bubble := scene.get("_think_bubble") as Label3D
	_check("think bubble visible while thinking", bubble.visible, true)
	_check("think bubble has dots", bubble.text.length() >= 1, true)

## 模拟回复到达：思考清除、情绪贴纸弹出（缩放从小到大）。
func _test_emotion_pop() -> void:
	scene.call("_on_character_response",
		{ "transcript": "你好", "replyText": "你好呀！", "emotion": "happy" })
	_check("response clears thinking", (scene.get("thinking_label") as Label).visible, false)
	var emo := scene.get("emotion_bubble") as Sprite3D
	_check("emotion shows happy sticker", emo.texture == UiAssets.emotion_tex("happy"), true)
	_check("emotion visible", emo.visible, true)
	_check("emotion pop starts small", emo.scale.x < 1.0, true)

## 说话演出准备：思考气泡应已随思考态消失；拉起假 TTS（headless dummy 播放态可置真）。
func _test_speak_bob_start() -> void:
	_check("think bubble gone after response", (scene.get("_think_bubble") as Label3D).visible, false)
	var player := scene.get("_tts_player") as AudioStreamPlayer
	var gen := AudioStreamGenerator.new()
	player.stream = gen
	player.play()

## TTS 播放中：选中角色应处于呼吸弹跳（scale 离开 1）。
## 注意 headless dummy 音频 stop() 后 playing 可能仍为真（已知陷阱），回正路径不在此断言。
func _test_speak_bob_active() -> void:
	var node := npc_node as Node3D
	_check("speaking bob squashes sprite", node != null and node.scale.y != 1.0, true)
	(scene.get("_tts_player") as AudioStreamPlayer).stop()

## 立去系指令（move_to）：说完再走（缺陷 ④）——派发后不得立刻关对话，先把回应说完。
## 此处 replyText 为空、无 TTS 可播，仍应停在「等起播」的宽限里，不许同步退出。
## 说话人必须是普通村民：_tap_npc 取的是离玩家最近的角色 = 随身的小仙子，而她不吃移动脚本
## （_run_behavior 早返回、人根本不走），拿她验「说完再走」等于什么也没验（见 _test_fairy_move_keeps_chat）。
func _test_command_move_defers_exit() -> void:
	villager = _first_villager()
	if villager.is_empty():
		fails += 1
		printerr("  FAIL no villager to command")
		return
	scene.call("_enter_interaction", npc_node)
	# 这一轮要验的是「没有 TTS 可等 → 宽限后动身」，把两路出声都掐掉，免得等招呼语音播完（时长不定）。
	(scene.get("_tts_player") as AudioStreamPlayer).stop()
	var fv: Node = scene.get("fairy_voice")
	if fv != null and fv.get("_player") is AudioStreamPlayer:
		(fv.get("_player") as AudioStreamPlayer).stop()
	_check("re-entered interaction before move cmd", scene.get("selected") == npc_node, true)
	scene.set("selected", villager["node"]) # 把对话对象换成村民（仙子不吃移动脚本）
	scene.call("_on_character_response", { "transcript": "去池塘", "replyText": "",
		"emotion": "happy", "behaviorScript": { "commands": [
			{ "type": "move_to", "params": { "location_name": "池塘" } }], "loop": false } })
	_check("move_to 不再同步关对话（先把话说完）", scene.get("selected") == villager["node"], true)
	_check("延迟退出已武装", (scene.get("_pending_leave") as Dictionary).is_empty(), false)
	_check("说完之前还没动身（仍在闲逛）", _running_script(villager), false)

## 起播宽限过后（这轮没有 TTS 可等）：角色真的动身（接上指令脚本），对话随之关闭。
func _check_leave_after_speech() -> void:
	_check("说完后关对话（selected 清空）", scene.get("selected"), null)
	_check("延迟退出已释放", (scene.get("_pending_leave") as Dictionary).is_empty(), true)
	_check("村民已动身（接上指令脚本）", _running_script(villager), true)

## 该角色身上是否挂着「指令脚本」执行器。村民平时都在自主闲逛（ambient=true），
## 单看 _has_executor_for 恒为真、验不出动没动身；只有非 ambient 的执行器才是服务端下发的指令。
func _running_script(d: Dictionary) -> bool:
	for ex in (scene.get("_executors") as Array):
		if (ex as BehaviorExecutor).drives(d) and not (ex as BehaviorExecutor).ambient:
			return true
	return false

## 小仙子吃移动指令：她是贴身随从，_run_behavior 对她早返回、人不会走开，
## 那就不该按「立去系」把对话关掉——否则孩子说「去风车那儿」，对话没了、仙子纹丝不动。
func _test_fairy_move_keeps_chat() -> void:
	var d: Dictionary = scene.call("_find_npc_dict", npc_node)
	_check("最近的角色确是小仙子", d.get("is_fairy", false), true)
	scene.call("_enter_interaction", npc_node)
	scene.call("_on_character_response", { "transcript": "去池塘", "replyText": "",
		"emotion": "happy", "behaviorScript": { "commands": [
			{ "type": "move_to", "params": { "location_name": "池塘" } }], "loop": false } })
	_check("仙子吃 move_to 不关对话", scene.get("selected") == npc_node, true)
	_check("仙子不武装延迟退出", (scene.get("_pending_leave") as Dictionary).is_empty(), true)

## 点名指派给别人（「小蓝跳一下」），而说话的是小仙子：她不会跑腿——_run_behavior 对她早返回，
## 走 relay_command 等于把指令扔进黑洞，村民永远不动。小仙子隔空施法，指令直接落到执行者身上，
## 对话也不必关（她没离开孩子面前）。
func _test_fairy_relays_without_errand() -> void:
	scene.call("_enter_interaction", npc_node) # 仙子
	villager.erase("paper_action")
	scene.call("_on_character_response", { "transcript": "让它跳一下", "replyText": "",
		"emotion": "happy", "performerId": String(villager.get("id", "")),
		"behaviorScript": { "commands": [
			{ "type": "do_action", "params": { "action": "jump" } }], "loop": false } })
	_check("仙子指派后对话不关", scene.get("selected") == npc_node, true)
	_check("仙子不跑腿（自己没接脚本）", _running_script(scene.call("_find_npc_dict", npc_node)), false)

## 下一帧执行器跑起来：指令真的落到了村民身上（paper_action 由 do_action 写入）。
func _check_fairy_relay_landed() -> void:
	_check("指令直接落到村民身上", String(villager.get("paper_action", "")), "jump")

## 场上第一个非仙子角色（demo 世界里的村民）。
func _first_villager() -> Dictionary:
	for n in (scene.get("npcs") as Array):
		if not (n as Dictionary).get("is_fairy", false):
			return n
	return {}

## 就地动作（do_action）：不该关对话——挥手完还能继续跟它说话（selected 保持）。
func _test_command_action_keeps_chat() -> void:
	scene.call("_enter_interaction", npc_node)
	_check("re-entered interaction before action cmd", scene.get("selected") == npc_node, true)
	scene.call("_on_character_response", { "transcript": "挥挥手", "replyText": "好呀！",
		"emotion": "wave", "behaviorScript": { "commands": [
			{ "type": "do_action", "params": { "action": "wave" } }], "loop": false } })
	_check("do_action keeps chat open (selected stays)", scene.get("selected") == npc_node, true)

func _silence_pcm(ms: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(ms * VoiceVad.BYTES_PER_MS)
	return out

## 440Hz 正弦、幅度 0.5 模拟人声（与 test_voice_vad 同参）。
func _voice_pcm(ms: int) -> PackedByteArray:
	var n := ms * VoiceVad.BYTES_PER_MS / 2
	var out := PackedByteArray()
	out.resize(n * 2)
	for i in range(n):
		var s := sin(TAU * 440.0 * float(i) / 16000.0) * 0.5
		var v := int(s * 32767.0)
		if v < 0:
			v += 65536
		out[i * 2] = v & 0xFF
		out[i * 2 + 1] = (v >> 8) & 0xFF
	return out

## 逻辑坐标 → 屏幕坐标（与 world 同一弯曲/台阶公式）。
func _screen_of(logical: Vector2, y_off: float) -> Vector2:
	var focus: Vector2 = scene.get("focus_logical")
	var cam: Camera3D = scene.get("camera")
	var d := WorldGrid.shortest_delta(focus, logical)
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(logical))) * TerrainMap.STEP_HEIGHT
	var drop := BendMat.CURVATURE * (d.x * d.x + d.y * d.y)
	return cam.unproject_position(Vector3(d.x, ty + y_off - drop, d.y))

func _dict_of(node: Node) -> Dictionary:
	for n in (scene.get("npcs") as Array):
		if n["node"] == node:
			return n
	return {}

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
