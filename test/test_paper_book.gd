extends SceneTree
## PaperBook(3D 卡纸故事书)单测：剖面数学/页堆分配/开合姿态/射线拾取，headless 无窗可跑。
## 运行: godot --headless --script res://test/test_paper_book.gd

var _fails := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		printerr("  ✗ ", msg)
		_fails += 1

func _initialize() -> void:
	_run_pure()
	# 节点相关断言：挂进 root 等 ready（global_transform 首帧才可用，与 test_paper_phone 同法）
	var book := PaperBook.new()
	root.add_child(book)
	# 相机也在 _initialize 挂树（ready 回调期间 add_child 的节点 is_inside_tree 为假,
	# project_ray/unproject 全废——踩坑实录）
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2)
	root.add_child(cam)
	book.ready.connect(func() -> void:
		await _run_node(book, cam)
		print("paper_book: fails=%d" % _fails)
		quit(_fails))

# ── 剖面纯数学 ───────────────────────────────────────────────────────────────

func _run_pure() -> void:
	var t := 0.05
	var w := PaperBook.PAGE_W
	var pts := PaperBook.page_profile(t, w, 20)
	_check(pts.size() == 21, "剖面点数 = segs+1")
	_check(absf(pts[0].y - PaperBook.BIND_Z) < 1e-6, "书脊处下潜到装订点")
	_check(absf(pts[20].y - t) < 1e-6, "前口处=页堆顶")
	_check(absf(pts[20].x - w) < 1e-6, "剖面横跨全页宽")
	var mono := true
	for i in range(1, pts.size()):
		if pts[i].y < pts[i - 1].y - 1e-9 or pts[i].x <= pts[i - 1].x:
			mono = false
	_check(mono, "剖面单调爬升(沟槽→页堆顶,无回折)")

	# 弧长 uv：0→1 单调；谷壁段(斜走)比平铺段占的 u 比横向投影大=贴图在沟槽被压缩
	var us := PaperBook.profile_us(pts)
	_check(absf(us[0]) < 1e-6 and absf(us[us.size() - 1] - 1.0) < 1e-6, "弧长 uv 首尾=0/1")
	var us_mono := true
	for i in range(1, us.size()):
		if us[i] <= us[i - 1]:
			us_mono = false
	_check(us_mono, "弧长 uv 单调递增")
	var climb_u := us[2] - us[0]          # 谷壁前两段
	var climb_x := (pts[2].x - pts[0].x) / w
	_check(climb_u > climb_x + 1e-4, "谷壁段 u 占比>横向占比(凹陷压缩变形) u=%.4f x=%.4f" % [climb_u, climb_x])

	# 沟槽阴影：书脊最暗、页堆顶=1、单调变亮
	var shade := PaperBook.profile_shade(pts, t)
	_check(absf(shade[shade.size() - 1] - 1.0) < 1e-6, "页堆顶 shade=1")
	_check(shade[0] < 0.65, "书脊沟底明显变暗(%.2f)" % shade[0])
	var sh_mono := true
	for i in range(1, shade.size()):
		if shade[i] < shade[i - 1] - 1e-9:
			sh_mono = false
	_check(sh_mono, "shade 沿剖面单调变亮")

	# 页堆分配：进度两端都 ≥ 基线厚，总厚守恒
	var s0 := PaperBook.stack_split(0.0)
	var s1 := PaperBook.stack_split(1.0)
	var base := PaperBook.PAGE_STACK_T * PaperBook.STACK_BASE_FRAC
	_check(absf(s0.x + s0.y - PaperBook.PAGE_STACK_T) < 1e-6, "总厚守恒(p=0)")
	_check(absf(s1.x + s1.y - PaperBook.PAGE_STACK_T) < 1e-6, "总厚守恒(p=1)")
	_check(s0.x >= base - 1e-6 and s1.y >= base - 1e-6, "两侧页堆始终≥基线厚")
	_check(s1.x > s0.x + 1e-6, "翻书进度让左堆增厚")

	# 翻页纸形变：k=0/1 与静止剖面严丝合缝、k=0.5 立在书脊上方
	var rest_r := PaperBook.page_profile(0.03, w, 20)
	var rest_l := PaperBook.page_profile(0.06, w, 20)
	var p0 := PaperBook.sheet_points(rest_r, rest_l, 0.0)
	var p1 := PaperBook.sheet_points(rest_r, rest_l, 1.0)
	var pm := PaperBook.sheet_points(rest_r, rest_l, 0.5)
	_check(p0[20].distance_to(rest_r[20]) < 1e-6, "k=0 自由边贴合右页剖面")
	_check(p1[20].distance_to(Vector2(-rest_l[20].x, rest_l[20].y)) < 1e-6, "k=1 自由边贴合左页剖面(镜像)")
	_check(absf(pm[20].x) < 1e-6 and pm[20].y > w * 0.5, "k=0.5 自由边立在书脊正上方高拱")

	# 跨页像素映射：左右页各采样半幅、书脊两侧相接
	var px := Vector2i(1560, 900)
	var r_mid := PaperBook.spread_px(PaperBook.FACE_PAGE_R, Vector2(0.5, 0.5), px)
	_check(r_mid.is_equal_approx(Vector2(1170, 450)), "右页中心→spread(0.75 宽)")
	var l_spine := PaperBook.spread_px(PaperBook.FACE_PAGE_L, Vector2(0.0, 0.5), px)
	var r_spine := PaperBook.spread_px(PaperBook.FACE_PAGE_R, Vector2(0.0, 0.5), px)
	_check(l_spine.is_equal_approx(Vector2(780, 450)) and r_spine.is_equal_approx(Vector2(780, 450)),
		"左右页书脊侧在跨页中缝(780)相接")
	var l_fore := PaperBook.spread_px(PaperBook.FACE_PAGE_L, Vector2(1.0, 0.0), px)
	_check(l_fore.is_equal_approx(Vector2(0, 0)), "左页前口→跨页最左")

