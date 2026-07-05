extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：SDF 可动物件截帧。
## 编排（--fixed-fps 8）：依次传送到五只物件旁各停 3s——
## 小花(3,4) → 风车(40,40) → 纸+蜡笔(33-34,34) → 路牌(36,24) → 走路小屋(24,47)。
## 观察点：接缝是否消失/颜色软过渡/描边贴不贴/步态与绳子演出。
## 环境变量：PITCH/DIST 调相机（近景建议 PITCH=25 DIST=10）；FOCUS_TILE="x,z" 只看一处。
## 运行: godot --write-movie screenshots/sdf/sdf.png --fixed-fps 8 --quit-after 125 \
##       --script res://test/test_visual_sdf_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

const STOPS: Array[Vector2i] = [
	Vector2i(4, 6),    # 小花(出生空地)
	Vector2i(41, 42),  # 风车(广场东南)
	Vector2i(34, 36),  # 纸+蜡笔(村核心)
	Vector2i(37, 26),  # 路牌(北路旁)
	Vector2i(26, 50),  # 走路小屋(留档对照)
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
