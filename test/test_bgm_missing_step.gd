extends SceneTree
## BGM 缺失段守卫（content-pck-distribution P5）。
## bgm 的 cheery/happy 两首改为可分发内容包，carefree 留主包。设备未下载/未挂载 bgm 包时，
## 那两段 load 失败——【不得连坐】carefree：跳过失败段、只播成功段；全失败才无 BGM（优雅静默）。
## 修复前 _poll_bgm_load 任一段失败即 clear 全部→无任何 BGM（含 carefree），本测试锁死该退化。
## 运行: godot --headless --path . --script res://test/test_bgm_missing_step.gd

var _fails := 0

func _initialize() -> void:
	var ga: Node = load("res://scripts/game_audio.gd").new()
	get_root().add_child(ga)
	await process_frame # 等 _ready（建 _music_a/b + SFX 预热）

	# 一段有效（主包内 bgm）+ 一段必然缺失（模拟未下载的可分发段）。
	var valid := "res://assets/audio/bgm/bgm_happy_boy.wav"
	var missing := "res://assets/audio/bgm/__nonexistent_test_segment__.wav"
	ga.call("start_bgm", [valid, missing], 0)

	# _process 会驱动 _poll_bgm_load；等它把 _bgm_want 消费完（成功组装或全失败）。
	var budget := 600
	while int((ga.get("_bgm_want") as Array).size()) > 0 and budget > 0:
		await process_frame
		budget -= 1

	var steps: Array = ga.get("_steps")
	_check("缺失段被跳过、有效段照常入 _steps（不连坐）", steps.size(), 1)
	_check("轮询已收敛（_bgm_want 清空）", int((ga.get("_bgm_want") as Array).size()), 0)

	ga.queue_free()
	print("test_bgm_missing_step: %d failures" % _fails)
	quit(_fails)

func _check(label: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok  %s" % label)
	else:
		print("  FAIL %s: got=%s want=%s" % [label, str(got), str(want)])
		_fails += 1
