extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：真静止造物烘焙 swap 前后对照。
## 左=静物（会被 bake_and_swap_sync 换成静态 mesh）；右=风车（loco.none 但带 spin→保持 live 带描边，做对照）。
## 存两张 PNG：bake 前（两只都 live）/ bake 后（左静物已烘焙无描边、右风车仍 live 带描边）。
## 观察点：静物烘焙后 形状/颜色/位置是否保真、脚下暗斑是否补上、无描边是否可接受、右风车不受影响。
## 运行（须带窗，headless 截图段错误）:
##   /Applications/Godot.app/Contents/MacOS/Godot --path . --script res://test/test_visual_bake_shot.gd

const STATIC_SPEC := {
	"name": "quiet_mushroom",
	"palette": ["#e8b04b", "#c0562e"],
	"blend": 0.35,
	"parts": [
		{"shape": "box", "pos": [0, 0.35, 0], "size": [0.7, 0.7, 0.7], "color": 0},
		{"shape": "sphere", "pos": [0, 1.0, 0], "r": 0.55, "color": 1},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}
const SPIN_SPEC := {
	"name": "windmill",
	"palette": ["#e8b04b", "#4a7fb5"],
	"blend": 0.3,
	"parts": [
		{"shape": "box", "pos": [0, 1.0, 0], "size": [0.15, 1.4, 0.12], "color": 0, "spin": 1.2},
		{"shape": "box", "pos": [0, 1.0, 0], "size": [1.4, 0.15, 0.12], "color": 0, "spin": 1.2},
		{"shape": "sphere", "pos": [0, 0.35, 0], "r": 0.28, "color": 1},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}

var _static_prop: SdfProp
var _frame := 0
var _shot_dir := "res://screenshots/bake"

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(900, 500))
	var world := Node3D.new()
	root.add_child(world)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.86, 0.90, 0.82)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.68)
	env.ambient_light_energy = 0.8
	var wenv := WorldEnvironment.new()
	wenv.environment = env
	world.add_child(wenv)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	world.add_child(sun)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 2.4, 5.2)
	cam.rotation_degrees = Vector3(-18, 0, 0)
	world.add_child(cam)

	# 地面
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(12, 12)
	ground.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.72, 0.78, 0.62)
	ground.material_override = gmat
	world.add_child(ground)

	_static_prop = SdfProp.from_spec(STATIC_SPEC)
	_static_prop.position = Vector3(-1.4, 0, 0)
	world.add_child(_static_prop)

	var spin := SdfProp.from_spec(SPIN_SPEC)
	spin.position = Vector3(1.4, 0, 0)
	world.add_child(spin)

	process_frame.connect(_tick)

func _tick() -> void:
	_frame += 1
	# 先让 SDF 顶点吸附 + shader 稳定几帧，再截「bake 前」
	if _frame == 8:
		await RenderingServer.frame_post_draw
		_save("before")
	elif _frame == 10:
		# 只烘焙左侧静物；右侧风车 is_static=false 会原样返回 null（对照仍 live 带描边）
		var baker := root.get_node(^"SdfBakeSwap")
		var mi: MeshInstance3D = baker.bake_and_swap_sync(_static_prop)
		print("[bake] 静物 swap → ", mi, "  (null=没换,说明判成会动了)")
	elif _frame == 18:
		await RenderingServer.frame_post_draw
		_save("after")
		print("[shot] 存图完成，看 screenshots/bake/{before,after}.png")
		quit(0)

func _save(tag: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_shot_dir))
	var img := get_root().get_texture().get_image()
	img.save_png("%s/%s.png" % [_shot_dir, tag])
