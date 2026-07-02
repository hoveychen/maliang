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
	# NPC_TILE="x,z"：把第一只占位 NPC 挪到指定 tile（验证高度跟随）。
	# 注意：_initialize 阶段子节点 _ready 未跑、npcs 还是空的，须等 ready 信号后注入。
	var nspec := OS.get_environment("NPC_TILE")
	if nspec != "":
		var np := nspec.split(",")
		var nt := Vector2i(int(np[0]), int(np[1]))
		scene.ready.connect(func() -> void:
			var npcs: Array = scene.get("npcs")
			if npcs.is_empty():
				printerr("NPC_TILE: npcs empty after ready")
				return
			npcs[0]["logical"] = TerrainMap.tile_center(nt))
