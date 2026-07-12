extends SceneTree
## 临时视觉验证（themed-terrain P2，不进回测）：把主场景地形换成海底切片，
## 驱动若干帧让 9 区块铺完，抓 viewport 存 PNG——桌面 GPU 确认 shader 能编译、
## 6 种海底贴图正确上色、礁岩/粗沙抬高块出各自侧壁。真机（老 Mali）观感另测。
## 运行（带窗，非 headless）：
##   godot --path . --script res://test/test_visual_seafloor.gd
## 环境变量 SHOT_OUT 指定输出 PNG（默认 screenshots/seafloor.png）；
## FOCUS_TILE="x,z" 聚焦 tile（默认 50,28 礁石群）。

const SEAFLOOR := preload("res://tools/export_seafloor.gd")

var _scene: Node
var _frames := 0
var _shot := false

func _initialize() -> void:
	_scene = load("res://main.tscn").instantiate()
	root.add_child(_scene)
	var spec := OS.get_environment("FOCUS_TILE")
	var t := Vector2i(50, 28)
	if spec != "":
		var p := spec.split(",")
		t = Vector2i(int(p[0]), int(p[1]))
	_scene.set("focus_logical", TerrainMap.tile_center(t))
	_scene.ready.connect(func() -> void:
		# 主场景 boot 后强制换海底地形并整图重铺
		var r: Dictionary = TerrainMap.load_from_bytes(SEAFLOOR.build_terrain_bytes())
		if not r["ok"]:
			printerr("海底地形注入失败：", r.get("error", ""))
			quit(1)
			return
		var cm = _scene.get("chunk_manager")
		if cm == null:
			printerr("拿不到 chunk_manager")
			quit(1)
			return
		cm.rebuild()
		print("海底地形已注入，开始铺块…"))
	process_frame.connect(_on_frame)

func _on_frame() -> void:
	_frames += 1
	# 给足帧数让 9 区块逐帧铺完（真机单块 80-200ms，桌面快得多）
	if _frames < 150 or _shot:
		return
	_shot = true
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var out := OS.get_environment("SHOT_OUT")
	if out == "":
		out = "screenshots/seafloor.png"
	var err := img.save_png(out)
	print("截图 ", out, " err=", err, " size=", img.get_size())
	quit(0)
