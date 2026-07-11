extends SceneTree
## PaperPhone(3D 纸糊双折叠手机)单测：几何姿态/状态机/射线拾取纯数学，headless 无窗可跑。
## 运行: godot --headless --script res://test/test_paper_phone.gd

var _fails := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		printerr("  ✗ ", msg)
		_fails += 1

func _initialize() -> void:
	# _initialize 阶段节点尚未进树（_ready 延迟到首帧、global_transform 不可用），
	# 与 test_phone_menu 同法：挂进 root 后等 ready 再跑断言。
	var phone := PaperPhone.new()
	var cam := Camera3D.new()
	cam.fov = 50.0
	root.add_child(cam)
	root.add_child(phone)
	phone.ready.connect(func() -> void:
		_run(phone, cam)
		print("paper_phone: fails=%d" % _fails)
		quit(_fails))

func _run(phone: PaperPhone, cam: Camera3D) -> void:
	var W := PaperPhone.PANEL_W
	var T := PaperPhone.PANEL_T

	# 初始：收起、隐藏
	_check(phone.state == PaperPhone.State.STOWED, "初始 STOWED")
	_check(not phone.visible, "初始隐藏")

	# ── 合拢正面态 ──
	phone.show_front(false)
	_check(phone.state == PaperPhone.State.FRONT, "show_front → FRONT")
	_check(phone.visible, "FRONT 可见")
	var front_xf := phone.face_transform(PaperPhone.FACE_FRONT)
	_check(front_xf.basis.z.z > 0.99, "正面壳法线朝 +Z(相机)")
	_check(absf(front_xf.origin.x) < 1e-4, "正面壳居中(x≈0)")
	var back_xf := phone.face_transform(PaperPhone.FACE_BACK)
	_check(back_xf.basis.z.z < -0.99, "背面壳法线朝 -Z(背对相机)")
	_check(back_xf.origin.z < -T, "合拢时 B 板叠在 A 板背后")
	_check(absf(back_xf.origin.x) < 1e-4, "合拢时 B 板与 A 板对齐(x≈0)")

	# 正面拾取：中心射线命中 front、uv≈(0.5,0.5)
	var hit := phone.pick(Vector3(0, 0, 2), Vector3(0, 0, -1))
	_check(String(hit.get("face", "")) == PaperPhone.FACE_FRONT, "正面中心射线命中 front")
	if not hit.is_empty():
		var uv: Vector2 = hit["uv"]
		_check(uv.distance_to(Vector2(0.5, 0.5)) < 0.01, "front 中心 uv≈(0.5,0.5)")
	# 左上角射线 → uv 靠 (0,0)（uv 原点=贴图左上）
	var corner := phone.pick(Vector3(-W * 0.45, 0.45, 2), Vector3(0, 0, -1))
	if _check_hit(corner, "front 左上角命中"):
		var cuv: Vector2 = corner["uv"]
		_check(cuv.x < 0.1 and cuv.y < 0.1, "左上角 uv≈(0,0) 实测(%.2f,%.2f)" % [cuv.x, cuv.y])
	# 背面态不可拾取 back/spread：打在正面外的射线落空
	_check(phone.pick(Vector3(2, 0, 2), Vector3(0, 0, -1)).is_empty(), "板外射线落空")

	# ── 翻转展开跨页态 ──
	phone.show_spread(false)
	_check(phone.state == PaperPhone.State.SPREAD, "show_spread → SPREAD")
	var l_xf := phone.face_transform(PaperPhone.FACE_SPREAD_L)
	var r_xf := phone.face_transform(PaperPhone.FACE_SPREAD_R)
	_check(l_xf.basis.z.z > 0.99 and r_xf.basis.z.z > 0.99, "翻转后两内页法线都朝 +Z(相机)")
	_check(absf(l_xf.origin.z - r_xf.origin.z) < 1e-4, "两内页共面(z 相等)")
	_check(absf(l_xf.origin.x + W * 0.5) < 1e-4, "A 内面=左页(中心 x≈-W/2)")
	_check(absf(r_xf.origin.x - W * 0.5) < 1e-4, "B 内面=右页(中心 x≈+W/2)")

	# 跨页拾取：左半命中 spread_l、右半命中 spread_r
	var lhit := phone.pick(Vector3(-W * 0.5, 0, 2), Vector3(0, 0, -1))
	_check(String(lhit.get("face", "")) == PaperPhone.FACE_SPREAD_L, "左页中心命中 spread_l")
	if not lhit.is_empty():
		_check((lhit["uv"] as Vector2).distance_to(Vector2(0.5, 0.5)) < 0.01, "spread_l 中心 uv≈(0.5,0.5)")
	var rhit := phone.pick(Vector3(W * 0.5, 0, 2), Vector3(0, 0, -1))
	_check(String(rhit.get("face", "")) == PaperPhone.FACE_SPREAD_R, "右页中心命中 spread_r")
	# 跨页最左缘 → spread_l 的 uv.x≈0（贴图不镜像）
	var edge := phone.pick(Vector3(-W * 0.95, 0, 2), Vector3(0, 0, -1))
	if _check_hit(edge, "跨页左缘命中"):
		_check(String(edge["face"]) == PaperPhone.FACE_SPREAD_L and float((edge["uv"] as Vector2).x) < 0.1,
			"跨页左缘是 spread_l 的 uv.x≈0")
	# 跨页态正面壳不可拾取（它背对相机）
	_check(String(phone.pick(Vector3(-W * 0.5, 0, 2), Vector3(0, 0, -1)).get("face", "")) != PaperPhone.FACE_FRONT,
		"跨页态不会拾到 front")

	# ── face_uv 静态数学边界 ──
	var xf := Transform3D.IDENTITY
	var sz := Vector2(1.0, 2.0)
	_check(not PaperPhone.face_uv(xf, sz, Vector3(0, 0, 1), Vector3(0, 0, -1)).is_empty(), "正面射线命中")
	_check(PaperPhone.face_uv(xf, sz, Vector3(0, 0, -1), Vector3(0, 0, 1)).is_empty(), "背面射线拒绝")
	_check(PaperPhone.face_uv(xf, sz, Vector3(0, 0, 1), Vector3(1, 0, 0)).is_empty(), "平行射线拒绝")
	_check(PaperPhone.face_uv(xf, sz, Vector3(0.6, 0, 1), Vector3(0, 0, -1)).is_empty(), "出界(宽外)拒绝")
	var euv: Dictionary = PaperPhone.face_uv(xf, sz, Vector3(0.4, -0.9, 1), Vector3(0, 0, -1))
	if _check_hit(euv, "偏角命中"):
		var v: Vector2 = euv["uv"]
		_check(absf(v.x - 0.9) < 1e-4 and absf(v.y - 0.95) < 1e-4, "uv 映射正确(0.9,0.95) 实测(%.2f,%.2f)" % [v.x, v.y])

	# ── 相机贴合（fit 只读相机参数，不必真挂相机下；ready 回调里 reparent 会撞 parent-busy）──
	phone.fit_to_camera(cam, 0.8, Vector2(0.3, 0.0))
	_check(phone.scale.x > 0.0, "fit 后 scale>0")
	_check(absf(phone.position.z + 0.42) < 1e-4, "fit 后位于相机前 0.42")
	_check(phone.position.x > 0.0, "ndc.x=0.3 → 落屏右侧")

	# ── 收起 + 动画路径不崩 ──
	phone.stow(false)
	_check(phone.state == PaperPhone.State.STOWED and not phone.visible, "stow → 隐藏")
	phone.show_front(true)   # 动画路径（tween 不等完成，验证不崩+状态即时生效）
	_check(phone.state == PaperPhone.State.FRONT and phone.visible, "动画 show_front 状态即时生效")
	phone.show_spread(true)
	_check(phone.state == PaperPhone.State.SPREAD, "动画 show_spread 状态即时生效")
	phone.stow(true)
	_check(phone.state == PaperPhone.State.STOWED, "动画 stow 状态即时生效")

func _check_hit(hit: Dictionary, msg: String) -> bool:
	_check(not hit.is_empty(), msg)
	return not hit.is_empty()
