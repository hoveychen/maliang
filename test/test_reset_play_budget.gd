extends SceneTree
## 清掉 user://profile.json 里的可玩时间预算（把 cooldown 截图脚本写进去的冷却抹掉，别锁住真机开发档）。
func _initialize() -> void:
	PlayerProfile.save_play_budget(0.0, 0.0, 0.0)
	print("play_budget reset")
	quit(0)
