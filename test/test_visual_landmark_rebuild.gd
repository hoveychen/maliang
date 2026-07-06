extends SceneTree
## 回归：角色站在地标占地内时，区块（重）建不得吞掉地标。
## 复现方式 = 把出生焦点设在风车丘顶（玩家因此出生在风车 3×3 占地里）：
## 修复前 prop_area_ok 连角色层一起查，摆放被玩家挡掉 → 风车消失、散布石补位；
## 修复后确定性重摆（LANDMARKS/散布/SDF 表）只查 prop 层+地形，风车必在。
## 同时守住反向不变量：语音造物等「运行时新摆放」仍要避开角色（默认 check_chars）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_visual_landmark_rebuild.gd

const WINDMILL_TILE := Vector2i(59, 54)

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	# 出生焦点设到风车丘顶 → 玩家出生在风车占地内（复现条件）
	scene.set("focus_logical", TerrainMap.tile_center(WINDMILL_TILE))
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame != 15:
		return
	var windmills := 0
	for n in root.find_children("*", "Node3D", true, false):
		if n.name.begins_with("building_windmill"):
			windmills += 1
	_check("玩家站占地内时风车仍在", windmills > 0, true)

	# 反向不变量：运行时新摆放默认仍避开角色
	var t := WINDMILL_TILE + Vector2i(0, 8) # 丘外平地
	OccupancyMap.char_register("test_npc", TerrainMap.tile_center(t), 2)
	_check("角色占位挡运行时新摆放（默认查角色层）",
		OccupancyMap.prop_area_ok(t, 1, 1), false)
	_check("确定性重摆无视角色层（check_chars=false）",
		OccupancyMap.prop_area_ok(t, 1, 1, false, false), true)
	OccupancyMap.char_unregister("test_npc")

	if fails == 0:
		print("visual_landmark_rebuild PASS")
	else:
		printerr("visual_landmark_rebuild FAILED: %d" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1
