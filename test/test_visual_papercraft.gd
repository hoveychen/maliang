extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：纸艺风运行时切换。
## 前半程默认水彩风，第 4 帧走真实运行时路径（world._apply_graphics_key "papercraft"）
## 切开——后半帧应看到已在场的物品/地形/水面全部变纸（活材质注册表生效的目视证据）。
## 运行: godot --write-movie screenshots/frame.png --fixed-fps 2 --quit-after 8 \
##       --script res://test/test_visual_papercraft.gd
## 环境变量 FOCUS_TILE="x,z" 同 test_visual_terrain。

var _scene: Node
var _frame := 0

func _initialize() -> void:
	_scene = load("res://main.tscn").instantiate()
	root.add_child(_scene)
	var spec := OS.get_environment("FOCUS_TILE")
	var t := Vector2i(37, 37)
	if spec != "":
		var parts := spec.split(",")
		t = Vector2i(int(parts[0]), int(parts[1]))
	_scene.set("focus_logical", TerrainMap.tile_center(t))
	process_frame.connect(_tick)

func _tick() -> void:
	_frame += 1
	if _frame == 4:
		_scene.call("_apply_graphics_key", "papercraft", 1)
