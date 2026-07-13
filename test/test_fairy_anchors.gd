extends SceneTree
## 图集(sprite-sheet)模式锚点兜底(player-fairy-anchors P2):小仙子等以本地 WebP 图集渲染的
## 角色走 sheet 模式,此前 _fallback_anchor 取不到 per-frame Image → 一律固定比例(0.5/0.02、
## 0.25/0.75),根本没逐像素标定。修复后应解码 atlas 的 cell0、在单格内跑同一套 alpha 启发式,
## 得到贴合该帧实际形状的锚点(通用,不止仙子)。
## 运行: godot --headless --script res://test/test_fairy_anchors.gd

var fails := 0

func _init() -> void:
	# 合成 2×1 图集(cellW=50 cellH=60,共 100×60)。cell0 放一个偏左的身体:
	# x∈[10,30]、y∈[6,58]。cell1(x≥50)放不同形状,确保只扫 cell0 不被隔壁格干扰。
	var atlas := Image.create(100, 60, false, Image.FORMAT_RGBA8)
	for y in range(6, 59):
		for x in range(10, 31):
			atlas.set_pixel(x, y, Color(0.7, 0.4, 0.9, 1.0))
	for y in range(0, 60):        # cell1 整格填满 → 若误扫会把锚点拉到右边
		for x in range(50, 100):
			atlas.set_pixel(x, y, Color(0.2, 0.8, 0.3, 1.0))
	var tex := ImageTexture.create_from_image(atlas)

	var npc := PaperCharacter.new()
	root.add_child(npc)
	npc.setup(tex, Color.WHITE, "图集角色")
	npc.play_anim(tex, { "cols": 2, "rows": 1, "frameCount": 2, "fps": 8, "cellW": 50, "cellH": 60 }, 1.2)

	# cell0 内理论值：headTop=首个不透明行(y=6)中心(x=20) → (20/49, 6/59)=(0.408, 0.102)；
	# hand 行=int(0.55*59)=32,身体 x∈[10,30],inset=0.05*50=2.5 → handL=(12.5/49)=0.255、handR=(27.5/49)=0.561。
	var head: Dictionary = npc._fallback_anchor("headTop")
	var hl: Dictionary = npc._fallback_anchor("handL")
	var hr: Dictionary = npc._fallback_anchor("handR")
	_near("headTop.x 按 cell0 形状算(非固定0.5)", float(head.get("x", -9)), 0.408)
	_near("headTop.y 按 cell0 形状算(非固定0.02)", float(head.get("y", -9)), 0.102)
	_near("handL.x 在 cell0 内", float(hl.get("x", -9)), 0.255)
	_near("handR.x 在 cell0 内(非固定0.75)", float(hr.get("x", -9)), 0.561)

	if fails == 0:
		print("fairy_anchors PASS")
	else:
		printerr("fairy_anchors FAILED: %d" % fails)
	quit(fails)

func _near(name: String, got: float, want: float) -> void:
	if absf(got - want) < 0.01:
		print("  ok %s (%.3f)" % [name, got])
	else:
		fails += 1
		printerr("  FAIL %s: got=%.3f want=%.3f" % [name, got, want])
