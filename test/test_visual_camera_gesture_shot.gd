extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：双指手势临时视角截帧。
## 编排（--fixed-fps 8）：1s 村庄广场默认视角 → 2s 捏合张开拉近 → 4s 双指右移环绕
## （看世界从其他方位渲染、纸片仍面向相机）→ 7s 双指下移压平俯仰 → 9s 松手 →
## 14s 起 5s 倒计时到点自动复原 → 17s 回默认正北视角，结束。
## 运行: godot --write-movie <目录>/f.png --fixed-fps 8 --quit-after 150 \
##       --script res://test/test_visual_camera_gesture_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

const F0 := Vector2(520.0, 360.0)  ## 双指初始位置（1152×648 默认窗口内）
const F1 := Vector2(720.0, 360.0)

var scene: Node
var frame := 0
var p0 := F0
var p1 := F1

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	frame += 1
	if frame == 1:
		_teleport(player, Vector2i(37, 37)) # 村庄广场取景
		(scene.get("heard_label") as Label).visible = false
		(scene.get("banner") as Label).visible = false
		return
	if frame == 8:
		_touch(0, p0, true)
		_touch(1, p1, true)
	elif frame > 8 and frame <= 24: # 捏合张开：每帧各外移 6px，拉近
		p0 += Vector2(-6.0, 0.0)
		p1 += Vector2(6.0, 0.0)
		_drag_both()
	elif frame > 32 and frame <= 56: # 双指右移：环绕（~0.005rad/px*3px*24帧*2指/2≈0.36rad/…可见转动）
		p0 += Vector2(10.0, 0.0)
		p1 += Vector2(10.0, 0.0)
		_drag_both()
	elif frame > 56 and frame <= 72: # 双指下移：压平俯仰
		p0 += Vector2(0.0, 8.0)
		p1 += Vector2(0.0, 8.0)
		_drag_both()
	elif frame == 73: # 松手，5s 倒计时开始
		_touch(0, p0, false)
		_touch(1, p1, false)
	# 73+40(5s)=113 帧倒计时到点，随后 ~1s 缓动复原；录到 145 帧留足余量

func _drag_both() -> void:
	var e0 := InputEventScreenDrag.new()
	e0.index = 0
	e0.position = p0
	scene.call("_unhandled_input", e0)
	var e1 := InputEventScreenDrag.new()
	e1.index = 1
	e1.position = p1
	scene.call("_unhandled_input", e1)

func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = pressed
	scene.call("_unhandled_input", ev)

func _teleport(d: Dictionary, tile: Vector2i) -> void:
	var pos := TerrainMap.tile_center(tile)
	d["logical"] = pos
	OccupancyMap.char_register(String(d.get("id", "")), pos, int(d.get("span", 2)))
