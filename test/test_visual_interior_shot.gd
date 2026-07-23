extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：boot 直接进某室内，看新相机（放平俯角 + 按房间尺寸框满）
## 与缩小后的房间/家具观感。场景由 MALIANG_BOOT_SCENE 指定（world._ready 读它）。
## 运行(带窗，--write-movie 须带窗)：
##   MALIANG_API_BASE=http://127.0.0.1:1 MALIANG_BOOT_SCENE=villager_home_1_interior \
##   /Applications/Godot.app/Contents/MacOS/Godot --write-movie <目录>/f.png \
##   --fixed-fps 12 --quit-after 80 --script res://test/test_visual_interior_shot.gd
## 注意：不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0

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
	if frame >= 78:
		quit(0)
