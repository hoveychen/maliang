extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：动态天空盒截帧。
## 默认 god 视角村庄中央；环境变量：
##   PITCH/DIST  模拟 lock 近身视角（如 PITCH=30 DIST=20，天空占比更大）
##   WIND_X      放大云漂移速度（如 0.08，10 秒内肉眼可见云移动，验证"动态"）
## 运行: godot --write-movie screenshots/sky.png --fixed-fps 2 --quit-after 10 \
##       --script res://test/test_visual_sky_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var t := Vector2i(37, 37)
	var spec := OS.get_environment("FOCUS_TILE")
	if spec != "":
		var parts := spec.split(",")
		t = Vector2i(int(parts[0]), int(parts[1]))
	scene.set("focus_logical", TerrainMap.tile_center(t))
	var pitch := OS.get_environment("PITCH")
	if pitch != "":
		scene.set("_target_pitch", float(pitch))
	var dist := OS.get_environment("DIST")
	if dist != "":
		scene.set("_target_dist", float(dist))
	var wind := OS.get_environment("WIND_X")
	if wind != "":
		scene.ready.connect(func() -> void:
			var env: Environment = scene.get("_env")
			var mat := env.sky.sky_material as ShaderMaterial
			mat.set_shader_parameter("wind", Vector2(float(wind), float(wind) * 0.25)))
