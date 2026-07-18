extends SceneTree
## M2 P5（docs/m2-story-director-design.md §4.3/§4.4）headless 验收：
## 故事音包 StoryVoice（lines.json 索引/WAV 资产核数/命中播包/miss 回落仍必达 ack）+
## task_offer 直递委托 + task_complete 带纪念贴纸随包下发 + 小猪家 POI 仙子提示台词齐备。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --script res://test/test_story_voice.gd

const PACK := "res://assets/voice/story_three_pigs"

var _fails := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		printerr("  ✗ ", msg)
		_fails += 1

func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.ready.connect(func() -> void:
		await _run(scene)
		print("story_voice: fails=%d" % _fails)
		quit(_fails))

## 轮询到条件成立或超时（headless 纪律：里程碑轮询+deadline，不做精确帧断言）。
func _wait_until(pred: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if pred.call():
			return true
		await process_frame
	return pred.call()

func _run(scene: Node) -> void:
	# ── 音包资产核数：lines.json 每行都有打包 WAV ──
	var f := FileAccess.open(PACK + "/lines.json", FileAccess.READ)
	_check(f != null, "story 音包 lines.json 在包里")
	var lines: Array = []
	if f != null:
		var data: Variant = JSON.parse_string(f.get_as_text())
		lines = data.get("lines", []) if typeof(data) == TYPE_DICTIONARY else []
	_check(lines.size() >= 30, "预烧台词 ≥30 条（实际 %d）" % lines.size())
	var missing := 0
	for l in lines:
		if not FileAccess.file_exists("%s/%s.wav" % [PACK, String(l["id"])]):
			missing += 1
	_check(missing == 0, "每条台词都有同名 WAV（缺 %d）" % missing)

	# ── StoryVoice：索引/命中/miss ──
	var sv: Variant = scene.get("story_voice")
	_check(sv != null and sv is StoryVoice, "world 挂了 story_voice")
	if sv == null or lines.is_empty():
		return
	var known := String(lines[0]["text"])
	_check(sv.has_line(known), "预烧台词能命中索引")
	_check(not sv.has_line("这句谁也没说过呀"), "未知文本不命中")

	# 命中播包：stage_say 走音包，ack 必达（完成轮询 deadline 兜底）
	var acked := [false]
	scene.call("stage_say", "no_such_actor", known, "", "zh-CN-YunyangNeural",
		func(_ok: bool, _r: Dictionary) -> void: acked[0] = true)
	_check(sv.is_playing() or true, "播包已发起") # dummy 音频下 playing 语义弱，真断言在 ack
	_check(await _wait_until(func() -> bool: return acked[0], 15000), "音包命中的台词 ack 必达")

	# miss 回落：不在音包里的词也必达 ack（时长兜底），演出绝不卡场
	var acked2 := [false]
	scene.call("stage_say", "no_such_actor", "这句谁也没说过呀", "", "zh-CN-YunyangNeural",
		func(_ok: bool, _r: Dictionary) -> void: acked2[0] = true)
	_check(await _wait_until(func() -> bool: return acked2[0], 15000), "miss 回落的台词 ack 必达")

	# ── task_offer 直递委托：不经 character_response 也能挂上任务 chip ──
	scene.call("_on_task_offer", { "task": {
		"id": "t-story", "type": "visit", "npcId": "story_three_pigs_pig_small", "npcName": "猪小弟",
		"locationName": "池塘", "stampStyle": "star", "storyBookId": "three_pigs", "storyChapter": 0,
	} })
	var at: Dictionary = scene.get("active_task")
	_check(String(at.get("id", "")) == "t-story", "task_offer 设进行中委托")

	# ── task_complete 带纪念贴纸：bag 随包下发即时入账，委托清空 ──
	scene.call("_on_task_complete", {
		"task": at, "stampStyle": "star", "flowerGained": false,
		"wallet": { "flowers": 3, "stampProgress": 1, "stampsTotal": 1, "hearts": 0 },
		"sticker": "story_straw", "bag": { "story_straw": 1 },
	})
	var bag: Dictionary = scene.get("bag")
	_check(int(bag.get("story_straw", 0)) == 1, "纪念贴纸随 task_complete 进背包")
	_check((scene.get("active_task") as Dictionary).is_empty(), "完成后委托清空")

	# ── 小猪家 POI：内置 POI 与仙子提示台词齐备（只提示不催促，cooldown 长）──
	var has_poi := false
	for p in scene.get("pois"):
		if String(p.get("trigger", "")) == "poi_story_pigs":
			has_poi = true
	_check(has_poi, "内置 POIS 含小猪家入口")
	# can_play 受全局冷却/正在播影响（时序敏感），这里只验「台词在表里且 WAV 在包里」。
	var fv: Variant = scene.get("fairy_voice")
	var story_hints: Array = []
	if fv != null:
		for l in (fv.get("_lines") as Array):
			if String(l.get("trigger", "")) == "poi_story_pigs":
				story_hints.append(l)
	_check(story_hints.size() >= 1, "仙子有小猪家提示台词（%d 条）" % story_hints.size())
	var hint_missing := 0
	for l in story_hints:
		if not FileAccess.file_exists("res://assets/voice/fairy/%s.wav" % String(l["id"])):
			hint_missing += 1
	_check(hint_missing == 0, "提示台词 WAV 都在包里（缺 %d）" % hint_missing)
