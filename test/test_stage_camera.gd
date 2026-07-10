extends SceneTree
## 舞台运镜（P8 打磨）：演出中镜头必须跟着戏走，收场后交还玩家。
## 老板第一次真机试演时看到的就是这个洞——旁白和横幅都有，村民走了，
## 但镜头一直锁在自己身上，戏在地图另一头演完了都不知道。
##
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_stage_camera.gd

var scene: Node
var frame := 0
var fails := 0
var _actor: Dictionary = {}
var _start_focus := Vector2.ZERO

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(640, 360)
		return
	if frame > 12:
		_tick_late()
		return
	if frame != 12:
		return

	# 纯函数先验：环面中点/中心不能跨接缝算到地图对面去
	var span := float(WorldGrid.GRID_TILES) * WorldGrid.TILE_SIZE
	var near_edge := Vector2(span - 2.0, 0.0)
	var past_edge := Vector2(2.0, 0.0)
	var mid: Vector2 = scene.call("torus_midpoint", near_edge, past_edge)
	_check("跨接缝中点绕近路（不是地图中央）", _wrapped_near(mid, Vector2(0.0, 0.0), 2.5), true)
	var cen: Vector2 = scene.call("torus_centroid", [near_edge, past_edge])
	_check("跨接缝中心与中点一致", _wrapped_near(cen, mid, 0.01), true)
	_check("单点的中心就是它自己", _wrapped_near(scene.call("torus_centroid", [Vector2(5, 7)]), Vector2(5, 7), 0.01), true)

	# 运镜态：reset/空 = 不接管；focus/overview/dialog = 接管
	scene.call("stage_camera", "overview", "", "")
	_check("overview 接管镜头", (scene.get("_stage_cam") as Dictionary).is_empty(), false)
	scene.call("stage_camera", "reset", "", "")
	_check("reset 交还镜头", (scene.get("_stage_cam") as Dictionary).is_empty(), true)

	# 演出中：镜头焦点必须离开玩家、跟到演员身上
	var npcs: Array = scene.get("npcs")
	if npcs.is_empty():
		printerr("  FAIL 世界里没有 NPC，测不了运镜")
		fails += 1
		_finish()
		return
	var actor: Dictionary = npcs[0]
	var actor_id := String(actor.get("id", ""))
	scene.call("stage_begin", [{ "id": actor_id, "name": "演员", "isPlayer": false }])
	scene.call("stage_camera", "focus", actor_id, "")
	var shot: Dictionary = scene.call("_stage_cam_shot")
	_check("focus 构图非空", shot.is_empty(), false)
	_check("focus 焦点落在演员身上", _wrapped_near(shot["want"], actor["logical"], 0.01), true)

	# overview 取全体演员中心：单演员时就是他本人
	scene.call("stage_camera", "overview", "", "")
	var ov: Dictionary = scene.call("_stage_cam_shot")
	_check("overview 焦点是演员中心", _wrapped_near(ov["want"], actor["logical"], 0.01), true)
	_check("overview 比特写拉得远", ov["dist"] > shot["dist"], true)

	# 找不到演员（还没降生/已离场）→ 返回空构图，镜头维持原样不抽搐
	scene.call("stage_camera", "focus", "查无此人", "")
	_check("演员不在场则不改构图", (scene.call("_stage_cam_shot") as Dictionary).is_empty(), true)

	# 把演员挪到离玩家很远处，再 focus 他——之后靠帧推进验真正的焦点迁移
	_actor = actor
	var player: Dictionary = scene.get("player")
	_check("玩家在场", player.is_empty(), false)
	_actor["logical"] = WorldGrid.wrap_pos(player["logical"] + Vector2(30.0, 0.0))
	_start_focus = scene.get("focus_logical")
	scene.call("stage_camera", "focus", actor_id, "")

func _tick_late() -> void:
	# 焦点缓动是逐帧插值：跑够帧数后镜头应已明显离开出发点、贴到演员身上。
	if frame == 45:
		var focus: Vector2 = scene.get("focus_logical")
		_check("镜头真的跟去了演员那边（不再赖在玩家身上）",
			_wrapped_near(focus, _actor["logical"], 6.0), true)
		_check("焦点确实动了（不是一直没挪）",
			WorldGrid.shortest_delta(focus, _start_focus).length() > 5.0, true)
		# 收场：镜头必须交还玩家，否则孩子以为卡死
		scene.call("stage_finish", {}, false, "")
		_check("收场交还镜头", (scene.get("_stage_cam") as Dictionary).is_empty(), true)
	elif frame == 58:
		var player: Dictionary = scene.get("player")
		_check("收场后镜头缓回玩家",
			_wrapped_near(scene.get("focus_logical"), player["logical"], 8.0), true)
		_finish()

func _finish() -> void:
	if fails == 0:
		print("stage_camera PASS")
	else:
		printerr("stage_camera FAILED: %d" % fails)
	quit(fails)

## 环面上两点是否足够近（跨接缝按最短路算）。
func _wrapped_near(a: Vector2, b: Vector2, eps: float) -> bool:
	return WorldGrid.shortest_delta(a, b).length() <= eps

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % what)
	else:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1
