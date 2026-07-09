extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：手机视图改造后截帧——
## 手机贴右侧 90% 高、近身相机把玩家推到屏左、桌面 widget、3x3 图标、状态栏时间+信号。
## 编排（--fixed-fps 8）：1s 打开手机（触发近身相机 zoom+焦点右移）→ 等相机缓动收敛 → 截帧。
## 运行: godot --write-movie <目录>/f.png --fixed-fps 8 --quit-after 90 \
##       --script res://test/test_visual_phone_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 8:
		(scene.get("album_button") as Button).emit_signal("pressed") # 开手机→近身相机

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)
