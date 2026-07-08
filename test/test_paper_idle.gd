extends SceneTree
## PaperCharacter.play_idle 的独立测试：sprite-sheet 图集切换后，
## 几何按单格 cellW×cellH 归一化到期望世界高度（不是整张图集尺寸）。
## 运行: Godot --headless --path . --script res://test/test_paper_idle.gd

func _check(name: String, got: float, want: float, eps := 0.001) -> int:
	if absf(got - want) <= eps:
		print("  ok %s" % name)
		return 0
	printerr("  FAIL %s: got %f want %f" % [name, got, want])
	return 1

func _init() -> void:
	var fails := 0

	# 造一张 2x2 图集纹理：cellW=20 cellH=30 → 整图 40x60
	var img := Image.create(40, 60, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	var atlas := ImageTexture.create_from_image(img)
	var meta := {
		"cols": 2, "rows": 2, "frameCount": 3, "fps": 8, "cellW": 20, "cellH": 30,
		"width": 40, "height": 60,
	}

	var pc := PaperCharacter.new()
	get_root().add_child(pc)

	# 期望世界高度 6.0 米 → pixel_size = 6/cellH = 6/30 = 0.2
	pc.play_idle(atlas, meta, 6.0)

	fails += _check("pixel_size 按 cellH 算", pc.pixel_size, 0.2)

	# 几何按单格算：w = cellW*ps = 20*0.2 = 4.0；h = cellH*ps = 30*0.2 = 6.0（= 世界高度）
	var q := pc.mesh as QuadMesh
	fails += _check("quad 宽 = cellW*ps", q.size.x, 4.0)
	fails += _check("quad 高 = 世界高度", q.size.y, 6.0)

	# 若误用整张图集尺寸，高会是 60*0.2=12（世界高度翻倍）——本测试正是防这个回归
	fails += _check("锚点脚底 offset.y = cellH/2", pc.offset.y, 15.0)

	pc.queue_free()

	if fails == 0:
		print("paper_idle tests PASS (4/4)")
	else:
		printerr("paper_idle tests FAILED: %d" % fails)
	quit(fails)
