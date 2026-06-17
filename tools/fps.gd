extends SceneTree
## 帧率压测：持续移动玩家逼迫区块每帧流送/重皮肤，统计平均 fps。
var f := 0
var w
var acc := 0.0
var n := 0
func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	get_root().add_child(w)
func _process(_d: float) -> bool:
	f += 1
	if w != null:
		w.player_logical = WorldGrid.wrap_pos(w.player_logical + Vector2(4.0, 1.5))
	if f > 30:
		acc += Engine.get_frames_per_second()
		n += 1
	if f == 200:
		printerr("AVG_FPS=%.1f over %d frames" % [acc / max(n, 1), n])
		return true
	return false
