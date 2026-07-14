extends SceneTree
## 组合物渲染器（ComposedProp，积木式造物 B1，docs/kids-thinking-build-from-parts.md §3.1）单测：
## - BuildBlueprints 客户端镜像：4 副蓝图、槽位姿完整
## - from_spec：造出骨架底板 + N 个零件子 quad，各按槽归一化位姿居中映射摆位
## - 每个零件 holder 是「前后三明治」双片（复用 PaperQuad，与角色贴纸同一套 helper）
## - 零件 scale：小 scale 槽（轮子 0.5）子 quad 明显小于 scale 1.0 槽（车身）
## - 预览路径 set_filled/set_glow_slot：增量填槽、当前槽发光节点存在
## 运行: godot --headless --script res://test/test_composed_prop.gd

var fails := 0

func _init() -> void:
	# ── 蓝图镜像自洽 ──────────────────────────────────────────────────────────
	_check("镜像 7 副蓝图", BuildBlueprints.BLUEPRINTS.size(), 7)
	_check("car 4 槽", (BuildBlueprints.slots("car")).size(), 4)
	var pose := BuildBlueprints.slot_pose("car", "body")
	_check("body 槽归一化 x=0.5", float(pose.get("x", -1)), 0.5)
	_check("未知蓝图空槽", BuildBlueprints.slots("nope").size(), 0)
	_check("car 中文名", BuildBlueprints.display_name("car"), "小车")

	# ── from_spec 结构与位姿 ──────────────────────────────────────────────────
	var spec := {
		"blueprintId": "car",
		"parts": [
			{ "slotId": "body", "partId": "body_box", "partRenderRef": "part:body_box" },
			{ "slotId": "wheel_back", "partId": "wheel_round", "partRenderRef": "part:wheel_round" },
			{ "slotId": "wheel_front", "partId": "wheel_round", "partRenderRef": "part:wheel_round" },
			{ "slotId": "handle", "partId": "handle_curve", "partRenderRef": "part:handle_curve" },
		],
	}
	var cp := ComposedProp.from_spec(spec)
	root.add_child(cp)
	_check("蓝图 id 记住", cp.blueprint_id, "car")
	_check("有骨架底板", cp.has_node("composed_base"), true)
	_check("4 个零件 holder", cp._part_holders.size(), 4)

	var H := ComposedProp.HEIGHT
	var body: Node3D = cp._part_holders["body"]
	var wheel: Node3D = cp._part_holders["wheel_back"]
	# body pose (0.5, 0.45): x 居中；y=(0.5-0.45)*H 略高于中心
	_check("body x 居中", absf(body.position.x) < 0.001, true)
	_check("body y=(0.5-py)*H", absf(body.position.y - (0.5 - 0.45) * H) < 0.001, true)
	# wheel_back pose (0.32, 0.78)：偏左（x<0）、偏下（y<0）
	_check("wheel_back 偏左(x<0)", wheel.position.x < 0.0, true)
	_check("wheel_back 偏下(y<0)", wheel.position.y < 0.0, true)

	# 三明治双片（复用 PaperQuad）：每零件两片 ±z，背片转 PI
	_check("零件双片(前后三明治)", body.get_child_count(), 2)
	var back_flipped := false
	for c in body.get_children():
		if (c as MeshInstance3D).position.z < 0.0 and absf(absf((c as MeshInstance3D).rotation.y) - PI) < 0.001:
			back_flipped = true
	_check("背片预转 PI", back_flipped, true)

	# 零件尺寸随 scale：轮子(0.5) 明显小于车身(1.0)；车身 quad 宽 = H*1.0
	var body_mesh := (body.get_child(0) as MeshInstance3D).mesh as QuadMesh
	var wheel_mesh := (wheel.get_child(0) as MeshInstance3D).mesh as QuadMesh
	_check("车身 quad 宽=H", absf(body_mesh.size.x - H) < 0.001, true)
	_check("轮子(scale0.5)比车身小", wheel_mesh.size.x < body_mesh.size.x - 0.5, true)
	cp.free()

	# ── 新蓝图（花）：验证客户端镜像同步 + 叠放 z 序（花心盖在花瓣之上）─────────────
	var fspec := {
		"blueprintId": "flower",
		"parts": [
			{ "slotId": "petals", "partId": "petals_round", "partRenderRef": "part:petals_round" },
			{ "slotId": "center", "partId": "center_yellow", "partRenderRef": "part:center_yellow" },
			{ "slotId": "stem", "partId": "stem_straight", "partRenderRef": "part:stem_straight" },
			{ "slotId": "leaf", "partId": "leaf_single", "partRenderRef": "part:leaf_single" },
		],
	}
	var fp := ComposedProp.from_spec(fspec)
	root.add_child(fp)
	_check("flower 中文名", BuildBlueprints.display_name("flower"), "小花")
	_check("flower 4 零件 holder", fp._part_holders.size(), 4)
	var petals: Node3D = fp._part_holders["petals"]
	var center: Node3D = fp._part_holders["center"]
	var stem: Node3D = fp._part_holders["stem"]
	var petals_mesh := (petals.get_child(0) as MeshInstance3D).mesh as QuadMesh
	var center_mesh := (center.get_child(0) as MeshInstance3D).mesh as QuadMesh
	# petals(scale1.0) 与 center(scale0.4) 同 x/y，但花心明显小
	_check("花心(scale0.4)比花瓣小", center_mesh.size.x < petals_mesh.size.x - 0.5, true)
	# 花瓣先填(layer0)、花心后填(layer1)→ 花心 z 更前，盖住花瓣中心的镂空
	_check("花心叠在花瓣之上(z更前)", center.position.z > petals.position.z, true)
	# stem pose y=0.74 → 偏下(y<0)
	_check("茎偏下(y<0)", stem.position.y < 0.0, true)
	fp.free()

	# ── 预览：增量填槽 + 当前槽发光 ────────────────────────────────────────────
	var cp2 := ComposedProp.new()
	root.add_child(cp2)
	cp2.set_filled("car", { "body": { "partId": "body_box", "partRenderRef": "part:body_box" } })
	_check("预览填 1 槽", cp2._part_holders.size(), 1)
	cp2.set_glow_slot("wheel_back")
	_check("当前槽发光节点存在", cp2.has_node("slot_glow"), true)
	_check("发光在 wheel_back 位姿", cp2._glow.position.x < 0.0, true)
	cp2.set_glow_slot("")
	_check("清发光后 _glow=null", cp2._glow == null, true)
	cp2.free()

	print("test_composed_prop: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		return
	print("  FAIL %s: got %s want %s" % [what, str(got), str(want)])
	fails += 1
