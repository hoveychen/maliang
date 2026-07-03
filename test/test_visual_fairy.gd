extends SceneTree
## 小仙子随从的视觉+行为验证：离线世界里小仙子悬浮跟在玩家旁;
## 玩家点地走远后小仙子追上来;悬浮高度有上下浮动。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie screenshots/fairy/f.png \
##       --fixed-fps 10 --quit-after 90 --script res://test/test_visual_fairy.gd

var scene: Node
var frame := 0
var fails := 0
var hover_min := 99.0
var hover_max := -99.0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	var fairy: Dictionary = scene.call("_find_fairy")
	if not fairy.is_empty():
		var hov := float(fairy.get("hover", 0.0))
		hover_min = minf(hover_min, hov)
		hover_max = maxf(hover_max, hov)
	match frame:
		15:
			_check_near("initial follow", 8.0)
		20:
			var player: Dictionary = scene.get("player")
			var target := WorldGrid.wrap_pos((player["logical"] as Vector2) + Vector2(14.0, 10.0))
			scene.call("_move_player_to", target, 0.0)
		80:
			_check_near("caught up after walk", 8.0)
			_check("hover bobbing (min<max)", hover_max - hover_min > 0.2, true)
		82:
			# 点玩家自己 → 应进入与小仙子的对话
			var pnode: Node3D = (scene.get("player") as Dictionary)["node"]
			var cam: Camera3D = scene.get("camera")
			scene.call("_tap_pick", cam.unproject_position(pnode.global_position + Vector3(0.0, 1.6, 0.0)))
		96:
			var f2: Dictionary = scene.call("_find_fairy")
			_check("tap player talks to fairy", scene.get("selected") == f2.get("node"), true)
			_check("talk banner visible", (scene.get("banner") as Label).visible, true)
			if fails == 0:
				print("visual_fairy PASS")
			else:
				printerr("visual_fairy FAILED: %d" % fails)

func _check_near(name: String, max_dist: float) -> void:
	var fairy: Dictionary = scene.call("_find_fairy")
	var player: Dictionary = scene.get("player")
	if fairy.is_empty() or player.is_empty():
		fails += 1
		printerr("  FAIL %s: fairy or player missing" % name)
		return
	var dist := WorldGrid.shortest_delta(fairy["logical"], player["logical"]).length()
	_check("%s (dist=%.2f)" % [name, dist], dist <= max_dist, true)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
