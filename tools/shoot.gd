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
		_world.player_logical = WorldGrid.wrap_pos(Vector2(_mx, _mz))
	if _frames == _shoot_at:
		var img := get_root().get_viewport().get_texture().get_image()
		img.save_png("res://_%s.png" % _name)
		printerr("SHOT saved: _%s.png" % _name)
		return true
	return false
