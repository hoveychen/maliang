extends SceneTree
## 占位符外观的人眼 QA（无断言，不进 scripts/test-headless.sh）：把传送门和魔法熔炉并排摆出来截一张图。
## 几何约束由 test_placeholder_specs 守；「看着像不像」只能靠眼睛。
## 运行（要带窗，headless 的假视口出不了图）：
##   /Applications/Godot.app/Contents/MacOS/Godot --path . --script res://test/test_visual_placeholders.gd
## 产物：screenshots/placeholders.png

var frame := 0

func _initialize() -> void:
	root.size = Vector2i(1280, 720)
	var world := Node3D.new()
	root.add_child(world)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.86, 0.90, 0.84)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.9, 0.9, 0.95)
	e.ambient_light_energy = 0.8
	env.environment = e
	world.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -35, 0)
	world.add_child(sun)

	var portal := SdfProp.from_spec(PlaceholderSpecs.PORTAL)
	portal.position = Vector3(-1.1, 0, 0)
	world.add_child(portal)

	var forge := SdfProp.from_spec(PlaceholderSpecs.FORGE)
	forge.position = Vector3(1.1, 0, 0)
	world.add_child(forge)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.15, 3.4)
	cam.rotation_degrees = Vector3(-8, 0, 0)
	cam.current = true
	world.add_child(cam)

	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame < 30:
		return # 等 shader 编译 + 首帧稳定
	var img := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://screenshots")
	img.save_png("res://screenshots/placeholders.png")
	print("saved screenshots/placeholders.png")
	quit(0)
