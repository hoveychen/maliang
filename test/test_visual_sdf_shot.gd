extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：SDF 可动物件截帧。
## 编排（--fixed-fps 8）：依次传送到五只物件旁各停 3s——
## 走路小屋(24,47) → 蹦蹦邮筒(41,34) → 飞灯笼(27,27) → 六足宝箱(60,44) → 双足路牌(35,22)。
## 观察点：接缝是否消失/颜色软过渡/描边贴不贴/步态与绳子演出。
## 环境变量：PITCH/DIST 调相机（近景建议 PITCH=25 DIST=10）；FOCUS_TILE="x,z" 只看一处。
## 运行: godot --write-movie screenshots/sdf/sdf.png --fixed-fps 8 --quit-after 125 \
##       --script res://test/test_visual_sdf_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

const STOPS: Array[Vector2i] = [
	Vector2i(26, 50),  # 物件锚点东南 2-3 tile：错开玩家占屏中心，相机朝北看得到物件
	Vector2i(43, 37),
	Vector2i(29, 30),
	Vector2i(62, 47),
	Vector2i(37, 25),
]
const FRAMES_PER_STOP := 24  # 3s @ 8fps

var scene: Node
var frame := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var pitch := OS.get_environment("PITCH")
	if pitch != "":
		scene.set("_target_pitch", float(pitch))
	var dist := OS.get_environment("DIST")
	if dist != "":
		scene.set("_target_dist", float(dist))
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	frame += 1
	var focus := OS.get_environment("FOCUS_TILE")
	if focus != "":
		if frame == 1:
			var parts := focus.split(",")
			player["logical"] = TerrainMap.tile_center(Vector2i(int(parts[0]), int(parts[1])))
		return
	var stop_i := (frame - 1) / FRAMES_PER_STOP
	if stop_i >= STOPS.size():
		return
	if (frame - 1) % FRAMES_PER_STOP == 0:
		player["logical"] = TerrainMap.tile_center(STOPS[stop_i])
