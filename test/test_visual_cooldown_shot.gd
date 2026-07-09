extends SceneTree
## 临时视觉验证（不进回测）：可玩时间用尽的冷却拦截遮罩截帧。
## frame 8 强制进入冷却（剩 5min / 冷却 10min → 进度 50%），观察全屏遮罩 + 大闹钟饼图 + 文案。
## 运行: godot --write-movie <目录>/f.png --fixed-fps 8 --quit-after 40 \
##       --script res://test/test_visual_cooldown_shot.gd
## 注意：会把冷却写进 user://profile.json，跑完请用 test_reset_play_budget.gd 清掉。

var scene: Node
var frame := 0

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 8:
		# 走真实机制：设个未来的冷却结束时间，下一帧 _step_play_budget 会判定 blocked→弹遮罩。
		scene.set("_play_cooldown_until", Time.get_unix_time_from_system() + 300.0)

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)
