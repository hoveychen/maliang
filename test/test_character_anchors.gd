extends SceneTree
## 角色锚点贴纸附着（character-anchors P3，docs/character-anchors-design.md §4）：
## - 锚点 → 面片局部坐标换算（头顶底边对齐/手部中心对齐）
## - 无锚点时 alpha 兜底现算（与服务端 anchors.ts 同规则）
## - 前后三明治双片结构（翻面 rotation.y=PI 后仍有一片朝相机）
## - 重复挂/摘下/锚点后到重摆
## 运行: godot --headless --script res://test/test_character_anchors.gd

var fails := 0

func _init() -> void:
	# 合成立绘 100×200：身体 x∈[20,80] y∈[10,190]（头顶行 y=10 中心 x=50）
	var img := Image.create(100, 200, false, Image.FORMAT_RGBA8)
	for y in range(10, 191):
		for x in range(20, 81):
			img.set_pixel(x, y, Color(0.8, 0.4, 0.2, 1.0))
	var tex := ImageTexture.create_from_image(img)
	var sticker := ImageTexture.create_from_image(Image.create(64, 64, false, Image.FORMAT_RGBA8))

	var npc := PaperCharacter.new()
	root.add_child(npc)
	npc.setup(tex, Color.WHITE, "测试角色")
	var w := 100.0 * npc.pixel_size
	var h := 200.0 * npc.pixel_size

	# ── 服务端锚点 → 局部坐标 ───────────────────────────────────────────────
	npc.set_anchors({
		"headTop": { "x": 0.5, "y": 0.05 },
		"handL": { "x": 0.25, "y": 0.55 },
		"handR": { "x": 0.75, "y": 0.55 },
	})
	npc.attach_sticker("headTop", sticker)
	npc.attach_sticker("handL", sticker)
	var head: Node3D = npc.get_node("sticker_headTop")
	var hand: Node3D = npc.get_node("sticker_handL")
	_check("头顶 x 居中", absf(head.position.x) < 0.001, true)
	var sh := float(head.get_meta("sticker_h"))
	_check("头顶底边对齐锚点(y=0.95h+半贴纸高)", absf(head.position.y - (0.95 * h + sh * 0.5)) < 0.001, true)
	_check("左手 x=(0.25-0.5)w", absf(hand.position.x - (-0.25 * w)) < 0.001, true)
	_check("左手中心对齐(y=0.45h)", absf(hand.position.y - 0.45 * h) < 0.001, true)

	# ── 三明治结构：两片 ±STICKER_Z，背片预转 PI ────────────────────────────
	var quads := head.get_children()
	_check("每槽两片", quads.size(), 2)
	var zs := []
	var back_flipped := false
	for q in quads:
		zs.append(snappedf((q as MeshInstance3D).position.z, 0.001))
		if (q as MeshInstance3D).position.z < 0.0 and absf(absf((q as MeshInstance3D).rotation.y) - PI) < 0.001:
			back_flipped = true
	zs.sort()
	_check("前后片 z=±0.02", zs, [-0.02, 0.02])
	_check("背片预转 PI", back_flipped, true)

	# ── 翻面：子节点随父转（结构性保证），无需锚点镜像 ──────────────────────
	npc.rotation.y = PI
	_check("翻面后 holder 局部位不变(跟父转)", absf(hand.position.x - (-0.25 * w)) < 0.001, true)
	npc.rotation.y = 0.0

	# ── 无锚点：alpha 兜底现算 ──────────────────────────────────────────────
	var npc2 := PaperCharacter.new()
	root.add_child(npc2)
	npc2.setup(tex, Color.WHITE, "兜底角色")
	npc2.attach_sticker("headTop", sticker)
	var fb: Dictionary = npc2._anchors.get("headTop", {})
	_check("兜底头顶 y≈首个不透明行", absf(float(fb.get("y", -1)) - 10.0 / 199.0) < 0.01, true)
	_check("兜底头顶 x≈身体中心", absf(float(fb.get("x", -1)) - 50.0 / 99.0) < 0.02, true)
	npc2.attach_sticker("handL", sticker)
	var fbl: Dictionary = npc2._anchors.get("handL", {})
	_check("兜底左手=左缘内收 5%", absf(float(fbl.get("x", -1)) - (20.0 + 5.0) / 99.0) < 0.02, true)

	# ── 重复挂=换、摘下=清、锚点后到重摆 ───────────────────────────────────
	npc.attach_sticker("headTop", sticker)
	var count := 0
	for c in npc.get_children():
		# detach 会给垂死 holder 改名让位（sticker_headTop_dying），存活的保留槽位名
		if String(c.name) == "sticker_headTop" and not c.is_queued_for_deletion():
			count += 1
	_check("重复挂同槽只剩一份", count, 1)
	npc.detach_sticker("handL")
	_check("摘下后槽位清空", npc._stickers.has("handL"), false)
	var head2: Node3D = npc._stickers["headTop"]
	npc.set_anchors({ "headTop": { "x": 0.3, "y": 0.1 }, "handL": { "x": 0.2, "y": 0.5 }, "handR": { "x": 0.8, "y": 0.5 } })
	_check("锚点后到已挂贴纸重摆", absf(head2.position.x - (-0.2 * w)) < 0.001, true)

	npc.free()
	npc2.free()
	print("test_character_anchors: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	print("  FAIL %s: got %s want %s" % [what, str(got), str(want)])
	fails += 1
	return 1
