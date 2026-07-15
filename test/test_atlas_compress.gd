extends SceneTree
## 动画图集的显存块压缩（Api._compress_for_gpu）。
## 三段图集未压缩 RGBA8 ≈ 17MB 显存/角色，一个场景八九个村民就把老 Mali 平板压垮；
## 块压缩降到 1 字节/像素（4×）。这里钉三件事：真压了、省了 4 倍、压完几何仍然对。
## 运行: Godot --headless --path . --script res://test/test_atlas_compress.gd

var _fails := 0

func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s %s" % [name, detail])
		_fails += 1

func _init() -> void:
	var api := Api.new()
	get_root().add_child(api)

	# 仿真实三段图集：cellW=200 cellH=256（都是 4 的倍数，服务端保证），10×10 格。
	var W := 2000
	var H := 2560
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.9, 0.3, 0.2, 1.0))
	var raw_bytes := img.get_data().size()

	api._compress_for_gpu(img)

	# 桌面(s3tc)/移动(etc2) 都应压得动；两者都没有的平台会跳过压缩——那时本测试的
	# 压缩断言不适用，只验「没把图弄坏」。
	var can := OS.has_feature("s3tc") or OS.has_feature("etc2")
	if can:
		_ok("图集被压缩了", img.is_compressed())
		var packed := img.get_data().size()
		_ok("显存降到 1/4 左右", packed * 3 < raw_bytes,
			"压缩后 %d 字节 vs 未压缩 %d 字节" % [packed, raw_bytes])
	else:
		print("  skip 本平台无 s3tc/etc2，跳过压缩断言")
	# 无论压没压，尺寸都不能变——变了所有 UV 分格就全错位
	_ok("压缩不改尺寸（改了则 UV 分格全错）", img.get_width() == W and img.get_height() == H,
		"%dx%d" % [img.get_width(), img.get_height()])

	# 压完的 Image 仍能建成纹理，并喂给 PaperCharacter 正常算几何。
	var tex := ImageTexture.create_from_image(img)
	_ok("压缩后仍能建成纹理", tex != null)

	var meta := {
		"cols": 10, "rows": 10, "frameCount": 93, "fps": 8, "cellW": 200, "cellH": 256,
		"width": W, "height": H,
		"clips": {
			"idle": { "start": 0, "count": 31 },
			"moving": { "start": 31, "count": 31 },
			"talking": { "start": 62, "count": 31 },
		},
	}
	var pc := PaperCharacter.new()
	get_root().add_child(pc)
	pc.play_anim(tex, meta, 6.0)
	# 几何按单格 cellH 归一化：6.0/256 = 0.0234375
	_ok("压缩图集的 pixel_size 仍按 cellH 算", is_equal_approx(pc.pixel_size, 6.0 / 256.0),
		"%f" % pc.pixel_size)
	_ok("压缩图集的可见身高仍是 6.0", is_equal_approx(pc.visible_height(), 6.0),
		"%f" % pc.visible_height())
	pc.set_clip("talking")
	_ok("压缩图集仍能切段", pc.current_clip() == "talking")
	pc.queue_free()

	# 二次压缩必须是空操作（图集可能被反复取用；重复压会把已压的数据当像素再压一遍）
	var before := img.get_data().size()
	api._compress_for_gpu(img)
	_ok("已压缩的图再压是空操作", img.get_data().size() == before)

	if can:
		_test_cell_bleed(api)

	_test_tex_diag()

	if _fails == 0:
		print("atlas_compress tests PASS")
	else:
		printerr("atlas_compress tests FAILED: %d" % _fails)
	quit(_fails)

## 诊断探针 Api._apply_tex_diag：MALIANG_TEX_DIAG=downsample 时把图集长宽减半做 A/B 隔离
## （证「未压缩村民图集是否吃帧」）。这里钉：置位→尺寸减半、缺省→原样、极小图不塌成 0。
func _test_tex_diag() -> void:
	var a := Image.create(2000, 2560, false, Image.FORMAT_RGBA8)
	Api._apply_tex_diag(a, false)
	_ok("诊断关：尺寸原样", a.get_width() == 2000 and a.get_height() == 2560,
		"%dx%d" % [a.get_width(), a.get_height()])

	var b := Image.create(2000, 2560, false, Image.FORMAT_RGBA8)
	Api._apply_tex_diag(b, true)
	_ok("诊断开：长宽各减半（显存降 4×）", b.get_width() == 1000 and b.get_height() == 1280,
		"%dx%d" % [b.get_width(), b.get_height()])

	var tiny := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	Api._apply_tex_diag(tiny, true)
	_ok("诊断开：极小图不塌成 0", tiny.get_width() >= 1 and tiny.get_height() >= 1,
		"%dx%d" % [tiny.get_width(), tiny.get_height()])

