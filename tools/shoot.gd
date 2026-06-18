extends SceneTree
## 截图工具：加载主场景，跑若干帧后保存视口截图并退出。
## 用法: Godot --path . --script res://tools/shoot.gd [-- <move_x> <move_z> <frames>]
## 通过环境变量 SHOT_MX / SHOT_MZ 注入玩家逻辑移动（用来验证 wrap），SHOT_NAME 命名。

var _frames := 0
var _world: Node = null
var _mx := 0.0
var _mz := 0.0
var _shoot_at := 50
var _name := "shot"

func _initialize() -> void:
	_mx = float(OS.get_environment("SHOT_MX"))
	_mz = float(OS.get_environment("SHOT_MZ"))
	var n := OS.get_environment("SHOT_NAME")
	if n != "":
		_name = n
	var scene: PackedScene = load("res://main.tscn")
	_world = scene.instantiate()
	get_root().add_child(_world)

func _process(_delta: float) -> bool:
	_frames += 1
	# 注入一个目标逻辑坐标，让 chunk/wrap 体现出来
	if _frames == 5 and _world != null and (_mx != 0.0 or _mz != 0.0):
		_world.focus_logical = WorldGrid.wrap_pos(Vector2(_mx, _mz))
	# 强制相机俯角（测试最平 lock 角度的边界）
	if _frames == 5 and _world != null and OS.get_environment("SHOT_PITCH") != "":
		var pp := float(OS.get_environment("SHOT_PITCH"))
		_world._cur_pitch = pp
		_world._target_pitch = pp
	# 合成一次点击，命中第一个 NPC，验证拾取 + 进交互模式
	if _frames == 10 and OS.get_environment("SHOT_TAP") == "1" and _world != null:
		var npc = _world.npcs[0]["node"]
		var sp: Vector2 = _world.camera.unproject_position(npc.global_position + Vector3(0, 1.6, 0))
		var ev := InputEventScreenTouch.new()
		ev.index = 0
		ev.pressed = true
		ev.position = sp
		get_root().push_input(ev)
	if _frames == 14 and OS.get_environment("SHOT_TAP") == "1" and _world != null:
		if _world.selected != null:
			printerr("SELECTED=%s EAR_VISIBLE=%s" % [_world.selected.char_name, str(_world.ear_icon.visible)])
		else:
			printerr("SELECTED=<none>")
	if _frames == _shoot_at:
		var img := get_root().get_viewport().get_texture().get_image()
		img.save_png("res://_%s.png" % _name)
		printerr("SHOT saved: _%s.png" % _name)
		return true
	return false
