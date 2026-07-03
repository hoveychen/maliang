extends SceneTree
## 形象生成页集成验证（需本地 mock 服务端）：预设答案 → 生成 → 确认行出现 →
## ↻ 重生成 → 再确认 → ✓ → sprite_asset 入档案并完成 onboarding 切世界。
## 运行: MALIANG_API_BASE=http://127.0.0.1:8095 godot --headless --script res://test/test_visual_generate.gd

var ob: Node
var frame := 0
var fails := 0
var phase := 0
var gen_idx := -1
var _phase2_t0 := 0

func _initialize() -> void:
	PlayerProfile.clear()
	ob = load("res://onboarding.tscn").instantiate()
	root.add_child(ob)
	var answers: Dictionary = ob.get("answers")
	answers["gender"] = "girl"
	answers["color"] = "蓝色"
	answers["likes"] = "小猫"
	answers["interest"] = "画画"
	answers["name"] = "朵朵"
	answers["nickname"] = "朵朵"
	for i in range((ob.get("PAGES") as Array).size()):
		if String(((ob.get("PAGES") as Array)[i] as Dictionary)["id"]) == "generate":
			gen_idx = i
	ob.set("page_idx", gen_idx - 1)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame == 5:
		ob.call("_next_page")
		return
	match phase:
		0: # 等第一次生成完成
			var c := ob.get("_gen_confirm") as Control
			if c != null and c.visible:
				_check("first sprite shown", (ob.get("_gen_img") as TextureRect).visible, true)
				(c.get_child(1) as Button).emit_signal("pressed") # ↻ 再变一次
				phase = 1
			elif frame > 200:
				_fail_out("first generation never completed")
		1: # 重生成后再次出现确认
			var c := ob.get("_gen_confirm") as Control
			if c != null and c.visible and frame > 30:
				(c.get_child(0) as Button).emit_signal("pressed") # ✓ 采用
				phase = 2
			elif frame > 300:
				_fail_out("regeneration never completed")
		2: # 完成:档案落盘 + 切世界（_finish 要等 ob_done 音频 ~2.3s,用真实时间预算）
			if _phase2_t0 == 0:
				_phase2_t0 = Time.get_ticks_msec()
			if current_scene != null and current_scene.name == "World":
				var prof := PlayerProfile.load_profile()
				_check("sprite_asset saved", String(prof.get("sprite_asset", "")).length() > 0, true)
				_check("name saved", prof.get("name", ""), "朵朵")
				phase = 3
				_done()
			elif Time.get_ticks_msec() - _phase2_t0 > 8000:
				_fail_out("never reached world")

func _fail_out(msg: String) -> void:
	fails += 1
	printerr("  FAIL %s" % msg)
	phase = 3
	_done()

func _done() -> void:
	if fails == 0:
		print("visual_generate PASS")
	else:
		printerr("visual_generate FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
