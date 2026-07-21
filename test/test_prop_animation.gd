extends SceneTree
## node 类 3D 摆件动起来（models-play-animation）：
## P1 通用自播——chunk_manager._activate_prop_animation 对含 AnimationPlayer 的 glb 循环播首个 clip；
## P2 风车转扇叶——chunk_manager._spawn_fan_spinner 对名含 _top_fan_ 的子节点挂 PropSpinner。
## 运行: godot --headless --path . --script res://test/test_prop_animation.gd

func _init() -> void:
	var fails := 0
	var cm := ChunkManager.new()
	root.add_child(cm)

	# ── P1a：合成场景（Node3D + AnimationPlayer[walk, RESET]）验证自播逻辑 ──────────
	var inst := Node3D.new()
	var ap := AnimationPlayer.new()
	inst.add_child(ap)
	var lib := AnimationLibrary.new()
	var walk := Animation.new()
	walk.length = 1.0
	lib.add_animation("walk", walk)
	var reset := Animation.new()
	reset.length = 0.0
	lib.add_animation("RESET", reset)
	ap.add_animation_library("", lib)
	root.add_child(inst) # play() 要求在树内
	cm._activate_prop_animation(inst)
	fails += _check("自带动画的 glb 会自动播放", ap.is_playing(), true)
	fails += _check("播的是真 clip 而非 RESET 姿态轨", ap.current_animation, "walk")
	fails += _check("首个 clip 被设为循环", ap.get_animation("walk").loop_mode, Animation.LOOP_LINEAR)
	inst.queue_free()

	# ── P1b：只有 RESET 轨（无真动画）→ 不 play，不崩 ────────────────────────────
	var inst2 := Node3D.new()
	var ap2 := AnimationPlayer.new()
	inst2.add_child(ap2)
	var lib2 := AnimationLibrary.new()
	lib2.add_animation("RESET", Animation.new())
	ap2.add_animation_library("", lib2)
	root.add_child(inst2)
	cm._activate_prop_animation(inst2)
	fails += _check("只有 RESET 轨时不误播", ap2.is_playing(), false)
	inst2.queue_free()

	# ── P1c：无 AnimationPlayer 的静态建筑 → 空操作，不崩 ────────────────────────
	var inst3 := Node3D.new()
	inst3.add_child(MeshInstance3D.new())
	root.add_child(inst3)
	cm._activate_prop_animation(inst3) # 不应抛错
	fails += _check("无 AnimationPlayer 时安全空操作", true, true)
	inst3.queue_free()

	# ── 真实 glb 的地面真相：区分两类模型家族 ───────────────────────────────────
	# 恐龙/机器人/鱼那批 glb 自带动画（历史上白白僵着）；KayKit 风车集不带动画。
	var dino: PackedScene = load("res://assets/dino/dino_a.glb")
	if dino != null:
		var dn := dino.instantiate()
		var has_ap := not dn.find_children("*", "AnimationPlayer", true, false).is_empty()
		fails += _check("恐龙 glb 自带 AnimationPlayer（本该动却曾僵着）", has_ap, true)
		dn.free()
	else:
		fails += _check("恐龙 glb 可载入", false, true)

	var mill: PackedScene = load("res://assets/medieval/hexagon/building_windmill_blue.gltf")
	if mill != null:
		var mn := mill.instantiate()
		var has_ap := not mn.find_children("*", "AnimationPlayer", true, false).is_empty()
		fails += _check("风车 glb 无 AnimationPlayer（故需程序化转扇叶）", has_ap, false)
		# 扇叶是独立命名子节点，程序化旋转的锚点
		var fan_found := false
		for c in mn.find_children("*", "MeshInstance3D", true, false):
			if String(c.name).contains("_top_fan_"):
				fan_found = true
				break
		fails += _check("风车扇叶是独立命名子节点(_top_fan_)", fan_found, true)
		mn.free()
	else:
		fails += _check("风车 glb 可载入", false, true)

	# ── P2：_spawn_fan_spinner 给扇叶挂上 PropSpinner ───────────────────────────
	var mill2: PackedScene = load("res://assets/medieval/hexagon/building_windmill_blue.gltf")
	if mill2 != null:
		var m2 := mill2.instantiate() as Node3D
		root.add_child(m2)
		cm._spawn_fan_spinner(m2)
		var spinner_n := 0
		for c in m2.find_children("*", "PropSpinner", true, false):
			spinner_n += 1
		fails += _check("风车扇叶挂上 1 个 PropSpinner", spinner_n, 1)
		m2.queue_free()

	cm.queue_free()
	if fails == 0:
		print("PASS test_prop_animation")
	else:
		printerr("FAIL test_prop_animation: %d 处不符" % fails)
	quit(fails)

func _check(label: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got=%s want=%s" % [label, str(got), str(want)])
	return 1
