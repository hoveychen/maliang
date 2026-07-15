extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：回家传送门过场同场景软过场——
## 召门(从地下升起) → 走进 → 黑幕(水彩+仙子 loading) → 揭幕 → 从门里走出 → 门沉下消散。
## 运行(带窗，headless --write-movie 会段错误): /Applications/Godot.app/Contents/MacOS/Godot \
##   --write-movie <目录>/f.png --fixed-fps 12 --quit-after 120 --script res://test/test_visual_home_shot.gd
## 注意：--write-movie 须带窗跑，且不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0
var fired := false

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		scene.set("online", false)
		return
	# 世界就绪、玩家挪离原点，便于看清"传送回原点"
	if frame == 24:
		var p: Dictionary = scene.get("player")
		if not p.is_empty():
			p["logical"] = WorldGrid.from_tile_center(Vector2i(18, 18))
			scene.set("focus_logical", p["logical"])
		return
	if frame == 30 and not fired:
		fired = true
		scene.call("_go_home") # 同场景 → 软过场完整动画
		return
	if frame >= 118:
		quit(0)
