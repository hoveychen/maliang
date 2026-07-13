extends SceneTree
## 确认条在两个宿主里的接线（world + onboarding 共用 ConfirmBar，一个开关全局生效）。
## 不走真 ASR：直接发 VoiceCapture 的信号，验证宿主对信号的反应——
##   confirm_ready → 亮条（world 还要把「思考中」收掉：说完≠采纳，这会儿没人在思考）
##   committed     → 收条（accept 会补发 committed；没开确认模式时它本来就一直发）
## 三个键点下去要真的打到 VoiceCapture 的 replay/accept/retry 上（接线断了 UI 就是死的）。
## 运行: godot --headless --path . --script res://test/test_confirm_bar.gd

var _ran := false

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ✓ %s" % name)
		return 0
	printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0
	fails += _test_world()
	fails += _test_onboarding()
	fails += _test_buttons_wired()
	if fails == 0:
		print("test_confirm_bar: 全部通过")
	else:
		printerr("test_confirm_bar: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)

func _test_world() -> int:
	print("[world 接线]")
	var f := 0
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var bar: Control = scene.get("confirm_bar")
	var vc: Object = scene.get("_vc")
	var thinking: Label = scene.get("thinking_label")
	f += _check("确认条已建", bar != null, true)
	f += _check("初始隐藏（没开确认模式就永远不出现）", bar.visible, false)
	# 假装孩子说完、端侧识别好了：VoiceCapture 正在回放，等确认
	thinking.visible = true # 先弄脏：验证宿主会把它收掉
	vc.confirm_ready.emit("去公园")
	f += _check("confirm_ready → 亮确认条", bar.visible, true)
	f += _check("确认条显示识别到的文字（给家长看）", bar._text_label.text, "去公园")
	f += _check("说完≠采纳：思考中收掉", thinking.visible, false)
	# 孩子点了「就是这样」→ VoiceCapture 补发 committed
	vc.committed.emit()
	f += _check("committed → 收确认条", bar.visible, false)
	scene.queue_free()
	return f

func _test_onboarding() -> int:
	print("[onboarding 接线]")
	var f := 0
	var ob: Control = load("res://scripts/onboarding.gd").new()
	root.add_child(ob)
	# intro 页的 UI 是懒构建的（_build_intro）：直接建一遍，确认条就在里面
	var box := VBoxContainer.new()
	ob.add_child(box)
	ob._build_intro(box, {})
	ob._voice.stop()
	var bar: Control = ob.get("_confirm_bar")
	var vc: Object = ob.get("_vc")
	f += _check("确认条已建", bar != null, true)
	f += _check("初始隐藏", bar.visible, false)
	vc.confirm_ready.emit("我叫朵朵")
	f += _check("confirm_ready → 亮确认条", bar.visible, true)
	f += _check("显示识别到的名字", bar._text_label.text, "我叫朵朵")
	f += _check("此时还没进提交态（说完≠采纳）", ob.get("_intro_submitting"), false)
	ob.free()
	return f

## 三个键真的连到了 VoiceCapture 上——按钮画得再好，信号没接就是死的。
func _test_buttons_wired() -> int:
	print("[按钮接线]")
	var f := 0
	var bar := ConfirmBar.new()
	root.add_child(bar)
	var hits := []
	bar.replay_pressed.connect(func() -> void: hits.append("replay"))
	bar.accept_pressed.connect(func() -> void: hits.append("accept"))
	bar.retry_pressed.connect(func() -> void: hits.append("retry"))
	# 按钮在第二个子节点（HBox）里：耳朵 / 对勾 / 转圈
	var row := bar.get_child(1)
	f += _check("三个键都在", row.get_child_count(), 3)
	for b in row.get_children():
		(b as Button).pressed.emit()
	f += _check("耳朵=再听、对勾=就是这样、转圈=再说一次", hits, ["replay", "accept", "retry"])
	bar.queue_free()
	return f
