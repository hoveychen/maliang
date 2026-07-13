extends SceneTree
## PaperCharacter 多段动画（idle/moving/talking）：切段只动 shader 的 sheet_start/sheet_frames，
## 几何（pixel_size / quad 尺寸 / 脚底 offset）必须纹丝不动——服务端三段共用一个裁剪盒，
## 客户端若在切段时重算几何，角色身高就会在走起来/说起话时抽一下。
## 运行: Godot --headless --path . --script res://test/test_paper_clips.gd

var _fails := 0

func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s %s" % [name, detail])
		_fails += 1

func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s want %s" % [got, want])

## 取主材质的 shader 参数（切段的唯一可见效果）。
func _sp(pc: PaperCharacter, key: String) -> Variant:
	return (pc.material_override as ShaderMaterial).get_shader_parameter(key)

func _init() -> void:
	# 10 帧的三段图集：idle[0,4) moving[4,7) talking[7,10)，4×3 网格，cell 20×30。
	var img := Image.create(80, 90, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	var atlas := ImageTexture.create_from_image(img)
	var meta := {
		"cols": 4, "rows": 3, "frameCount": 10, "fps": 8, "cellW": 20, "cellH": 30,
		"width": 80, "height": 90,
		"clips": {
			"idle": { "start": 0, "count": 4 },
			"moving": { "start": 4, "count": 3 },
			"talking": { "start": 7, "count": 3 },
		},
	}

	var pc := PaperCharacter.new()
	get_root().add_child(pc)
	pc.play_anim(atlas, meta, 6.0)

	# ① 落地即 idle 段
	_eq("落地播 idle 段", pc.current_clip(), "idle")
	_eq("idle sheet_start", _sp(pc, "sheet_start"), 0)
	_eq("idle sheet_frames = 段内帧数(非整张 10)", _sp(pc, "sheet_frames"), 4)

	# 记下几何基线，切段后必须一模一样
	var ps0 := pc.pixel_size
	var size0 := (pc.mesh as QuadMesh).size
	var off0 := pc.offset
	var h0 := pc.visible_height()

	# ② 切 moving
	pc.set_clip("moving")
	_eq("切到 moving", pc.current_clip(), "moving")
	_eq("moving sheet_start", _sp(pc, "sheet_start"), 4)
	_eq("moving sheet_frames", _sp(pc, "sheet_frames"), 3)

	# ③ 切段不得动几何（本测试的核心）
	_ok("切段后 pixel_size 不变", is_equal_approx(pc.pixel_size, ps0), "%f vs %f" % [pc.pixel_size, ps0])
	_ok("切段后 quad 尺寸不变", (pc.mesh as QuadMesh).size.is_equal_approx(size0))
	_ok("切段后脚底 offset 不变", pc.offset.is_equal_approx(off0))
	_ok("切段后可见身高不变", is_equal_approx(pc.visible_height(), h0), "%f vs %f" % [pc.visible_height(), h0])

	# ④ 切 talking，再切回 idle
	pc.set_clip("talking")
	_eq("talking sheet_start", _sp(pc, "sheet_start"), 7)
	_eq("talking sheet_frames", _sp(pc, "sheet_frames"), 3)
	pc.set_clip("idle")
	_eq("切回 idle sheet_start", _sp(pc, "sheet_start"), 0)
	_eq("切回 idle sheet_frames", _sp(pc, "sheet_frames"), 4)

	# ⑤ 图集里没有的段 → 回落播 idle（而不是"保持当前段不动"）。
	#    这不是洁癖：服务端不生成 moving 段（走路是程序化的），世界层却每帧都请求 "moving"。
	#    若这里保持不动，角色说完话一走动就永远卡在 talking 帧——_clip 停在 "talking"，
	#    之后每帧的 set_clip("moving") 都被当成"没这段，不动"，再也回不到 idle。
	pc.set_clip("talking")
	_eq("先切到 talking", _sp(pc, "sheet_start"), 7)
	pc.set_clip("dancing") # 图集里没有的段
	_eq("缺段回落到 idle 的 start", _sp(pc, "sheet_start"), 0)
	_eq("缺段回落到 idle 的 frames", _sp(pc, "sheet_frames"), 4)
	_eq("current_clip 记的是请求的段名", pc.current_clip(), "dancing")
	pc.queue_free()

	# ⑤b 「说完话走起来」的回归：talking → moving(图集里没有) 必须回到 idle 帧，不能卡在 talking。
	var pc3 := PaperCharacter.new()
	get_root().add_child(pc3)
	# 只有 idle+talking 两段的图集（= 服务端实际下发的形状）
	var two := {
		"cols": 4, "rows": 2, "frameCount": 7, "fps": 8, "cellW": 20, "cellH": 30,
		"width": 80, "height": 60,
		"clips": { "idle": { "start": 0, "count": 4 }, "talking": { "start": 4, "count": 3 } },
	}
	pc3.play_anim(atlas, two, 6.0)
	pc3.set_clip("talking")
	_eq("对话中播 talking", _sp(pc3, "sheet_start"), 4)
	pc3.set_clip("moving") # 说完话走起来；图集里没有 moving
	_eq("走起来 → 回落 idle 帧（不是卡在 talking）", _sp(pc3, "sheet_start"), 0)
	_eq("走起来 → idle 段帧数", _sp(pc3, "sheet_frames"), 4)
	pc3.set_clip("idle")
	_eq("停下 → 仍是 idle 帧", _sp(pc3, "sheet_start"), 0)
	pc3.queue_free()

	# ⑥ v1 老图集（无 clips）：整张图集当 idle 播；set_clip("moving") 是安全空操作。
	#    存量角色在服务端回填完成前就是这个状态，绝不能因此播出空白帧。
	var img2 := Image.create(40, 60, false, Image.FORMAT_RGBA8)
	img2.fill(Color(0, 1, 0, 1))
	var old_atlas := ImageTexture.create_from_image(img2)
	var old_meta := { "cols": 2, "rows": 2, "frameCount": 3, "fps": 8, "cellW": 20, "cellH": 30, "width": 40, "height": 60 }
	var pc2 := PaperCharacter.new()
	get_root().add_child(pc2)
	pc2.play_anim(old_atlas, old_meta, 6.0)
	_eq("v1 图集 sheet_start=0", _sp(pc2, "sheet_start"), 0)
	_eq("v1 图集 sheet_frames=整张帧数", _sp(pc2, "sheet_frames"), 3)
	pc2.set_clip("moving")
	# 播的帧仍是整张图集（= idle）。current_clip() 记的是"请求了什么"，播的帧才是要害。
	_eq("v1 图集切 moving 后仍播整张图集（start）", _sp(pc2, "sheet_start"), 0)
	_eq("v1 图集切 moving 后仍播整张图集（frames）", _sp(pc2, "sheet_frames"), 3)
	pc2.set_clip("talking")
	_eq("v1 图集切 talking 后也仍播整张图集", _sp(pc2, "sheet_frames"), 3)
	pc2.queue_free()

	if _fails == 0:
		print("paper_clips tests PASS")
	else:
		printerr("paper_clips tests FAILED: %d" % _fails)
	quit(_fails)
