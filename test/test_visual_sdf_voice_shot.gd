extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：语音造物全链路真机演练。
## 对着真实服务端（真 LLM）以文字转写模拟小朋友对小神仙说话——
## 「帮我变一朵会点头的小花」→ 意图路由 create_prop → designSdfProp → item_created
## → 物件在玩家旁落位。录 20s，观察施法回应与落地演出。
## 运行（先起真实服务端）: MALIANG_API_BASE=http://127.0.0.1:18736 godot --write-movie \
##   <目录>/voice.png --fixed-fps 8 --quit-after 160 --script res://test/test_visual_sdf_voice_shot.gd
## 环境变量：SAY 覆盖说话内容。

var scene: Node
var frame := 0
var _sent := false

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if _sent or frame < 20:
		return
	if not bool(scene.get("online")):
		return  # 等世界联网加载完
	if not bool(scene.get("backend").get("_open")):
		return  # 等 WS 握手完成（过早 _send 会被静默丢弃）
	var fairy_id := ""
	for n in scene.get("npcs"):
		if bool((n as Dictionary).get("is_fairy", false)):
			fairy_id = String((n as Dictionary).get("id", ""))
			break
	if fairy_id.is_empty():
		return
	var say := OS.get_environment("SAY")
	if say.is_empty():
		say = "帮我变一朵会点头的小花"
	scene.get("backend").item_created.connect(func(p: Dictionary) -> void: print("[qa] item_created ", String((p.get("item", {}) as Dictionary).get("id", ""))))
	scene.get("backend").prop_failed.connect(func(r: String) -> void: print("[qa] prop_failed ", r))
	scene.get("backend").send_voice_transcript(String(scene.get("world_id")), fairy_id, say)
	print("已模拟说话: %s (player tile=%s)" % [say, str(WorldGrid.to_tile(scene.get("player")["logical"]))])
	_sent = true
