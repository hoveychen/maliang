extends SceneTree
## 本地 SDF prop 预览渲染（P2/P3/P4 观感 QA 用；不依赖服务端）。
## 把一个 sdf_props/<id>.json 用游戏真实 SdfProp 渲染管线（复用 item_icon_capture 的离屏舞台
## + 自动取景），出一张斜俯 45° hero PNG 到磁盘，供目视确认「像不像目标物」。
##
## ⚠️ 必须带窗跑（不要 --headless）：SDF 靠 GPU 逐帧把顶点吸附到隐式面，headless 假视口渲染空/冻结帧。
## 用法：
##   /Applications/Godot.app/Contents/MacOS/Godot --path . --script res://tools/sdf_preview.gd \
##     -- --json corn_stalk --out /tmp/corn.png --quit-after 200
## 多角度：--azim 30（默认）可改；--elev 45（默认）。

const VP_SIZE := 480
const SETTLE_FRAMES := 12
const FIT_MARGIN := 1.25
const FIT_PASSES := 6
const FIT_TARGET := 0.5

var _vp: SubViewport
var _cam: Camera3D
var _stage: Node3D
var _elev := 45.0
var _azim := 30.0

func _initialize() -> void:
	_build_stage()
	_run()

func _arg(flag: String, dflt: String) -> String:
	var a := OS.get_cmdline_user_args()
	for i in range(a.size()):
		if a[i] == flag and i + 1 < a.size():
			return a[i + 1]
	return dflt

func _build_stage() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(VP_SIZE, VP_SIZE)
	_vp.transparent_bg = true  # 透明底：get_used_rect 才能测出内容边界，自动取景/裁边靠它
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -40, 0)
	sun.light_energy = 1.2
	_vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 140, 0)
	fill.light_energy = 0.4
	_vp.add_child(fill)

	_cam = Camera3D.new()
	_vp.add_child(_cam)
	_stage = Node3D.new()
	_vp.add_child(_stage)

func _run() -> void:
	await process_frame
	var id := _arg("--json", "corn_stalk")
	var out := _arg("--out", "/tmp/%s.png" % id)
	_elev = float(_arg("--elev", "45"))
	_azim = float(_arg("--azim", "30"))
	var prop: SdfProp = SdfProp.from_json_file("res://assets/sdf_props/%s.json" % id)
	if prop == null:
		push_error("[preview] 解析失败: %s" % id)
		quit(1)
		return
	# 摘 VisibleOnScreenEnabler3D 并强制常驻（离屏无主窗相机否则挂起）
	for c in prop.get_children():
		if c is VisibleOnScreenEnabler3D:
			prop.remove_child(c)
			c.queue_free()
	prop.visible = true
	prop.process_mode = Node.PROCESS_MODE_ALWAYS
	_stage.add_child(prop)
	for _i in range(SETTLE_FRAMES):
		await process_frame

	var aabb := _node_aabb(prop)
	if aabb.size == Vector3.ZERO:
		aabb = AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1.6, 1))
	var center := aabb.position + aabb.size * 0.5
	var radius := aabb.size.length() * 0.5
	var elev := deg_to_rad(_elev)
	var azim := deg_to_rad(_azim)
	var dir := Vector3(cos(elev) * sin(azim), sin(elev), cos(elev) * cos(azim))
	_cam.near = 0.01
	_cam.far = 100000.0
	var dist := maxf(radius * FIT_MARGIN / tan(deg_to_rad(_cam.fov * 0.5)), 0.6)
	_cam.position = center + dir * dist
	_cam.look_at(center, Vector3.UP)

	var img: Image = null
	for pass_i in range(FIT_PASSES):
		for _i in range(SETTLE_FRAMES):
			await process_frame
		img = _vp.get_texture().get_image()
		var used := img.get_used_rect()
		if used.size == Vector2i.ZERO:
			continue
		var span := float(maxi(used.size.x, used.size.y))
		var target := float(VP_SIZE) * FIT_TARGET
		if pass_i == FIT_PASSES - 1 or absf(span - target) < VP_SIZE * 0.06:
			break
		var d := (_cam.position - center).length()
		var nd := clampf(d * span / target, 0.4, 200000.0)
		_cam.position = center + dir * nd
		_cam.look_at(center, Vector3.UP)

	if img == null:
		push_error("[preview] 渲染空帧")
		quit(1)
		return
	img = _flatten(_trim(img), Color(0.9, 0.9, 0.92))
	img.save_png(out)
	print("[preview] 已存 %s (%dx%d) elev=%.0f azim=%.0f" % [out, img.get_width(), img.get_height(), _elev, _azim])
	quit(0)

func _trim(img: Image) -> Image:
	var used := img.get_used_rect()
	if used.size == Vector2i.ZERO:
		return img
	var pad := 12
	var x := maxi(used.position.x - pad, 0)
	var y := maxi(used.position.y - pad, 0)
	var w := mini(used.size.x + pad * 2, img.get_width() - x)
	var h := mini(used.size.y + pad * 2, img.get_height() - y)
	return img.get_region(Rect2i(x, y, w, h))

## 透明图合成到不透明底色（目视用）。
func _flatten(img: Image, bg: Color) -> Image:
	var out := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	out.fill(bg)
	out.blend_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i.ZERO)
	return out

func _node_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var has := false
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var world := vi.global_transform * vi.get_aabb()
			if not has:
				out = world
				has = true
			else:
				out = out.merge(world)
		for c in n.get_children():
			stack.append(c)
	return out
