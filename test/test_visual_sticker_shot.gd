extends SceneTree
## 临时视觉验证(不进回测): tile 边缘贴纸在世界里的观感——玩家脚边四条边各贴一张,
## 台阶立面再贴一张（验证崖壁贴法）。
## 带窗跑:
##   MALIANG_API_BASE=http://127.0.0.1:1 godot --path . --quit-after 40 \
##     --script res://test/test_visual_sticker_shot.gd
## 输出 /tmp/sticker_shot.png。

var scene: Node
var frame := 0

func _initialize() -> void:
	seed(7)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.set("_target_dist", 10.0)
	scene.set("_target_pitch", 22.0)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	frame += 1
	if frame == 1:
		player["logical"] = TerrainMap.tile_center(Vector2i(37, 37))
		return
	if frame == 3:
		# 广场脚边:同 tile 四条边各贴一张 + 邻 tile 补两张(密一点好看清)
		var pal_n := TerrainMap.palette().size()
		var p: Dictionary = TerrainMap.apply_patch({
			"paletteAppend": [
				{ "index": pal_n + 1, "itemId": "sticker_sun" },
				{ "index": pal_n + 2, "itemId": "sticker_heart" },
				{ "index": pal_n + 3, "itemId": "sticker_star" },
				{ "index": pal_n + 4, "itemId": "sticker_mushroom" },
				{ "index": pal_n + 5, "itemId": "sticker_rainbow" },
				{ "index": pal_n + 6, "itemId": "sticker_butterfly" },
			],
			"edits": [
				{ "x": 37, "y": 38, "edge": [TerrainMap.EDGE_S, pal_n + 1] },
				{ "x": 37, "y": 38, "edge": [TerrainMap.EDGE_E, pal_n + 2] },
				{ "x": 36, "y": 38, "edge": [TerrainMap.EDGE_S, pal_n + 3] },
				{ "x": 38, "y": 38, "edge": [TerrainMap.EDGE_S, pal_n + 4] },
				{ "x": 36, "y": 38, "edge": [TerrainMap.EDGE_W, pal_n + 5] },
				# 主峰南麓台阶(37,14 一带高度落差):崖壁贴法
				{ "x": 37, "y": 15, "edge": [TerrainMap.EDGE_S, pal_n + 6] },
			],
		})
		print("[sticker] patch ok=", p["ok"], " err=", p.get("error", ""))
		var cm: Node = scene.get("chunk_manager")
		if cm != null:
			cm.rebuild_tiles(p["tiles"])
		return
	if frame == 20:
		var img := root.get_viewport().get_texture().get_image()
		img.save_png("/tmp/sticker_shot.png")
		print("[sticker] saved /tmp/sticker_shot.png")
		scene = null
		quit(0)
