extends SceneTree
## PaperCharacter.portrait_tex()：委托 chip 用的小头像来源。
## 静态角色 → 整张立绘原样返回；动画角色 → 裁图集第 0 帧（cellW×cellH 起于原点）——
## 直接把整张 sheet 塞进 TextureRect 会把多帧糊成一片。无纹理 → null（chip 回落类型图标，不崩）。
## 运行: Godot --headless --path . --script res://test/test_task_chip_portrait.gd

var _fails := 0

func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s %s" % [name, detail])
		_fails += 1

func _init() -> void:
	# ① 静态角色：portrait_tex 原样返回立绘
	var simg := Image.create(40, 60, false, Image.FORMAT_RGBA8)
	simg.fill(Color(0, 1, 0, 1))
	var stex := ImageTexture.create_from_image(simg)
	var sc := PaperCharacter.new()
	get_root().add_child(sc)
	sc.setup(stex, Color.WHITE, "小静")
	_ok("静态角色 portrait_tex == 立绘本身", sc.portrait_tex() == stex)

	# ② 动画角色：portrait_tex 裁出第 0 帧（AtlasTexture，region = 单格尺寸）
	var aimg := Image.create(80, 90, false, Image.FORMAT_RGBA8)
	aimg.fill(Color(1, 0, 0, 1))
	var atlas := ImageTexture.create_from_image(aimg)
	var meta := {
		"cols": 4, "rows": 3, "frameCount": 10, "fps": 8, "cellW": 20, "cellH": 30,
		"clips": { "idle": { "start": 0, "count": 4 } },
	}
	var ac := PaperCharacter.new()
	get_root().add_child(ac)
	ac.play_anim(atlas, meta, 6.0)
	var p := ac.portrait_tex()
	_ok("动画角色 portrait_tex 是 AtlasTexture", p is AtlasTexture)
	if p is AtlasTexture:
		var at := p as AtlasTexture
		_ok("裁的是整张动画图集", at.atlas == atlas)
		_ok("region = 单格尺寸(第 0 帧)", at.region == Rect2(0.0, 0.0, 20.0, 30.0), "got %s" % at.region)

	# ③ 无纹理角色：portrait_tex 返回 null（chip 据此回落到类型图标，不崩）
	var ec := PaperCharacter.new()
	get_root().add_child(ec)
	_ok("无纹理 portrait_tex 返回 null", ec.portrait_tex() == null)

	quit(_fails)
