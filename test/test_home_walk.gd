extends SceneTree
## 回家「走进/走出」P3（home-portal-anim）：_step_home_walk 把玩家从 _home_from smoothstep 到 _home_to。
## 关键点：不设 _hop 标志——_update_paper_motion 的 _hop 分支会冻结位移、压掉 walk_bob；走正常分支才有踏步。
## 断言：沿路推进(不瞬移)、paper_walk>0(踏步真的触发)、不带 _hop、到位落在终点。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 40 \
##       --script res://test/test_home_walk.gd

const FROM := Vector2i(5, 5)
const TO := Vector2i(9, 5)   ## 同排横向 4 格：vel.x 明显，也顺带验证走路

var scene: Node
var frame := 0
var fails := 0
var from_pos: Vector2
var to_pos: Vector2
var full_dist := 0.0
var arrived := false
var arrive_frame := -1
var saw_walk := false

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(640, 480)
		scene.set("online", false)
		return
	if frame == 10:
		var p: Dictionary = scene.get("player")
		if p.is_empty():
			printerr("  ✗ 没有玩家节点"); fails += 1; _finish(); return
		from_pos = WorldGrid.from_tile_center(FROM)
		to_pos = WorldGrid.from_tile_center(TO)
		full_dist = WorldGrid.shortest_delta(from_pos, to_pos).length()
		p["logical"] = from_pos
		p["paper_prev"] = from_pos   # 防上一位置残留被当成一帧巨速误触走路
		p.erase("_hop")
		p["paper_walk"] = 0.0
		scene.set("_home_from", from_pos)
		scene.set("_home_to", to_pos)
		scene.set("_home_t", 0.0)
		return
	if frame > 10 and not arrived:
		var done: bool = scene.call("_step_home_walk", 0.1)
		var p: Dictionary = scene.get("player")
		# 走路量攒起来（踏步触发的证据）：任一帧 >0 即算见到
		if float(p.get("paper_walk", 0.0)) > 0.0:
			saw_walk = true
		# 不得设 _hop（否则 walk_bob 被冻结）
		if bool(p.get("_hop", false)):
			printerr("  ✗ 走进期间被设了 _hop（会压掉踏步）"); fails += 1
		if done:
			arrived = true
			arrive_frame = frame
			var landed: Vector2 = p["logical"]
			_check_near("到位落在终点", WorldGrid.shortest_delta(landed, to_pos).length(), 0.0, 0.01)
		elif frame == 13:
			# 走了两三帧：应已推进但还没到（不是瞬移）
			var moved: Vector2 = p["logical"]
			var d_from := WorldGrid.shortest_delta(from_pos, moved).length()
			_check("已离开起点(在走)", d_from > 0.01, true)
			_check("尚未瞬移到终点(沿路走)", d_from < full_dist - 0.01, true)
		return
	if arrived and frame >= arrive_frame + 2:
		_check("走进途中见到 paper_walk>0（踏步触发）", saw_walk, true)
		# HOME_WALK_DUR=0.55s / 0.1s每帧 → 约 6 帧到位；给宽松窗
		_check("到位帧数合理(约6帧)", arrive_frame - 10 >= 5 and arrive_frame - 10 <= 8, true)
		_finish()

func _finish() -> void:
	print("home_walk ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	if is_instance_valid(scene):
		scene.queue_free()
	scene = null
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok ", name)
	else:
		printerr("  ✗ %s: got %s, want %s" % [name, got, want]); fails += 1

func _check_near(name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) <= tol:
		print("  ok ", name)
	else:
		printerr("  ✗ %s: got %f, want %f (±%f)" % [name, got, want, tol]); fails += 1
