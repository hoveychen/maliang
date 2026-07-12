extends SceneTree
## 临时视觉验证(不进回测): 真角色立绘按 vision 锚点戴帽/持物的观感。
## 素材: /tmp/anchor_demo_sprite.png(prod 舞舞兔立绘)+打包贴纸;锚点用 PoC 实测值。
## 带窗跑:
##   godot --path . --quit-after 30 --script res://test/test_visual_anchor_shot.gd
## 输出 /tmp/anchor_shot.png(正面) 与 /tmp/anchor_shot_flip.png(翻面)。

var frame := 0
var npc: PaperCharacter

func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var img := Image.load_from_file("/tmp/anchor_demo_sprite.png")
	var tex := ImageTexture.create_from_image(img)
	npc = PaperCharacter.new()
	world.add_child(npc)
	npc.setup(tex, Color.WHITE, "舞舞兔")
	npc.set_anchors({
		"headTop": { "x": 0.481, "y": 0.242 },  # PoC 实测:两耳之间戴帽位(alpha 会点到耳尖)
		"handL": { "x": 0.234, "y": 0.707 },
		"handR": { "x": 0.761, "y": 0.668 },
	})
	npc.attach_sticker("headTop", load("res://assets/stickers/mushroom.webp"))
	npc.attach_sticker("handL", load("res://assets/stickers/flag.webp"))
	npc.attach_sticker("handR", load("res://assets/stickers/heart.webp"))

	var cam := Camera3D.new()
	world.add_child(cam)
	cam.position = Vector3(0.0, 1.8, 5.2)
	cam.look_at(Vector3(0.0, 1.7, 0.0))
	cam.current = true
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.92, 0.95, 0.9)
	env.environment = e
	world.add_child(env)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame == 8:
		root.get_viewport().get_texture().get_image().save_png("/tmp/anchor_shot.png")
		npc.rotation.y = PI # 翻面:三明治背片顶上,贴纸应仍可见(镜像)
	if frame == 14:
		root.get_viewport().get_texture().get_image().save_png("/tmp/anchor_shot_flip.png")
		print("[anchor] saved /tmp/anchor_shot.png + _flip.png")
		quit(0)
