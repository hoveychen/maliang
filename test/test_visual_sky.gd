extends SceneTree
## 动态天空盒回归：环境必须是 BG_SKY + sky_day shader，且守住两个无缝衔接不变量：
## (1) shader 的 horizon_color == fog_light_color——深度雾把远地渐隐到的颜色必须正好是
##     天空底色，否则地平线处出现色带接缝；
## (2) fog_sky_affect == 0——深度雾对天空满强度（sky 在无穷远 = 雾最浓）会把整个
##     渐变/云抹平回雾色，动态天空等于白做。
## 动态性断言：wind 非零（云随 TIME 漂移）+ 云噪声纹理已挂载。
## 性能护栏：radiance 最小档 + 非 REALTIME（安卓平板；ambient 走纯色源用不到 radiance）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_visual_sky.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame != 10:
		return
	var env := _find_env()
	_check("场景里有 WorldEnvironment", env != null, true)
	if env == null:
		quit(fails)
		return
	_check("背景模式是 BG_SKY", env.background_mode, Environment.BG_SKY)
	_check("挂了 Sky 资源", env.sky != null, true)
	if env.sky != null:
		var mat := env.sky.sky_material as ShaderMaterial
		_check("sky_material 是 ShaderMaterial", mat != null, true)
		if mat != null:
			_check("shader 是 sky_day", mat.shader.resource_path, "res://shaders/sky_day.gdshader")
			var horizon: Variant = mat.get_shader_parameter("horizon_color")
			_check("地平线色与雾色一致（无缝衔接不变量）",
				horizon is Color and _color_close(horizon, env.fog_light_color), true)
			var wind: Variant = mat.get_shader_parameter("wind")
			_check("云漂移速度非零（天空是动的）",
				wind is Vector2 and (wind as Vector2).length() > 0.0, true)
			var tex: Variant = mat.get_shader_parameter("cloud_tex")
			_check("云噪声纹理已挂载且无缝",
				tex is NoiseTexture2D and (tex as NoiseTexture2D).seamless, true)
		_check("radiance 最小档（安卓开销护栏）", env.sky.radiance_size, Sky.RADIANCE_SIZE_32)
		_check("radiance 非逐帧重烘", env.sky.process_mode != Sky.PROCESS_MODE_REALTIME, true)
	_check("深度雾仍开启（无限地平线保留）", env.fog_enabled, true)
	_check("雾不抹平天空 (fog_sky_affect=0)", is_zero_approx(env.fog_sky_affect), true)
	if fails == 0:
		print("visual_sky PASS")
	else:
		printerr("visual_sky FAILED: %d" % fails)
	quit(fails)

func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01

func _find_env() -> Environment:
	for c in scene.get_children():
		if c is WorldEnvironment:
			return (c as WorldEnvironment).environment
	return null

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
