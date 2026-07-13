extends SceneTree
## PaperPhone 三态截图 + 光照 derisk 工具（带窗跑；headless 假视口 64×64 不可用）。
## 用法: $GODOT --path <绝对路径> --script res://tools/shoot_phone.gd
## 环境变量:
##   SHOT_DIR    输出目录（默认 res://screenshots/paper_phone）
##   SHOT_MODE   baseline（默认：dock/front/spread 三态各一张）
##               yawsweep（光照稳定性：front 态在相机 yaw 0/90/180/270 各一张 + 亮度统计）
##   SHOT_LIGHT  unshaded（默认，现状）| rig（方案A 原型：手机独立渲染层 + 相机挂灯 + 材质吃光）
##   SHOT_TAG    输出文件名前缀（默认取 SHOT_LIGHT）

const PHONE_LAYER := 1 << 10  # 渲染层 11（全仓库无人用 .layers，独占）

var _frames := 0
var _world: Node = null
var _dir := "res://screenshots/paper_phone"
var _mode := "baseline"
var _light := "unshaded"
var _tag := ""
var _yaw_idx := 0
var _yaws := [0.0, PI * 0.5, PI, -PI * 0.5]
var _lums := []

func _initialize() -> void:
	var d := OS.get_environment("SHOT_DIR")
	if d != "":
		_dir = d
	var m := OS.get_environment("SHOT_MODE")
	if m != "":
		_mode = m
	var l := OS.get_environment("SHOT_LIGHT")
	if l != "":
		_light = l
	_tag = OS.get_environment("SHOT_TAG")
	if _tag == "":
		_tag = _light
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var scene: PackedScene = load("res://main.tscn")
	_world = scene.instantiate()
	get_root().add_child(_world)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 30 and _light == "rig":
		_apply_rig()
	match _mode:
		"baseline":
			return _step_baseline()
		"yawsweep":
			return _step_yawsweep()
	return true

## ── baseline：dock → front → spread 各一张 ──────────────────────────────────

func _step_baseline() -> bool:
	match _frames:
		50:
			_shoot("dock")
		55:
			_world._open_phone()
		110:
			_shoot("front")
		115:
			_world.phone_ui.open_app("flowers")
		175:
			_shoot("spread")
			return true
	return false

## ── yawsweep：front 态，相机绕焦点转 4 个方位，各截一张并统计手机区亮度 ──────

func _step_yawsweep() -> bool:
	if _frames == 55:
		_world._open_phone()
	# 每个方位：设 yaw → 等 45 帧（相机 lerp 收敛）→ 截图
	var base := 120
	var period := 45
	if _frames >= base and (_frames - base) % period == 0:
		if _yaw_idx > 0:
			_shoot_yaw(_yaw_idx - 1)
		if _yaw_idx >= _yaws.size():
			_report()
			return true
		_world._gest_yaw = _yaws[_yaw_idx]
		_world._gest_yaw_t = _yaws[_yaw_idx]
		_yaw_idx += 1
	return false

func _shoot_yaw(i: int) -> void:
	var img := _capture("yaw%d" % int(round(rad_to_deg(float(_yaws[i])))))
	var lum := _phone_luminance(img)
	_lums.append(lum)
	printerr("LUM yaw=%.0f° -> %.4f" % [rad_to_deg(float(_yaws[i])), lum])

func _report() -> void:
	var lo := 1e9
	var hi := -1e9
	for v: float in _lums:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	printerr("LUM_RANGE light=%s min=%.4f max=%.4f spread=%.4f (%.1f%%)" %
		[_light, lo, hi, hi - lo, (hi - lo) / maxf(lo, 1e-6) * 100.0])

## 手机区平均亮度：front 态机身中心 NDC(0.52,0)、高占屏 0.85、宽=高/2.1，取中央 60%。
func _phone_luminance(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var ph := 0.85 * float(h) * 0.6
	var pw := ph / 2.1
	var cx := (0.52 * 0.5 + 0.5) * float(w)
	var cy := 0.5 * float(h)
	var acc := 0.0
	var n := 0
	for y in range(int(cy - ph * 0.5), int(cy + ph * 0.5), 4):
		for x in range(int(cx - pw * 0.5), int(cx + pw * 0.5), 4):
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			var c := img.get_pixel(x, y)
			acc += c.r * 0.299 + c.g * 0.587 + c.b * 0.114
			n += 1
	return acc / maxf(float(n), 1.0)

## ── 方案A 原型（运行期 monkey-patch，不改 paper_phone.gd）────────────────────

func _apply_rig() -> void:
	var phone: Node3D = _world.paper_phone
	var cam: Camera3D = _world.camera
	# 1) 手机全部 mesh 挪独立渲染层 + 材质改吃光哑光（屏幕视口贴面一并，先看效果）
	for mi: MeshInstance3D in _all_meshes(phone):
		mi.layers = PHONE_LAYER
		var m := mi.material_override as StandardMaterial3D
		if m != null:
			m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			m.roughness = 1.0
			m.metallic_specular = 0.0
	# 2) 世界太阳不照手机（方向随相机 yaw 变，是亮度不稳的唯一来源）
	var sun := _world._sun as DirectionalLight3D
	sun.light_cull_mask &= ~PHONE_LAYER
	# 3) 自带暖灯挂相机：相对观察者恒定的左上前方光（onboarding 故事书同参）
	var rig := DirectionalLight3D.new()
	rig.name = "PhoneRigLight"
	rig.light_cull_mask = PHONE_LAYER
	rig.rotation = Vector3(-0.95, -0.35, 0.0)
	rig.light_color = Color(1.0, 0.965, 0.90)
	rig.light_energy = 1.05
	rig.shadow_enabled = false
	cam.add_child(rig)
	printerr("RIG applied: layer=%d sun_mask=%d" % [PHONE_LAYER, sun.light_cull_mask])

func _all_meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all_meshes(c))
	return out

## ── 截图 ────────────────────────────────────────────────────────────────────

func _capture(shot_name: String) -> Image:
	var img := get_root().get_viewport().get_texture().get_image()
	var path := "%s/%s_%s.png" % [_dir, _tag, shot_name]
	img.save_png(path)
	printerr("SHOT saved: %s" % path)
	return img

func _shoot(shot_name: String) -> void:
	_capture(shot_name)
