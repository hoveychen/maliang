extends SceneTree
## 进度式加载 + 就绪才揭幕（消除玩家启动瞬移）的单元测试。
## 覆盖两件事：
##   1. 关窗不变量：api.get_world 的网络超时严格 < world 的就绪硬超时——保证「慢但成功」
##      的 get_world 必在 loading 揭幕前定音（成功走正常路径 / 超时走离线），从源头堵死
##      「揭幕后 get_world 才返回、把玩家硬拽到仙子旁」这一启动瞬移窗口。
##   2. chunk_manager.skinned_fraction()：loading 仙子飞行进度的地基信号。
## 运行: godot --headless --path . --script res://test/test_loading_progress.gd

func _init() -> void:
	var fails := 0

	# --- 关窗不变量：get_world 超时 < 就绪硬超时，且为正（有限）---
	# world.gd 无 class_name，取其常量映射读 READY_TIMEOUT_SEC。
	var world_consts: Dictionary = (load("res://scripts/world.gd") as GDScript).get_script_constant_map()
	var ready_timeout: float = world_consts["READY_TIMEOUT_SEC"]
	var net_timeout := Api.GET_WORLD_TIMEOUT_SEC
	fails += _check("get_world 超时为正（有限，非 0=永不超时）", net_timeout > 0.0, true)
	fails += _check("get_world 超时 < 就绪硬超时（关瞬移窗口）", net_timeout < ready_timeout, true)

	# --- skinned_fraction：空槽 0、混合按比例、全铺 1 ---
	var cm := ChunkManager.new()
	fails += _check("空槽 fraction=0", cm.skinned_fraction(), 0.0)
	cm._slots = [
		{ "skinned": true }, { "skinned": false },
		{ "skinned": false }, { "skinned": true },
	]
	fails += _check("2/4 已铺 fraction=0.5", cm.skinned_fraction(), 0.5)
	for s in cm._slots:
		s["skinned"] = true
	fails += _check("全铺 fraction=1", cm.skinned_fraction(), 1.0)
	fails += _check("全铺时 all_skinned 亦为真", cm.all_skinned(), true)
	cm.free()

	print("test_loading_progress: %d fail(s)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
