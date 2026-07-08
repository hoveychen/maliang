extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：设置页「换形象」布局截帧。
## 编排（--fixed-fps 8）：开收集册 → 切设置页（重新捏角色 + 换形象两按钮）→
## 点换形象（假 API，按钮禁用态）→ 手动铺预览区（占位图 + ✓/✗）看布局。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie <目录>/f.png \
##       --fixed-fps 8 --quit-after 70 --script res://test/test_visual_avatar_regen_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	match frame:
		8:
			(scene.get("album_button") as Button).emit_signal("pressed")
		16:
			((scene.get("_album_tab_buttons") as Dictionary)["settings"] as Button).emit_signal("pressed")
		28:
			(scene.get("_avatar_btn") as Button).emit_signal("pressed") # 假 API：观察禁用态
		40:
			# 手动铺预览（占位用小仙子图）：QA 预览图 + ✓/✗ 行布局
			var img := scene.get("_avatar_img") as TextureRect
			img.texture = load("res://assets/fairy.png")
			(scene.get("_avatar_preview") as Control).visible = true
		64:
			quit(0)
