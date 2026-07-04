extends SceneTree
## 相机台阶高度跟随回归：玩家站上高阶地形后，相机焦点必须一起升高。
## 修复前焦点固定 y=0，玩家上到 7、8 级台地（y=14~16m）就投影到画面顶端之外。
## 断言：平地基线 + 传送到 8 级演示山顶后，玩家都应投影在画面中央带。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 80 --script res://test/test_visual_camera_height.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		# headless 假视口 64×64，强制与带窗一致（见 test_visual_click_move 注释）
		root.size = Vector2i(1280, 720)
	match frame:
		15:
			_check_player_band("平地（村庄）")
			_teleport_to_mountain()
		70:
			_check_player_band("8级山顶")
			if fails == 0:
				print("visual_camera_height PASS")
			else:
				printerr("visual_camera_height FAILED: %d" % fails)
			quit(fails)

## 把玩家直接放到北部演示山 8 级台地中心（tile 37,6 高度 8），相机应随焦点缓动跟上。
func _teleport_to_mountain() -> void:
	var top := TerrainMap.tile_center(Vector2i(37, 6))
	var h := TerrainMap.tile_height(Vector2i(37, 6))
	_check("传送目标确为高阶台地 (h=%d)" % h, h >= 7, true)
	var player: Dictionary = scene.get("player")
	player["logical"] = top
	OccupancyMap.char_register(player["id"], top, player["span"])

## 玩家（相机跟随对象）应在相机前方、且投影落在画面中央带 [0.25, 0.85]。
func _check_player_band(label: String) -> void:
	var player: Dictionary = scene.get("player")
	var cam: Camera3D = scene.get("camera")
	var node: Node3D = player["node"]
	var wp: Vector3 = node.global_position + Vector3(0.0, 1.0, 0.0)
	var behind := cam.is_position_behind(wp)
	_check("%s: 玩家在相机前方" % label, not behind, true)
	if behind:
		return
	var sp := cam.unproject_position(wp)
	var vy := sp.y / float(root.size.y)
	_check("%s: 玩家投影在画面中央带 (vy=%.2f)" % [label, vy], vy >= 0.25 and vy <= 0.85, true)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
