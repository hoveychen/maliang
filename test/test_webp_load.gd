extends SceneTree
## 验证 Godot 能解码带 alpha 的 WebP(idle 动画图集用 WebP 传输的前提)。
## save_webp_to_buffer → load_webp_from_buffer round-trip,确认编解码可用且 alpha 保留。
## 运行: Godot --headless --path . --script res://test/test_webp_load.gd

func _init() -> void:
	var fails := 0

	# 造一张带透明的图:左半不透明红,右半全透明
	var w := 40
	var h := 40
	var src := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			if x < w / 2:
				src.set_pixel(x, y, Color(1, 0, 0, 1))
			else:
				src.set_pixel(x, y, Color(0, 0, 0, 0))

	var buf := src.save_webp_to_buffer(false) # 无损,保 alpha
	if buf.size() < 12:
		printerr("  FAIL save_webp 产出为空"); quit(1); return
	# magic: RIFF....WEBP
	var is_webp := buf[0] == 0x52 and buf[1] == 0x49 and buf[2] == 0x46 and buf[3] == 0x46 \
		and buf[8] == 0x57 and buf[9] == 0x45 and buf[10] == 0x42 and buf[11] == 0x50
	fails += 0 if is_webp else 1
	print("  ok save_webp 产出 WebP magic" if is_webp else "  FAIL 非 WebP magic")

	var out := Image.new()
	var e := out.load_webp_from_buffer(buf)
	if e != OK:
		printerr("  FAIL load_webp_from_buffer err=%d" % e); quit(1); return
	print("  ok load_webp_from_buffer")

	fails += 0 if (out.get_width() == w and out.get_height() == h) else 1
	print("  ok 尺寸保持 %dx%d" % [out.get_width(), out.get_height()])

	# alpha 保留:左半不透明、右半透明
	var left_a := out.get_pixel(5, 20).a
	var right_a := out.get_pixel(35, 20).a
	if left_a > 0.9 and right_a < 0.1:
		print("  ok alpha 保留(左实右透)")
	else:
		printerr("  FAIL alpha 丢失 left=%f right=%f" % [left_a, right_a]); fails += 1

	if fails == 0:
		print("webp_load tests PASS")
	else:
		printerr("webp_load tests FAILED: %d" % fails)
	quit(fails)
