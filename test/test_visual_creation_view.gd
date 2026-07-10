extends SceneTree
## 创造视图人眼 QA（带窗，无断言）：进与仙子的交互 → 驱动一轮 creation_prompt → 截图看
## 特写构图 + 暗底 + 居中 2×2 大卡是否像方案 A。
## 运行: /Applications/Godot.app/Contents/MacOS/Godot --path . --script res://test/test_visual_creation_view.gd
## 产物：screenshots/creation_view.png

var scene: Node
var frame := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	root.size = Vector2i(1280, 720)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame == 20:
		var fairy: Dictionary = scene.call("_find_fairy")
		if not fairy.is_empty():
			scene.call("_enter_interaction", fairy["node"])
	if frame == 40:
		scene.call("_on_creation_prompt", {
			"replyText": "它是什么颜色的呀？", "question": "它是什么颜色的呀？", "category": "color",
			"options": [
				{ "id": "red", "label": "红", "iconAsset": "" },
				{ "id": "yellow", "label": "黄", "iconAsset": "" },
				{ "id": "blue", "label": "蓝", "iconAsset": "" },
				{ "id": "green", "label": "绿", "iconAsset": "" },
			],
			"ttsAsset": "", "voiceId": "",
		})
	if frame == 70: # 等相机推近缓动到位
		var img := root.get_texture().get_image()
		DirAccess.make_dir_recursive_absolute("res://screenshots")
		img.save_png("res://screenshots/creation_view.png")
		print("saved screenshots/creation_view.png")
		quit(0)
