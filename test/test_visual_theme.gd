extends SceneTree
## 主题地形独立渲染 QA harness（themed-terrain P3；不进 headless 回测，人工桌面 GPU 观感用）。
## 绕开 main.tscn（其启动流程会覆盖注入的 TerrainMap，test_visual_seafloor 式注入已失效）：
## 直接建 光 + 相机 + ChunkManager，注入 THEME 指定的种子场景地形并逐帧铺块，第 130 帧截图。
## bend 曲率把世界卷成穹顶（游戏真实观感），故截图上半为天、地形+类型化崖壁在下半。
## 用法（带窗，非 headless）：
##   THEME=icesnow FOCUS=47,30 PITCH=38 DIST=14 SHOT=/abs/out.png \
##     /Applications/Godot.app/Contents/MacOS/Godot --path . --script res://test/test_visual_theme.gd
## THEME ∈ 见下方 exporters；FOCUS=tile x,z（相机看向该 tile，缺省 45,33）；PITCH/DIST 相机俯仰/距离。
var _f := 0
var _shot := false
var cm
func _initialize() -> void:
	var theme := OS.get_environment("THEME")
	var exporters := {
		"icesnow":"res://tools/export_icesnow.gd","jurassic":"res://tools/export_jurassic.gd",
		"medieval":"res://tools/export_medieval.gd","roman":"res://tools/export_roman.gd",
		"ancient_china":"res://tools/export_ancient_china.gd","modern_city":"res://tools/export_modern_city.gd",
		"toy_room":"res://tools/export_toy_room.gd","kitchen":"res://tools/export_kitchen.gd",
		"hospital":"res://tools/export_hospital.gd","future_robot":"res://tools/export_future_robot.gd",
		"seafloor":"res://tools/export_seafloor.gd",
	}
	var ex = load(exporters[theme])
	ItemCatalog.ensure_builtin()
	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(ex.build_terrain_bytes())
	if not r["ok"]:
		printerr("注入失败 ", theme, ": ", r.get("error","")); quit(1); return
	# 光
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0,-40.0,0.0)
	light.light_color = Color(1.0,0.96,0.86); light.light_energy = 1.25
	root.add_child(light)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.7,0.82,0.92)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6,0.62,0.66); e.ambient_light_energy = 1.0
	env.environment = e; root.add_child(env)
	# 地形
	cm = ChunkManager.new(); root.add_child(cm)
	# 相机：pitch 47°, dist 23, 看渲染原点（focus 处地形铺到原点）
	var camera := Camera3D.new(); camera.fov = 50.0; camera.far = 900.0
	var pitch := deg_to_rad(float(OS.get_environment("PITCH") if OS.get_environment("PITCH")!="" else "44"))
	var dist := float(OS.get_environment("DIST") if OS.get_environment("DIST")!="" else "19")
	camera.position = Vector3(0.0, sin(pitch)*dist, cos(pitch)*dist)
	root.add_child(camera)
	# AIMY：看向点的 y 偏移（默认 0=看渲染原点）。bend 曲率把远处地形卷成穹顶下沉，
	# 取负值让相机多向下看、把 focus 处的地块从画面底部提到中央（QA 取景用，不影响观感判断）。
	var aim_y := float(OS.get_environment("AIMY")) if OS.get_environment("AIMY")!="" else 0.0
	camera.look_at(Vector3(0.0, aim_y, 0.0), Vector3.UP)
	var fp := OS.get_environment("FOCUS"); var ft := Vector2i(45,33)
	if fp != "": ft = Vector2i(int(fp.split(",")[0]), int(fp.split(",")[1]))
	var focus := TerrainMap.tile_center(ft)
	cm.rebuild()
	set_meta("focus", focus)
	process_frame.connect(_on_frame)
	print("注入 ", theme, " 完成，铺块…")
func _on_frame() -> void:
	_f += 1
	cm.update(get_meta("focus"))
	if _f < 130 or _shot: return
	_shot = true
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var out := OS.get_environment("SHOT")
	img.save_png(out)
	print("截图 ", out, " ", img.get_size()); quit(0)
