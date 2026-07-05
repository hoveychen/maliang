extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：纸片角色演出截帧。
## 编排（--fixed-fps 8，共 10s）：0-2.5s 向左走（摇摆+下摆飘动+翻面朝左）→
## 2.5-5s 向右走（换向翻面，中途侧身纸边）→ 5-10s 待机（呼吸微卷）。
## 环境变量：PITCH/DIST 调相机（如 PITCH=30 DIST=14 近景）。
## 运行: godot --write-movie <目录>/paper.png --fixed-fps 8 --quit-after 80 \
##       --script res://test/test_visual_paper_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

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
	if frame == 1:
		player["logical"] = TerrainMap.tile_center(Vector2i(37, 37)) # 传送到村庄广场空地取景
		var sprite_path := OS.get_environment("SPRITE_PATH")
		if sprite_path != "": # 换上生成的贴纸立绘（QA 白边黑框+朝右在世界里的观感）
			var img := Image.load_from_file(sprite_path)
			var tex := ImageTexture.create_from_image(img)
			var node: PaperCharacter = player["node"]
			node.texture = tex
			node.pixel_size = 5.0 / float(tex.get_height())
			node.offset = Vector2(0.0, float(tex.get_height()) / 2.0)
			node.modulate = Color.WHITE
		return
	var step := Vector2.ZERO
	if frame <= 7:
		step = Vector2(-1.0, 0.0) # 8 m/s @ 8fps 向左（广场西侧 6m 内无遮挡）
	elif frame <= 19:
		step = Vector2(1.0, 0.0)  # 换向向右（翻面），回到广场东侧
	if step != Vector2.ZERO:
		player["logical"] = WorldGrid.wrap_pos(player["logical"] + step)
