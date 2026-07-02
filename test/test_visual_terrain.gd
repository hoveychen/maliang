extends SceneTree
## 临时视觉验证：把 god 视角焦点挪到指定 tile，配合 --write-movie 截帧。
## 运行: godot --write-movie screenshots/frame.png --fixed-fps 2 --quit-after 6 --script res://test/test_visual_terrain.gd
## 环境变量 FOCUS_TILE="x,z" 指定聚焦 tile（默认 37,37 中央广场）。

func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var spec := OS.get_environment("FOCUS_TILE")
	var t := Vector2i(37, 37)
	if spec != "":
		var parts := spec.split(",")
		t = Vector2i(int(parts[0]), int(parts[1]))
	scene.set("focus_logical", TerrainMap.tile_center(t))
