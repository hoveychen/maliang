extends SceneTree
## 童话书框架验证：故事页自动翻页(无音频时 ~1.7s)、问题页点选项记录答案并翻页、
## 全部问题答完(intro/generate 框架期点▶跳过)后落盘档案并切世界场景。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie screenshots/ob/f.png \
##       --fixed-fps 10 --quit-after 420 --script res://test/test_visual_onboarding.gd
## （故事页按预制旁白实际时长自动翻页,3 页 ~23s,全流程 ~35s）

var ob: Node
var frame := 0
var fails := 0
var done := false

func _initialize() -> void:
	PlayerProfile.clear()
	ob = load("res://onboarding.tscn").instantiate()
	root.add_child(ob)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if done:
		return
	# 每帧机会主义推进：问题页点第 2 个选项;intro/generate 页点 ▶
	if frame % 5 == 0 and ob.is_inside_tree():
		var idx: int = ob.get("page_idx")
		if idx >= 0:
			var p: Dictionary = (ob.get("PAGES") as Array)[idx]
			match String(p["kind"]):
				"question":
					var btns: Array[Node] = ob.find_children("*", "Button", true, false)
					var opts: Array = []
					for b in btns:
						if (b as Button).custom_minimum_size.x > 100.0:
							opts.append(b)
					if opts.size() >= 2:
						(opts[1] as Button).emit_signal("pressed")
				"intro":
					# 离线环境:提交必失败→重问,3 次后兜底叫「小朋友」自动放行
					if frame % 30 == 0 and int(p_idx_tries()) < 3:
						ob.call("_submit_intro", "测试", PackedByteArray())
				"generate":
					pass # 离线:生成失败自动放行,无需驱动
	# 场景被替换成世界 = 完成
	if current_scene != null and current_scene.name == "World":
		done = true
		var prof := PlayerProfile.load_profile()
		_check("profile gender saved", prof.get("gender", ""), "girl")
		_check("profile color saved", prof.get("color", ""), "蓝色")
		_check("profile likes saved", prof.get("likes", ""), "小猫")
		_check("profile interest saved", prof.get("interest", ""), "踢球")
		_check("offline intro fallback nickname", prof.get("nickname", ""), "小朋友")
		if fails == 0:
			print("visual_onboarding PASS")
		else:
			printerr("visual_onboarding FAILED: %d" % fails)
		return
	if frame >= 470:
		done = true
		printerr("visual_onboarding FAILED: 没有在时限内走完流程 (page_idx=%s)" % str(ob.get("page_idx")))

func p_idx_tries() -> int:
	return int(ob.get("_intro_tries"))

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
