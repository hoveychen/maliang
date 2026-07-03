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
