extends SceneTree
## 室内封闭观感回归（home-interior P3，唯一引擎侧改动）：boot 进 home_interior 后环境必须切成
## 室内档——无天空(BG_COLOR 暖暗)、无雾、暖色环境光、太阳压暗。室外还原不回归由 test_visual_sky
## 守（它 boot 默认 village_forest 仍断言 BG_SKY + 雾开）。这里只验室内侧。
## 用 OS.set_environment 在 instantiate 前把 boot 场景钉到 home_interior（world._ready 读它）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_visual_home_env.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。
const World := preload("res://scripts/world.gd")

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	OS.set_environment("MALIANG_BOOT_SCENE", "home_interior")
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
	if env != null:
		_check("室内无天空：背景 = BG_COLOR", env.background_mode, Environment.BG_COLOR)
		_check("室内背景 = 暖暗色", _color_close(env.background_color, World.INDOOR_BG_COLOR), true)
		_check("室内关雾（不被地平线雾色冲淡）", env.fog_enabled, false)
		_check("室内暖色环境光", _color_close(env.ambient_light_color, World.INDOOR_AMBIENT_COLOR), true)
		_check("室内环境光能量", is_equal_approx(env.ambient_light_energy, World.INDOOR_AMBIENT_ENERGY), true)
	var sun := _find_sun()
	_check("场景里有太阳灯", sun != null, true)
	if sun != null:
		_check("室内太阳压暗", is_equal_approx(sun.light_energy, World.INDOOR_SUN_ENERGY), true)
		_check("室内太阳更暖", _color_close(sun.light_color, World.INDOOR_SUN_COLOR), true)
	if fails == 0:
		print("visual_home_env PASS")
	else:
		printerr("visual_home_env FAILED: %d" % fails)
	quit(fails)

func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01

func _find_env() -> Environment:
	for c in scene.get_children():
		if c is WorldEnvironment:
			return (c as WorldEnvironment).environment
	return null

func _find_sun() -> DirectionalLight3D:
	for c in scene.get_children():
		if c is DirectionalLight3D:
			return c as DirectionalLight3D
	return null

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