## 块压缩以 4×4 为块。cell 宽不是 4 的倍数时，一个块会横跨相邻两格的边界，把两格的颜色
## 揉进同一个块 —— 播放时上一帧的边缘会渗进这一帧。服务端把 cellW/cellH 对齐到 4 就是为了
## 堵死它（sprite_sheet.ts 的 align4）。
##
## 素材：左格暖色调、右格冷色调，且**每个像素都在变**。像素在变这点很要紧——块压缩每块
## 存两个端点色，纯色块（只有两种颜色）是无损的，拿纯红|纯蓝当素材根本压不出误差，会得到
## 「没串色」的假绿灯（第一版就踩了这个）。真实角色帧是连续色调，一个块里颜色远多于两种，
## 块必须做近似；跨格的块只能拿两个端点去凑两帧的内容，于是把邻帧的颜色揉了进来。
##
## 度量用「边界列误差 / 格内误差」的比值，而不是绝对误差——块压缩本身到处都有误差，
## 只有把它当基线除掉，剩下的才是「串色」这一项。比值 ≈1 = 边界和别处一样干净。
##
## 实测（本机 Godot 4.6）：S3TC 下 cellW=66 的比值是 10.7，cellW=64 是 1.01。
func _test_cell_bleed(_api: Api) -> void:
	var modes: Array = []
	if OS.has_feature("s3tc"):
		modes.append(["S3TC", Image.COMPRESS_S3TC])
	if OS.has_feature("etc2"):
		modes.append(["ETC2", Image.COMPRESS_ETC2])

	var max_unaligned := 0.0
	for m in modes:
		var tag := String(m[0])
		var mode := m[1] as Image.CompressMode
		var aligned := _seam_ratio(64, mode)   # 64 是 4 的倍数 → 格边界落在块边界上
		var unaligned := _seam_ratio(66, mode) # 66 不是 → 格边界切进块中间
		max_unaligned = maxf(max_unaligned, unaligned)
		_ok("%s: cell 对齐到 4 → 格边界不比别处脏（比值 %.2f）" % [tag, aligned], aligned < 1.2,
			"比值 %.2f 应 ≈1（对照：不对齐时 %.2f）" % [aligned, unaligned])

	# 前提校验：素材必须真能测出串色，否则上面那条断言是恒真的、抓不到任何回归。
	# （只要有一种格式测得出显著串色即可——ETC2 的块内有 4×2/2×4 子块，对半开的边界
	#   比 S3TC 扛得住些，signal 弱；S3TC 下是 10 倍量级。）
	_ok("素材能测出串色（前提成立，否则本测试无意义）", max_unaligned > 2.0,
		"不对齐时的最大比值只有 %.2f，本应显著 >1" % max_unaligned)

## 造一张 2 格图（左格暖调、右格冷调，格宽 cell_w），压缩→解压，
## 返回「左格最后一列的压缩误差 ÷ 左格正中的压缩误差」。≈1 = 边界不脏；>>1 = 邻格串过来了。
func _seam_ratio(cell_w: int, mode: Image.CompressMode) -> float:
	var orig := _seam_image(cell_w)
	var dec := _seam_image(cell_w)
	if dec.compress(mode, Image.COMPRESS_SOURCE_SRGB) != OK:
		return -1.0
	dec.decompress()
	var boundary := _col_err(orig, dec, cell_w - 1)      # 左格最后一列（紧贴格边界）
	var interior := _col_err(orig, dec, int(cell_w / 2)) # 左格正中（基线：普通块压缩误差）
	return boundary / maxf(interior, 0.0001)

func _seam_image(cell_w: int) -> Image:
	var h := 64
	var img := Image.create(cell_w * 2, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(cell_w * 2):
			var t := 0.5 + 0.5 * sin(float(x) * 1.7 + float(y) * 0.9) # 每像素都变
			if x < cell_w:
				img.set_pixel(x, y, Color(0.55 + 0.4 * t, 0.30 * t, 0.05, 1.0)) # 暖
			else:
				img.set_pixel(x, y, Color(0.05, 0.30 * t, 0.55 + 0.4 * t, 1.0)) # 冷
	return img

## 某一列的平均 RGB 误差（解压后 vs 原图）。
func _col_err(orig: Image, dec: Image, x: int) -> float:
	var s := 0.0
	for y in range(orig.get_height()):
		var a := orig.get_pixel(x, y)
		var b := dec.get_pixel(x, y)
		s += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
	return s / float(orig.get_height()) / 3.0
