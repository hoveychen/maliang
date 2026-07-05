extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：SDF 物件"摄影棚"近景截帧。
## 不加载世界——空场景一字排开五只物件（各自游走演出），定向光+固定近机位，
## 专看：融合面接缝是否消失/颜色软过渡宽度/描边贴合度/步态-跳跃-振翅-绳子。
## 运行: godot --write-movie screenshots/sdf/studio.png --fixed-fps 8 --quit-after 48 \
##       --script res://test/test_visual_sdf_studio_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误）。

const SPECS: Array[String] = [
	"res://assets/sdf_props/walking_hut.json",
	"res://assets/sdf_props/six_leg_chest.json",
	"res://assets/sdf_props/hop_mailbox.json",
	"res://assets/sdf_props/fly_lantern.json",
	"res://assets/sdf_props/sign_scout.json",
]

func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -30, 0)
	light.shadow_enabled = true
	world.add_child(light)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("#bfe3ef")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#cfd8e6")
	e.ambient_light_energy = 0.7
	env.environment = e
	world.add_child(env)

	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 20)
	floor_mesh.mesh = pm
	floor_mesh.material_override = BendMat.make(Color("#9fce84"))
	world.add_child(floor_mesh)

	var x := -8.0
	for path in SPECS:
		var prop := SdfProp.from_json_file(path)
		prop.position = Vector3(x, 0, 0)
		world.add_child(prop)
		prop.enable_wander(1.0, hash(path))
		x += 4.0

	var cam := Camera3D.new()
	cam.position = Vector3(0, 3.2, 9.5)
	cam.rotation_degrees = Vector3(-12, 0, 0)
	world.add_child(cam)
	cam.make_current()
