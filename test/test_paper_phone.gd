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

	# 初始：停靠态、首次 fit_dock 前隐藏（防原点闪现）
	_check(phone.state == PaperPhone.State.DOCKED, "初始 DOCKED")
	_check(not phone.visible, "首次贴合前隐藏")

	# ── 合拢正面态 ──
	phone.show_front(false)
	_check(phone.state == PaperPhone.State.FRONT, "show_front → FRONT")
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

	# ── SubViewport 屏幕管线 ──
	phone.create_screens(Vector2i(360, 780), Vector2i(720, 780))
	_check(phone.front_viewport() != null and phone.front_viewport().size == Vector2i(360, 780), "正面视口就绪")
	_check(phone.spread_viewport() != null and phone.spread_viewport().size == Vector2i(720, 780), "跨页视口就绪")
	# screen_px 纯映射：正面全幅、跨页左右页各半、壳区不进屏
	var m1: Dictionary = PaperPhone.screen_px(PaperPhone.FACE_SCREEN, Vector2(0.5, 0.5), Vector2i(360, 780), Vector2i(720, 780))
	_check(String(m1["vp"]) == "front" and (m1["px"] as Vector2).is_equal_approx(Vector2(180, 390)), "screen uv(0.5,0.5)→front(180,390)")
	var m2: Dictionary = PaperPhone.screen_px(PaperPhone.FACE_SPREAD_L, Vector2(1.0, 0.5), Vector2i(360, 780), Vector2i(720, 780))
	var m3: Dictionary = PaperPhone.screen_px(PaperPhone.FACE_SPREAD_R, Vector2(0.0, 0.5), Vector2i(360, 780), Vector2i(720, 780))
	_check((m2["px"] as Vector2).is_equal_approx(Vector2(360, 390)) and (m3["px"] as Vector2).is_equal_approx(Vector2(360, 390)),
		"左页右缘/右页左缘拼在跨页中缝(360)")
	_check(PaperPhone.screen_px(PaperPhone.FACE_FRONT, Vector2(0.5, 0.5), Vector2i(360, 780), Vector2i(720, 780)).is_empty(),
		"壳(bezel)不映射进屏")
	# 正面态：屏幕 quad 浮在壳上，中心拾取改中 screen
	phone.show_front(false)
	var shit := phone.pick(Vector3(0, 0, 2), Vector3(0, 0, -1))
	_check(String(shit.get("face", "")) == PaperPhone.FACE_SCREEN, "建屏后正面中心拾取命中 screen")
	# 合成点击穿透：屏幕坐标→射线→UV→push_input→SubViewport 里的按钮收到 pressed
	cam.position = Vector3(0, 0, 2)
	var fbtn := Button.new()
	fbtn.position = Vector2.ZERO
	fbtn.size = Vector2(360, 780)
	phone.front_viewport().add_child(fbtn)
	var fclicked := [false]
	fbtn.pressed.connect(func() -> void: fclicked[0] = true)
	var spos := cam.unproject_position(Vector3(0, 0, 0.02))
	_check(phone.route_gui_event(cam, _mouse_ev(spos, true)), "正面点击命中机身")
	_check(phone.route_gui_event(cam, _mouse_ev(spos, false)), "正面松开命中机身")
	_check(fclicked[0], "点击穿透到正面视口按钮(pressed)")
	_check(not phone.route_gui_event(cam, _mouse_ev(Vector2(1, 1), true)), "角落点击没打在手机上")
	# 跨页态：左页点击进 spread 视口左半
	phone.show_spread(false)
	_check(phone.front_viewport().render_target_update_mode == SubViewport.UPDATE_DISABLED
		and phone.spread_viewport().render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"跨页态只更新跨页视口")
	var sbtn := Button.new()
	sbtn.position = Vector2.ZERO
	sbtn.size = Vector2(360, 780) # 左半页
	phone.spread_viewport().add_child(sbtn)
	var sclicked := [false]
	sbtn.pressed.connect(func() -> void: sclicked[0] = true)
	var lpos := cam.unproject_position(Vector3(-W * 0.5, 0, 0.02))
	_check(phone.route_gui_event(cam, _mouse_ev(lpos, true)), "左页点击命中")
	_check(phone.route_gui_event(cam, _mouse_ev(lpos, false)), "左页松开命中")
	_check(sclicked[0], "左页点击穿透到跨页视口左半按钮")
	# 拖拽捕获：按下命中屏区后，拖出机身/机外松手仍归手机（否则 ScrollContainer 丢 release 卡死）
	_check(phone.route_gui_event(cam, _mouse_ev(lpos, true)), "捕获:按下命中屏区")
	_check(phone.route_gui_event(cam, _motion_ev(Vector2(1, 1))), "捕获:拖出机身仍归手机")
	_check(phone.route_gui_event(cam, _mouse_ev(Vector2(1, 1), false)), "捕获:机外松手仍归手机")
	_check(not phone.route_gui_event(cam, _motion_ev(Vector2(1, 1))), "松手后捕获结束:机外事件不归手机")
	phone.dock(false)
	_check(phone.state == PaperPhone.State.DOCKED, "dock → DOCKED")
	_check(phone.front_viewport().render_target_update_mode == SubViewport.UPDATE_DISABLED
		and phone.spread_viewport().render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"停靠后两视口都停更新")
	phone.refresh_dock_screen()
	_check(phone.front_viewport().render_target_update_mode == SubViewport.UPDATE_ONCE,
		"停靠低频刷屏 = UPDATE_ONCE（渲一帧自动回停）")

	# ── 相机贴合（fit 只读相机参数，不必真挂相机下；ready 回调里 reparent 会撞 parent-busy）──
	phone.show_front(false)
	phone.fit_hand(cam, 0.8, Vector2(0.3, 0.0))
	_check(phone.scale.x > 0.0, "fit_hand 后 scale>0")
	_check(absf(phone.position.z + 0.42) < 1e-4, "fit_hand 后位于相机前 0.42")
	_check(phone.position.x > 0.0, "ndc.x=0.3 → 落屏右侧")
	var hand_scale := phone.scale.x
	phone.dock(false)
	phone.fit_dock(cam, 0.2, Vector2(-0.6, -0.6))
	_check(phone.visible, "首次 fit_dock 后现身")
	_check(phone.scale.x < hand_scale, "停靠比持机小")
	_check(phone.position.x < 0.0 and phone.position.y < 0.0, "停靠位落屏左下")

	# ── 动画路径不崩（tween 不等完成，验证状态即时生效）──
	phone.show_front(true)
	_check(phone.state == PaperPhone.State.FRONT, "动画 show_front 状态即时生效")
	phone.show_spread(true)
	_check(phone.state == PaperPhone.State.SPREAD, "动画 show_spread 状态即时生效")
	phone.dock(true)
	_check(phone.state == PaperPhone.State.DOCKED, "动画 dock 状态即时生效")

func _check_hit(hit: Dictionary, msg: String) -> bool:
	_check(not hit.is_empty(), msg)
	return not hit.is_empty()

func _motion_ev(pos: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	return ev

func _mouse_ev(pos: Vector2, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	return ev