# ── 节点姿态与拾取 ───────────────────────────────────────────────────────────

func _run_node(book: PaperBook, cam: Camera3D) -> void:
	var w := PaperBook.PAGE_W
	var ct := PaperBook.COVER_T

	# 摊平态：左右页堆顶面等高、对称分布
	book.set_progress(0.5)
	var lc := book.pick(Vector3(-w * 0.6, 0.0, 2.0), Vector3(0, 0, -1))
	var rc := book.pick(Vector3(w * 0.6, 0.0, 2.0), Vector3(0, 0, -1))
	_check(String(lc.get("face", "")) == PaperBook.FACE_PAGE_L, "左半射线命中左页")
	_check(String(rc.get("face", "")) == PaperBook.FACE_PAGE_R, "右半射线命中右页")
	if not rc.is_empty():
		var uv: Vector2 = rc["uv"]
		_check(absf(uv.y - 0.5) < 0.01, "右页中线 v≈0.5 实测 %.3f" % uv.y)
		_check(uv.x > 0.5, "x=0.6w 在右页前口半侧(u>0.5) 实测 %.3f" % uv.x)
	# 书脊正上方打下去：命中沟槽内(u 小)
	var spine_hit := book.pick(Vector3(0.02, 0.0, 2.0), Vector3(0, 0, -1))
	_check(not spine_hit.is_empty() and float((spine_hit["uv"] as Vector2).x) < 0.2,
		"书脊近旁命中沟槽段(u<0.2)")
	# 页外射线落空
	_check(book.pick(Vector3(w * 2.0, 0.0, 2.0), Vector3(0, 0, -1)).is_empty(), "页外射线落空")

	# 页顶边(v≈0)/页底边(v≈1)方向：+Y 是页顶
	var top_hit := book.pick(Vector3(w * 0.6, 0.45, 2.0), Vector3(0, 0, -1))
	if not top_hit.is_empty():
		_check(float((top_hit["uv"] as Vector2).y) < 0.1, "页顶(+Y)v≈0 实测 %.3f" % float((top_hit["uv"] as Vector2).y))

	# 进度改变页堆厚度：右堆变薄后，右页前口顶面 z 下降
	book.set_progress(0.0)
	var t_r0 := PaperBook.stack_split(0.0).y
	var hi := book.pick(Vector3(w * 0.9, 0.0, 2.0), Vector3(0, 0, -1))
	_check(not hi.is_empty() and absf(float(hi["dist"]) - (2.0 - ct - t_r0 - PaperBook.FACE_EPS)) < 0.01,
		"p=0 右页前口面高=封面+右堆厚")
	book.set_progress(1.0)
	var t_r1 := PaperBook.stack_split(1.0).y
	var hi2 := book.pick(Vector3(w * 0.9, 0.0, 2.0), Vector3(0, 0, -1))
	_check(not hi2.is_empty() and absf(float(hi2["dist"]) - (2.0 - ct - t_r1 - PaperBook.FACE_EPS)) < 0.01,
		"p=1 右堆变薄、面高随之下降")
	book.set_progress(0.0)

	# 合书姿态：前封面板翻到右堆顶、左页堆随铰链叠进书里；页面不可拾取
	book.set_open_frac(0.0)
	_check(book.pick(Vector3(w * 0.5, 0.0, 2.0), Vector3(0, 0, -1)).is_empty(), "合书态页面不可拾取")
	var bf := book.get_node("HingeSpine/HingeFront/BoardFront") as MeshInstance3D
	var bf_pos := bf.global_transform.origin
	_check(bf_pos.z > PaperBook.SPINE_W - PaperBook.COVER_T, "合书:前封面板抬到书侧高(z=%.3f)" % bf_pos.z)
	_check(bf_pos.x > 0.0, "合书:前封面板盖在右堆上方(x>0)")
	var pl := book.get_node("HingeSpine/HingeFront/PageL") as MeshInstance3D
	_check((pl.global_transform.basis * Vector3(0, 0, 1)).z < -0.99, "合书:左页堆翻转扣在右堆顶(法线朝下)")
	# 重新摊开：拾取恢复、左页堆回到左半
	book.set_open_frac(1.0)
	_check(not book.pick(Vector3(-w * 0.5, 0.0, 2.0), Vector3(0, 0, -1)).is_empty(), "重新摊开后拾取恢复")
	_check((pl.global_transform.basis * Vector3(0, 0, 1)).z > 0.99, "摊开:左页堆法线朝上")
	_check(pl.global_transform.origin.x < 1e-4, "摊开:左页堆回到书脊左侧原位")

	# 跨页视口：uv 采样参数（左页反向采左半、右页正向采右半）
	book.create_spread(Vector2i(1560, 900))
	_check(book.spread_viewport() != null and book.spread_viewport().size == Vector2i(1560, 900), "跨页视口就绪")
	# 合成点击穿透：射线→uv→push_input→SubViewport 里的按钮收到 pressed
	var pressed := [false]
	var btn := Button.new()
	btn.position = Vector2(1170 - 100, 450 - 50) # 右页中心(u=0.5→px 1170)
	btn.size = Vector2(200, 100)
	book.spread_viewport().add_child(btn)
	btn.pressed.connect(func() -> void: pressed[0] = true)
	cam.make_current()
	# 右页 u=0.5 的世界 x：u 是弧长参数，平铺段近似=横向位置；取拾取反查保证一致
	var target := _find_world_x_for_u(book, 0.5)
	for pressed_state: bool in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed_state
		ev.position = cam.unproject_position(Vector3(target, 0.0, PaperBook.COVER_T + 0.06))
		book.route_gui_event(cam, ev)
	# SubViewport 的 gui 事件在本帧末结算：等两帧再断言
	for i in 3:
		await process_frame
	_check(pressed[0], "点击穿透:右页中心按钮收到 pressed")

	# ── 动画编排（headless 无渲染,只钉状态机与几何结果）──
	book.set_open_frac(0.0)
	await book.play_open(0.05)
	_check(absf(book.open_frac() - 1.0) < 1e-6, "play_open 结束=完全摊平")
	var swapped := [0]
	var turn_done := [false]
	var turn := func() -> void:
		await book.turn_page(func() -> void: swapped[0] += 1, 0.6, 0.06)
		turn_done[0] = true
	turn.call()
	await process_frame
	_check(book.is_turning(), "翻页动画进行中")
	_check(book.pick(Vector3(w * 0.5, 0.0, 2.0), Vector3(0, 0, -1)).is_empty(), "翻页中页面不可拾取")
	while not turn_done[0]:
		await process_frame
	_check(swapped[0] == 1, "swap_content 恰被调用一次")
	_check(absf(book.progress() - 0.6) < 1e-6, "翻页后进度=0.6")
	_check(not book.is_turning(), "翻页动画收尾")
	_check(not (book.get_node("Sheet") as MeshInstance3D).visible, "翻页纸收起")
	# 落地后两侧页堆厚度=新进度分配（用拾取面高反查）
	var sp := PaperBook.stack_split(0.6)
	var lh := book.pick(Vector3(-w * 0.9, 0.0, 2.0), Vector3(0, 0, -1))
	var rh := book.pick(Vector3(w * 0.9, 0.0, 2.0), Vector3(0, 0, -1))
	_check(not lh.is_empty() and absf(float(lh["dist"]) - (2.0 - PaperBook.COVER_T - sp.x - PaperBook.FACE_EPS)) < 0.01,
		"左堆按新进度增厚")
	_check(not rh.is_empty() and absf(float(rh["dist"]) - (2.0 - PaperBook.COVER_T - sp.y - PaperBook.FACE_EPS)) < 0.01,
		"右堆按新进度变薄")

## 二分找"右页 uv.x≈u0"的世界 x（拾取即真相，避免手工重算弧长映射）。
func _find_world_x_for_u(book: PaperBook, u0: float) -> float:
	var lo := 0.0
	var hi := PaperBook.PAGE_W
	for i in 40:
		var mid := (lo + hi) * 0.5
		var hit := book.pick(Vector3(mid, 0.0, 2.0), Vector3(0, 0, -1))
		if hit.is_empty() or float((hit["uv"] as Vector2).x) < u0:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5
