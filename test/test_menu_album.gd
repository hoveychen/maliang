extends SceneTree
## menu 相册轮播冒烟（menu-dynamic P3）。验证：
##  1) album_paths 纯函数：数出 ≥2 张、剥净 .import/.remap 包装名、有序稳定；
##  2) 实例化 menu.tscn：撕纸卡/相册层结构在，卡上挂着点点+标题+箭头；
##  3) _step_album 推进：跨过 ALBUM_CYCLE 换张（idx 前进、front 换贴图、back 开始余段），
##     叠化结束后 back 回收、front alpha 归 1。
## 运行: godot --headless --path . --script res://test/test_menu_album.gd

var _ran := false
var fails := 0

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ✓ %s" % name)
	else:
		printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
		fails += 1

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true

	print("[album_paths：纯函数]")
	var paths: Array = load("res://scripts/menu.gd").album_paths()
	_check("张数 ≥ 2", paths.size() >= 2, true)
	var clean := true
	for p in paths:
		if String(p).ends_with(".import") or String(p).ends_with(".remap"):
			clean = false
	_check("无 .import/.remap 包装名", clean, true)
	var sorted_copy := paths.duplicate()
	sorted_copy.sort()
	_check("有序（轮播次序稳定）", paths, sorted_copy)

	print("[menu 场景：撕纸卡版式结构]")
	var menu: Control = (load("res://menu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	var card: Node = menu.get_node_or_null("MenuCard")
	_check("撕纸卡在", card != null, true)
	_check("卡上有内容（点点/标题/箭头）", card != null and card.get_child_count() >= 3, true)
	var album: Node = menu.get_node_or_null("Album")
	_check("相册层在", album != null, true)
	_check("相册层双 rect", album != null and album.get_child_count() == 2, true)
	_check("相册贴图已载", (menu.get("_album") as Array).size(), paths.size())

	print("[_step_album：换张与叠化]")
	var front0: TextureRect = menu.get("_ph_front")
	var tex0: Texture2D = front0.texture
	_check("首张就位", tex0, (menu.get("_album") as Array)[0])
	# 跨过 ALBUM_CYCLE：应换张——idx 前进、front/back 互换、front 换下一张贴图开始淡入
	menu._step_album(7.2)
	_check("换张后 idx=1", menu.get("_album_idx"), 1)
	var front1: TextureRect = menu.get("_ph_front")
	_check("front 换了贴图", front1.texture, (menu.get("_album") as Array)[1])
	_check("上一张退居 back 可见", (menu.get("_ph_back") as TextureRect).visible, true)
	_check("front 从透明淡入", front1.modulate.a < 1.0, true)
	# 走完叠化：back 回收、front 完全不透明
	menu._step_album(menu.ALBUM_FADE + 0.1)
	_check("叠化毕 back 回收", (menu.get("_ph_back") as TextureRect).visible, false)
	_check("叠化毕 front 全显", front1.modulate.a, 1.0)
	# Ken Burns 变换在动：缩放 > 1（永远处于放大出画状态才有推拉余量）
	_check("KB 缩放 >1", front1.scale.x > 1.0, true)

	menu.queue_free()
	if fails == 0:
		print("test_menu_album: 全部通过")
	else:
		printerr("test_menu_album: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)
