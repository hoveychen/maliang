extends SceneTree
## 临时视觉验证（无断言，只服务人眼 QA，不进 test-headless.sh）：
## 开演 → 参演角色脚下的金色光环是否平躺贴地、与 BlobShadow 不打架、全景是否框住所有人。
## 运行（要带窗，headless 下 --write-movie 会段错误）：
##   MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie screenshots/ring.png \
##     --fixed-fps 2 --quit-after 10 --script res://test/test_visual_stage_ring.gd

var scene: Node
var frame := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame != 3:
		return
	var npcs: Array = scene.get("npcs")
	var actors: Array = []
	for n in npcs:
		actors.append({ "id": String(n.get("id", "")), "name": (n["node"] as PaperCharacter).char_name, "isPlayer": false })
	scene.call("stage_begin", actors)
	scene.call("stage_camera", "overview", "", "")
