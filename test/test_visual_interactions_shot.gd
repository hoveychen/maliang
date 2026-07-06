extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：基础交互演出截帧。
## 编排（--fixed-fps 8）：1s 小蓝开始跟随玩家 → 玩家绕广场走一圈（跟随拖尾）→
## 6s 小蓝连做四个动作（挥手/跳/转圈/点头）→ 12s 小绿去找小黄聊天（面对+轮流气泡）→
## 19s 点名传话：对小绿点名小蓝跳——小绿跑腿到小蓝旁交接，小蓝点头应答后跳 → 25s 结束。
## 环境变量：PITCH/DIST 调相机（如 PITCH=30 DIST=16 近景）。
## 运行: godot --write-movie <目录>/f.png --fixed-fps 8 --quit-after 200 \
##       --script res://test/test_visual_interactions_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0
var blue: Dictionary = {}
var green: Dictionary = {}
var yellow: Dictionary = {}

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var pitch := OS.get_environment("PITCH")
	if pitch != "":
		scene.set("_target_pitch", float(pitch))
	var dist := OS.get_environment("DIST")
	if dist != "":
		scene.set("_target_dist", float(dist))
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	frame += 1
	if frame == 1:
		# 全员传送到村庄广场取景（占用图同步迁移）
		_teleport(player, Vector2i(37, 37))
		for n in (scene.get("npcs") as Array):
			match (n["node"] as PaperCharacter).char_name:
				"小蓝": blue = n
				"小绿": green = n
				"小黄": yellow = n
		_teleport(blue, Vector2i(40, 37))
		_teleport(green, Vector2i(34, 36))
		_teleport(yellow, Vector2i(34, 40))
		return
	# ONLY_RELAY=1：只录点名传话段（短时长，降低带窗录像被窗口遮挡节流的风险）
	if OS.get_environment("ONLY_RELAY") != "":
		if frame == 8:
			scene.set("selected", green["node"])
			_inject(blue, { "commands": [{ "type": "do_action", "params": { "action": "jump" } }], "loop": false })
		return
	match frame:
		8:
			_inject(blue, { "commands": [{ "type": "follow", "params": { "target_name": "玩家" } }], "loop": false })
		48:
			_inject(blue, { "commands": [
				{ "type": "do_action", "params": { "action": "wave" } },
				{ "type": "do_action", "params": { "action": "jump" } },
				{ "type": "do_action", "params": { "action": "spin" } },
				{ "type": "do_action", "params": { "action": "nod" } },
			], "loop": false })
		96:
			_inject(green, { "commands": [{ "type": "chat_with", "params": { "character_name": "小黄" } }], "loop": false })
		152:
			# 点名传话：玩家正与小绿对话，点名小蓝跳——小绿跑腿交接，小蓝点头应答后跳
			scene.set("selected", green["node"])
			_inject(blue, { "commands": [{ "type": "do_action", "params": { "action": "jump" } }], "loop": false })
	# 玩家走一段折线（8m/s@8fps，走东/南开阔路面别让房子挡镜头），跟随者拖尾；动作/聊天阶段站住看戏
	var step := Vector2.ZERO
	if frame >= 9 and frame <= 20:
		step = Vector2(1.0, 0.0)
	elif frame >= 21 and frame <= 32:
		step = Vector2(0.0, 1.0)
	elif frame >= 33 and frame <= 40:
		step = Vector2(-1.0, 0.0)
	if step != Vector2.ZERO:
		var moved := WorldGrid.wrap_pos((player["logical"] as Vector2) + step)
		player["logical"] = moved
		OccupancyMap.char_register(String(player["id"]), moved, int(player["span"]))

func _teleport(d: Dictionary, tile: Vector2i) -> void:
	var pos := TerrainMap.tile_center(tile)
	d["logical"] = pos
	OccupancyMap.char_register(String(d.get("id", "")), pos, int(d.get("span", 2)))

func _inject(target: Dictionary, script: Dictionary) -> void:
	scene.call("_on_character_response", {
		"transcript": "", "replyText": "", "emotion": "happy",
		"performerId": String(target.get("id", "")), "behaviorScript": script,
	})
	# QA 取景：藏掉转写/横幅/情绪提示，只看角色演出本身
	(scene.get("heard_label") as Label).visible = false
	(scene.get("banner") as Label).visible = false
	(scene.get("emotion_bubble") as Sprite3D).visible = false
