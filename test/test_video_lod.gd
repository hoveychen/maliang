extends SceneTree
## 焦点视频 LOD 原语（PaperCharacter.start_video_lod/set_video_clip/stop_video_lod）的冒烟测试：
## 验证「图集↔视频」材质与状态的 swap 逻辑、隐藏 VideoStreamPlayer 的属性（★只取纹理不自绘）、
## 段切换、缺段回落、以及 stop 后几何复原。headless 不真解码视频，故只断状态机与几何数学，不断帧像素。
## 运行: Godot --headless --path . --script res://test/test_video_lod.gd

var _fails := 0

func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s %s" % [name, detail])
		_fails += 1

func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s want %s" % [got, want])

func _atlas() -> Dictionary:
	# 7 帧 idle/talking 两段图集，cell 20×30，与服务端下发形状一致。
	var img := Image.create(80, 60, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	return {
		"tex": ImageTexture.create_from_image(img),
		"meta": {
			"cols": 4, "rows": 2, "frameCount": 7, "fps": 8, "cellW": 20, "cellH": 30,
			"width": 80, "height": 60,
			"clips": { "idle": { "start": 0, "count": 4 }, "talking": { "start": 4, "count": 3 } },
		},
	}

func _fake_video_tex(w: int, h: int) -> Texture2D:
	return ImageTexture.create_from_image(Image.create(w, h, false, Image.FORMAT_RGBA8))

## 极小真 ogv 测试素材（32×32 绿幕 6 帧，由 Docker prod 镜像的 libtheora 生成）。
const TINY_OGV := "res://test/fixtures/tiny.ogv"
func _load_ogv() -> VideoStream:
	return load(TINY_OGV) as VideoStream

func _find_vsp(pc: PaperCharacter) -> VideoStreamPlayer:
	for c in pc.get_children():
		if c is VideoStreamPlayer:
			return c
	return null

func _init() -> void:
	var a := _atlas()

	# ── ① 图集→视频 swap ───────────────────────────────────────────────────
	var pc := PaperCharacter.new()
	get_root().add_child(pc)
	pc.play_anim(a["tex"], a["meta"], 6.0)
	var atlas_mat := pc.material_override
	_ok("进视频前是图集主材质", atlas_mat == pc._mat)
	_ok("进视频前 is_video_lod=false", not pc.is_video_lod())

	var idle := _load_ogv()
	var talking := _load_ogv()
	_ok("测试素材 tiny.ogv 加载成功", idle != null)
	pc.start_video_lod(idle, talking, 6.0)
	_ok("start 后 is_video_lod=true", pc.is_video_lod())
	# ★首帧到手前材质仍是图集——不透明闪、平台不支持也留图集（P4 兜底）
	_ok("start 后材质仍是图集（首帧前不换）", pc.material_override == atlas_mat)
	_eq("起手段是 idle", pc.current_video_clip(), "idle")

	# ── ② 隐藏 VideoStreamPlayer 的属性（★核心坑：只取纹理不自绘）───────────────
	var vsp := _find_vsp(pc)
	_ok("建了 VideoStreamPlayer 子节点", vsp != null)
	_ok("VSP visible=false（不自绘到 2D 层）", not vsp.visible)
	_ok("VSP 挪出屏幕", vsp.position.x < -1000.0 and vsp.position.y < -1000.0)
	_ok("VSP loop=true", vsp.loop)
	_ok("VSP 静音", vsp.volume_db <= -60.0)
	_ok("VSP stream 指向 idle", vsp.stream == idle)

	# 真解码冒烟：跑几帧让 theora 吐首帧，首帧到手时 _process 才把材质无缝换成视频材质并喂 video_tex。
	var swapped := false
	for i in range(120):
		await process_frame
		if pc.material_override == pc._video_mat:
			swapped = true
			break
	_ok("首帧到手后无缝换成视频材质", swapped)
	_ok("视频材质 shader 是 chroma_video", (pc.material_override as ShaderMaterial).shader == load("res://shaders/chroma_video.gdshader"))
	_ok("视频材质无 xray next_pass", (pc.material_override as ShaderMaterial).next_pass == null)
	_ok("解码纹理已喂进 video_tex", (pc.material_override as ShaderMaterial).get_shader_parameter("video_tex") != null)

	# ── ③ 段切换：idle↔talking 换 stream（单路解码）──────────────────────────
	pc.set_video_clip("talking")
	_eq("切到 talking", pc.current_video_clip(), "talking")
	_ok("talking stream 换上", vsp.stream == talking)
	pc.set_video_clip("idle")
	_eq("切回 idle", pc.current_video_clip(), "idle")
	_ok("idle stream 换回", vsp.stream == idle)

	# ── ④ 几何数学：视频宽高比 + 脚底对齐（headless 不解码，直接喂假纹理算）────────
	pc._apply_video_geometry(_fake_video_tex(864, 496))
	var q := pc.mesh as QuadMesh
	var frame_h := 6.0 / PaperCharacter.VIDEO_FILL
	var frame_w := frame_h * (864.0 / 496.0)
	_ok("quad 高 = 目标身高/占比", is_equal_approx(q.size.y, frame_h), "%f vs %f" % [q.size.y, frame_h])
	_ok("quad 宽按视频宽高比", is_equal_approx(q.size.x, frame_w), "%f vs %f" % [q.size.x, frame_w])
	_ok("脚底落在原点(center_offset.y)", is_equal_approx(q.center_offset.y, frame_h * (PaperCharacter.VIDEO_FOOT - 0.5)))
	_ok("水平居中(center_offset.x=0)", is_equal_approx(q.center_offset.x, 0.0))

	# ── ⑤ stop 撤回：材质换回图集、几何复原、无 vsp 残留 ──────────────────────
	pc.stop_video_lod()
	_ok("stop 后 is_video_lod=false", not pc.is_video_lod())
	_eq("stop 后段清空", pc.current_video_clip(), "")
	_ok("stop 后材质换回图集主材质", pc.material_override == pc._mat)
	_ok("stop 后 _vsp 引用清空", pc._vsp == null)
	# 几何复原 = 按图集单格算（cellW=20, cellH=30, world_height=6 → pixel_size=0.2 → w=4,h=6）
	var rq := pc.mesh as QuadMesh
	_ok("stop 后 quad 高复原到图集单格", is_equal_approx(rq.size.y, 6.0), "%f" % rq.size.y)
	_ok("stop 后 quad 宽复原到图集单格", is_equal_approx(rq.size.x, 4.0), "%f" % rq.size.x)
	pc.stop_video_lod()  # 幂等：再 stop 一次不炸
	_ok("stop 幂等", not pc.is_video_lod())
	pc.queue_free()

	# ── ⑥ talking 缺省（只有 idle 原片）：set_video_clip('talking') 保持 idle ────
	var pc2 := PaperCharacter.new()
	get_root().add_child(pc2)
	pc2.play_anim(a["tex"], a["meta"], 6.0)
	pc2.start_video_lod(_load_ogv())  # 不传 talking
	_eq("只有 idle 时起手 idle", pc2.current_video_clip(), "idle")
	pc2.set_video_clip("talking")
	_eq("缺 talking 原片 → 保持 idle", pc2.current_video_clip(), "idle")
	pc2.stop_video_lod()
	pc2.queue_free()

	# ── ⑦ idle_stream 为 null：start 空操作，不进视频档 ─────────────────────
	var pc3 := PaperCharacter.new()
	get_root().add_child(pc3)
	pc3.play_anim(a["tex"], a["meta"], 6.0)
	pc3.start_video_lod(null)
	_ok("idle_stream=null → 不进视频档", not pc3.is_video_lod())
	_ok("idle_stream=null → 材质仍是图集", pc3.material_override == pc3._mat)
	pc3.queue_free()

	# ── ⑧ 坏流兜底（P4 平台不支持/坏 ogv）：永远不吐帧 → 材质始终留图集，绝不透明闪 ────
	var pc4 := PaperCharacter.new()
	get_root().add_child(pc4)
	pc4.play_anim(a["tex"], a["meta"], 6.0)
	var atlas_mat4 := pc4.material_override
	var broken := VideoStreamTheora.new()
	broken.file = "res://test/fixtures/__nonexistent__.ogv"  # 解不出帧
	pc4.start_video_lod(broken)
	for i in range(15):
		await process_frame
	_ok("坏流：材质始终留图集（无透明闪）", pc4.material_override == atlas_mat4)
	pc4.stop_video_lod()
	pc4.queue_free()

	if _fails == 0:
		print("video_lod tests PASS")
	else:
		printerr("video_lod tests FAILED: %d" % _fails)
	quit(_fails)
