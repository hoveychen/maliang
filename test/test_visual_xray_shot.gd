extends SceneTree
## 临时视觉验证（不进回测）：纸片角色被不透明方块遮挡时，穿透 pass 应画出半透明剪影。
## 带窗跑（headless 假渲染器不填 DEPTH_TEXTURE，穿透判定失效）：
##   godot --path . --quit-after 30 --script res://test/test_visual_xray_shot.gd
## 输出 /tmp 截图 + 断言：被遮挡区像素≠纯方块色（剪影绘制），旁边纯方块区=方块色。

var frame := 0
var cam: Camera3D
var chr: PaperCharacter
var box: MeshInstance3D

func _initialize() -> void:
	var w := root
	w.transparent_bg = false
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.9, 0.95, 1.0)
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	cam = Camera3D.new()
	cam.fov = 50.0
	cam.position = Vector3(0, 1.6, 7)
	cam.look_at(Vector3(0, 1.6, 0), Vector3.UP)
	root.add_child(cam)

	# 角色：128×256 纯红立绘（脚底锚点），约 3.2m 高，站在原点
	var img := Image.create(128, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.9, 0.1, 0.1, 1.0))
	var tex := ImageTexture.create_from_image(img)
	chr = PaperCharacter.new()
	root.add_child(chr)
	chr.setup(tex, Color.WHITE, "test")

	# 遮挡物：不透明灰方块，夹在相机(z=7)与角色(z=0)之间，挡住角色中段
	box = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.4, 1.4, 0.4)
	box.mesh = bm
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.4, 0.4, 0.45)
	box.material_override = sm
	box.position = Vector3(0, 1.6, 3.0)
	root.add_child(box)

	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame < 6:
		return
	var vp := root.get_viewport()
	var imgc := vp.get_texture().get_image()
	imgc.save_png("/tmp/xray_shot.png")
	var w := imgc.get_width()
	var h := imgc.get_height()
	# 按图像像素尺寸取点（视口 stretch 逻辑尺寸≠像素尺寸，之前用 visible_rect 采错）
	var cx := w / 2
	var cy := h / 2
	var behind := imgc.get_pixel(cx, cy)                    # 角色被方块挡住处（轮廓内）
	var boxside := imgc.get_pixel(cx + int(w * 0.08), cy)   # 方块内、角色红轮廓外侧（应为纯灰）
	var boxonly := imgc.get_pixel(cx - int(w * 0.08), cy)   # 对侧纯灰方块
	print("[xray] size=%dx%d behind=%s boxside=%s boxonly=%s" % [w, h, behind, boxside, boxonly])
	# 断言：被遮挡处应带红色调（剪影混入原色）；方块两侧纯方块处红分量应很低
	var behind_reddish := behind.r > behind.b + 0.08
	var boxside_plain := boxside.r < 0.55 and absf(boxside.r - boxside.b) < 0.12
	print("[xray] behind_reddish=%s boxside_plain=%s" % [behind_reddish, boxside_plain])
	var fails := 0
	if not behind_reddish:
		print("  FAIL 被遮挡区未见剪影红调"); fails += 1
	if not boxside_plain:
		print("  FAIL 方块外侧非纯方块色（剪影溢出/未裁形）"); fails += 1
	if fails == 0:
		print("  PASS 穿透剪影只在被遮挡的角色轮廓内绘制")
	quit(fails)
