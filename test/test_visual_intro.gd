extends SceneTree
## 自我介绍页集成验证（需本地 mock 服务端 MALIANG_API_BASE）：
## 1) 听不清（无名字）→ 重问不出确认行;2) 「我叫朵朵」→ 确认行出现 → ✓ → 名字入 answers 并翻页。
## 运行: MALIANG_API_BASE=http://127.0.0.1:8095 godot --headless --script res://test/test_visual_intro.gd
## （无渲染依赖,headless 即可;服务端用 mock adapters: node src/index.ts 不带 .env）

var ob: Node
var frame := 0
var fails := 0
var phase := 0
var intro_idx := -1

func _initialize() -> void:
	PlayerProfile.clear()
	ob = load("res://onboarding.tscn").instantiate()
	root.add_child(ob)
	for i in range((ob.get("PAGES") as Array).size()):
		if String(((ob.get("PAGES") as Array)[i] as Dictionary)["id"]) == "intro":
			intro_idx = i
	ob.set("page_idx", intro_idx - 1)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	match phase:
		0:
			if frame == 5:
				ob.call("_next_page") # 翻到 intro 页
			if frame == 20:
				phase = 1
				ob.call("_submit_intro", "今天天气真好", PackedByteArray())
		1:
			if frame == 60:
				_check("no-name keeps confirm hidden", (ob.get("_intro_confirm") as Control).visible, false)
				_check("retry counted", int(ob.get("_intro_tries")), 1)
				phase = 2
				ob.call("_submit_intro", "我叫朵朵", PackedByteArray())
		2:
			var confirm := ob.get("_intro_confirm") as Control
			if confirm != null and confirm.visible:
				_check("pending name", String((ob.get("_pending") as Dictionary).get("name", "")), "朵朵")
				(confirm.get_child(0) as Button).emit_signal("pressed") # ✓
				phase = 3
			elif frame > 160:
				fails += 1
				printerr("  FAIL confirm row never appeared")
				phase = 4
		3:
			if frame > 165 or int(ob.get("page_idx")) > intro_idx:
				var ans: Dictionary = ob.get("answers")
				_check("answers name", String(ans.get("name", "")), "朵朵")
				_check("advanced to next page", int(ob.get("page_idx")), intro_idx + 1)
				phase = 4
		4:
			if fails == 0:
				print("visual_intro PASS")
			else:
				printerr("visual_intro FAILED: %d" % fails)
			quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
