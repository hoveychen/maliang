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
			var dist := WorldGrid.shortest_delta(player["logical"], d["logical"]).length()
			_check("player adjacent to npc (dist=%.2f)" % dist, dist <= 3.2, true)
	_check("banner visible", (scene.get("banner") as Label).visible, true)

## 开放麦·短促噪声：触发开口但有声段太短 → 静默取消（不进思考、继续聆听）。
## 注入合成 PCM 走 _feed_voice_pcm 全链路（VAD 事件 → 会话开/取消），与真实麦克风同路。
func _test_voice_short_burst() -> void:
	_check("open mic on enter (vad ready)", scene.get("_vad") != null, true)
	scene.call("_feed_voice_pcm", _voice_pcm(150))
	_check("burst opens utterance", scene.get("_recording"), true)
	scene.call("_feed_voice_pcm", _silence_pcm(1200))
	_check("burst cancels silently", scene.get("_recording"), false)
	_check("burst no thinking", (scene.get("thinking_label") as Label).visible, false)

## 开放麦·正常说话：说完静音自动断句发送——退出录音、进入思考态、横幅收起。
func _test_voice_utterance() -> void:
	scene.call("_feed_voice_pcm", _voice_pcm(800))
	_check("speech opens utterance", scene.get("_recording"), true)
	scene.call("_feed_voice_pcm", _silence_pcm(1200))
	_check("silence auto-commits", scene.get("_recording"), false)
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
