extends SceneTree
## 回家过场边界 P7（home-portal-anim）：重入守卫 + 超时兜底 + 离线软过场。
##   A. 重入：_homing 中再按回家被忽略，不会召第二座门/重启阶段。
##   B. 兜底：_home_total_t 超 HOME_FAILSAFE → 强制硬着陆回原点、清门、收黑幕、解锁。
##   C. 离线：online=false 也走软过场动画，全程不发 enter_scene，落原点。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 90 \
##       --script res://test/test_home_edge.gd

const HP_RISE_NEAR := 1
const HOME_TILE := Vector2i.ZERO

var scene: Node
var frame := 0
var fails := 0
var sent: Array = []
var phase_c_started := false
var phase_c_done := false

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
	# ── A. 重入 ──
	if frame == 10:
		var p: Dictionary = scene.get("player")
		if p.is_empty():
			printerr("  ✗ 没有玩家节点"); fails += 1; _finish(); return
		scene.set("_scene_id", "forest")   # 跨场景分支
		scene.call("_go_home")
		var doors1: int = (scene.get("_home_portals") as Array).size()
		var phase1: int = scene.get("_home_phase")
		scene.call("_go_home")             # 立刻再按一次
		_check("重入被忽略:门没翻倍(仍1座)", (scene.get("_home_portals") as Array).size(), doors1)
		_check("重入被忽略:阶段没被重启", scene.get("_home_phase"), phase1)
		_check("第一次按确实起了 RISE_NEAR", phase1, HP_RISE_NEAR)
		return
	# ── B. 兜底 ──
	if frame == 12:
		scene.set("_home_total_t", 999.0)  # 假装过场卡了很久
		return
	if frame == 14:
		_check("兜底:超时后强制收尾 _homing=false", scene.get("_homing"), false)
		_check("兜底:临时门清空", (scene.get("_home_portals") as Array).size(), 0)
		_check("兜底:黑幕不再过场 _transitioning=false", scene.get("_transitioning"), false)
		_check("兜底:玩家硬着陆到原点(≤3格)", _player_dist(HOME_TILE) <= 3, true)
		return
	# ── C. 离线软过场 ──
	if frame == 18:
		scene.set("online", false)
		scene.set("_scene_id", "village")
		sent.clear()
		# 把玩家挪离原点，好验证软过场真把它送回来
		var p: Dictionary = scene.get("player")
		p["logical"] = WorldGrid.from_tile_center(Vector2i(20, 20))
		scene.call("_go_home")
		_check("离线也启动了回家动画 _homing", scene.get("_homing"), true)
		phase_c_started = true
		return
	if phase_c_started and not phase_c_done and not bool(scene.get("_homing")):
		phase_c_done = true
		_check("离线:全程不发 enter_scene(软过场)", _count("enter_scene"), 0)
		_check("离线:玩家送回原点(≤3格)", _player_dist(HOME_TILE) <= 3, true)
		_check("离线:临时门清空", (scene.get("_home_portals") as Array).size(), 0)
		_finish()
		return
	if frame > 82:
		printerr("  ✗ 超时：phase_c_started=%s homing=%s phase=%s" % [
			phase_c_started, scene.get("_homing"), scene.get("_home_phase")])
		fails += 1
		_finish()

func _finish() -> void:
	print("home_edge ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
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

func _player_dist(tile: Vector2i) -> int:
	var p: Dictionary = scene.get("player")
	if p.is_empty():
		return 999
	return int(round(WorldGrid.shortest_delta(p["logical"], WorldGrid.from_tile_center(tile)).length() / WorldGrid.TILE_SIZE))

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok ", name)
	else:
		printerr("  ✗ %s: got %s, want %s" % [name, got, want]); fails += 1
