extends SceneTree
## 回家同场景软过场 P6（home-portal-anim，需求 2 核心）：已在村子里按回家，也走完整传送门动画——
## 召门 → 走进 → 黑幕全黑(遮住原地瞬移到原点) → 淡出 → 走出 → 门消散，而**不是**静默 snap。
## 关键断言：_fade_a 到过≈1（真过场，不是"啥也没发生"）再回 0；全程不发 enter_scene 报文；末了落原点、门清空。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 90 \
##       --script res://test/test_home_soft.gd

const HP_RISE_NEAR := 1
const HOME_TILE := Vector2i.ZERO

var scene: Node
var frame := 0
var fails := 0
var sent: Array = []
var started := false
var done := false
var max_fade := 0.0

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
		scene.set("online", true) # 在线也要:同场景不发报文,证明"不静默"靠的是过场动画不是换场景
		return
	if frame == 10:
		var p: Dictionary = scene.get("player")
		if p.is_empty():
			printerr("  ✗ 没有玩家节点"); fails += 1; _finish(); return
		_check("起始就在村子里", String(scene.get("_scene_id")), "village")
		scene.call("_go_home")
		_check("回家启动 _homing", scene.get("_homing"), true)
		_check("标记为非跨场景(软过场)", scene.get("_home_cross"), false)
		_check("召唤了近门(1 座)", (scene.get("_home_portals") as Array).size(), 1)
		_check("起始阶段 = RISE_NEAR", scene.get("_home_phase"), HP_RISE_NEAR)
		started = true
		return
	if not started:
		return
	max_fade = maxf(max_fade, float(scene.get("_fade_a")))
	if not done and not bool(scene.get("_homing")):
		done = true
		# 需求 2 核心：真的走了一趟黑幕过场（不是静默 snap）
		_check("过场真的全黑过(_fade_a 到过≈1)", max_fade >= 0.99, true)
		_check("过场收尾后黑幕已淡回(_fade_a≈0)", float(scene.get("_fade_a")) <= 0.01, true)
		# 同场景软过场不发任何换场景报文
		_check("全程未发 enter_scene(不是换场景)", _count("enter_scene"), 0)
		_check("仍在村子里(没换场景)", String(scene.get("_scene_id")), "village")
		# 末态：落原点、门清空、已解锁
		_check("玩家落在原点附近(≤3格)", _player_dist(HOME_TILE) <= 3, true)
		_check("临时门全消散", (scene.get("_home_portals") as Array).size(), 0)
		_check("不再过场 _transitioning=false", scene.get("_transitioning"), false)
		_finish()
		return
	if frame > 82:
		printerr("  ✗ 超时未走完：homing=%s phase=%s max_fade=%.2f fade=%.2f" % [
			scene.get("_homing"), scene.get("_home_phase"), max_fade, float(scene.get("_fade_a"))])
		fails += 1
		_finish()

func _finish() -> void:
	print("home_soft ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
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
