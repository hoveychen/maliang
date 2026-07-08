extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：进世界加载过场观感。
## 编排（--fixed-fps 8）：起 loading.tscn（next_scene=main）→ 品牌遮罩(水彩背景+飘动
## 小仙子+三点脉动)盖住世界首屏铺设 → world_ready 后淡出交还世界。抓整段弧线。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie <目录>/f.png \
##       --fixed-fps 8 --quit-after 40 --script res://test/test_visual_loading_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

var frame := 0

func _initialize() -> void:
	Loading.next_scene = "res://main.tscn"
	root.add_child(load("res://loading.tscn").instantiate())
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame >= 40:
		quit(0)
