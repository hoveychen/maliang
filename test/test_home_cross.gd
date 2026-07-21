extends SceneTree
## 回家跨场景 P5（home-portal-anim）：不在村子时按回家 → 召唤近门 → 走进 → enter_scene(村子) →
## 黑幕后销近门/召远门/坐门上 → 揭幕走出 → 门沉下消散。事件驱动（轮询关键事件，不硬编帧）。
## 离线世界 + online=true 放行 send_*；scene_entered 手动喂（terrainAsset 留空，绕开地形网络拉取）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 90 \
##       --script res://test/test_home_cross.gd

const HP_RISE_NEAR := 1
const HP_CROSS_WAIT := 3   ## 须与 world.gd enum 一致
const HOME_TILE := Vector2i.ZERO

var scene: Node
var frame := 0
var fails := 0
var sent: Array = []
var started := false
var fed := false
var reached_cross := false
var done := false

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
		(scene.get("backend") as Backend).sent.connect(func(m: Dictionary) -> void: sent.append(m))
		scene.set("online", true)
		return
	if frame == 10:
		var p: Dictionary = scene.get("player")
		if p.is_empty():
			printerr("  ✗ 没有玩家节点"); fails += 1; _finish(); return
		scene.set("_scene_id", "forest") # 置身别的场景 → 回家走跨场景分支
		scene.call("_go_home")
		_check("回家启动 _homing", scene.get("_homing"), true)
		_check("标记为跨场景 _home_cross", scene.get("_home_cross"), true)
		_check("召唤了近门(1 座)", (scene.get("_home_portals") as Array).size(), 1)
		_check("起始阶段 = RISE_NEAR", scene.get("_home_phase"), HP_RISE_NEAR)
		started = true
		return
	if not started:
		return
	# 走进完成 → enter_scene 发出 → 喂 scene_entered(村子)
	if not fed and _count("enter_scene") >= 1:
		_check("走进后发出 enter_scene", _count("enter_scene") >= 1, true)
		_check("enter_scene 目标是主场景", String(_last_of("enter_scene").get("sceneId", "")), "village_forest")
		_check("进入 CROSS_WAIT 阶段", scene.get("_home_phase"), HP_CROSS_WAIT)
		_check("过场进行中", scene.get("_transitioning"), true)
		reached_cross = true
		scene.call("_on_scene_entered", {
			"sceneId": "village_forest",
			"scene": { "sceneId": "village_forest", "terrainAsset": "", "pois": [], "portals": [] },
			"characters": [], "props": [],
		})
		fed = true
		return
	# 过场彻底收尾 + 回家状态机走完 → 断言最终态
	if fed and not done and not bool(scene.get("_homing")):
		done = true
		_check("回家结束 _homing=false", scene.get("_homing"), false)
		_check("已切到主场景", String(scene.get("_scene_id")), "village_forest")
		_check("临时门全消散", (scene.get("_home_portals") as Array).size(), 0)
		_check("玩家落在原点附近(≤3格)", _player_dist(HOME_TILE) <= 3, true)
		_finish()
		return
	# 兜底：太久没走完就失败并给诊断
	if frame > 80:
		printerr("  ✗ 超时未走完：reached_cross=%s fed=%s homing=%s phase=%s scene=%s" % [
			reached_cross, fed, scene.get("_homing"), scene.get("_home_phase"), scene.get("_scene_id")])
		fails += 1
		_finish()

func _finish() -> void:
	print("home_cross ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	if is_instance_valid(scene):
		scene.queue_free()
	scene = null
	quit(fails)

func _count(kind: String) -> int:
	var n := 0
	for m in sent:
		if String((m as Dictionary).get("type", "")) == kind:
			n += 1
	return n

func _last_of(kind: String) -> Dictionary:
	for i in range(sent.size() - 1, -1, -1):
		if String((sent[i] as Dictionary).get("type", "")) == kind:
			return sent[i]
	return {}

func _player_dist(tile: Vector2i) -> int:
	var p: Dictionary = scene.get("player")
	if p.is_empty():
		return 999
	var d := WorldGrid.shortest_delta(p["logical"], WorldGrid.from_tile_center(tile))
	return int(round(d.length() / WorldGrid.TILE_SIZE))

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok ", name)
	else:
		printerr("  ✗ %s: got %s, want %s" % [name, got, want]); fails += 1
