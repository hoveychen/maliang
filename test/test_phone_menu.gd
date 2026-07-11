extends SceneTree
## 手机菜单（左下角）冒烟测试：实例化整关，验证 3D 纸糊手机（PaperPhone）+ 屏幕内容
## （PhoneUi）在真实实例化下不崩、状态正确。纯解析检查抓不到 _setup_hud 的运行期错误
## （空调用/类型错），故用整关实例化跑一遍关键路径。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --script res://test/test_phone_menu.gd

var _fails := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		printerr("  ✗ ", msg)
		_fails += 1

func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.ready.connect(func() -> void:
		_run(scene)
		print("phone_menu smoke: fails=%d" % _fails)
		quit(_fails))

func _run(scene: Node) -> void:
	var album_button: Variant = scene.get("album_button")
	var phone: PaperPhone = scene.get("paper_phone")
	var pui: Variant = scene.get("phone_ui")
	_check(album_button != null and album_button is Button, "album_button 是 Button")
	_check(phone != null, "paper_phone 存在")
	_check(pui != null and pui is PhoneUi, "phone_ui 存在")
	if phone == null or pui == null:
		return
	_check(phone.state == PaperPhone.State.DOCKED, "初始停靠态(DOCKED)")
	_check(not phone.visible, "首次停靠贴合前隐藏（ready 时机早于首帧 _step_phone_ui）")
	_check(scene.get("_phone_scrim") != null, "_phone_scrim（点外部收起遮罩）存在")
	_check(pui.get("_phone_signal") != null, "_phone_signal（状态栏信号格）存在")
	# 两块屏幕视口按 PhoneUi 尺寸就绪
	_check(phone.front_viewport() != null and phone.front_viewport().size == PhoneUi.FRONT_PX, "正面视口尺寸")
	_check(phone.spread_viewport() != null and phone.spread_viewport().size == PhoneUi.SPREAD_PX, "跨页视口尺寸")
	# 主屏图标分页：3x3 网格、每页 columns=3；所有页图标总数 = 已实装 app 数（3）
	var pager: ScrollContainer = pui.get("_phone_pager")
	var pages_box: HBoxContainer = pui.get("_phone_pages_box")
	_check(pager != null, "_phone_pager（图标分页横滚）存在")
	_check(pages_box != null and pages_box.get_child_count() >= 1, "至少一页图标")
	var icon_total := 0
	var cols_ok := true
	if pages_box != null:
		for page in pages_box.get_children():
			for g in page.get_children():
				if g is GridContainer:
					if (g as GridContainer).columns != 3:
						cols_ok = false
					icon_total += g.get_child_count()
	_check(cols_ok, "每页网格 columns=3 (3x3)")
	_check(icon_total == 3, "图标总数 = 已实装 app 数 3（flowers/items/settings）")

	scene._toggle_album()
	_check(phone.state == PaperPhone.State.FRONT, "打开后正面态(FRONT)")
	_check(phone.visible, "打开后可见")
	_check(String(pui.get("_phone_open_app")) == "", "打开后停在主屏")
	_check((scene.get("_phone_scrim") as Control).visible, "打开后遮罩可见")
	_check(phone.front_viewport().render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"正面态主屏视口在更新")

	# 打开各 app：翻转到跨页、只显示该页
	var pages: Dictionary = pui.get("_album_pages")
	for id in ["flowers", "items", "settings"]:
		scene._open_app(id)
		_check(String(pui.get("_phone_open_app")) == id, "打开 app: %s" % id)
		_check(phone.state == PaperPhone.State.SPREAD, "%s：翻转到跨页态" % id)
		_check((pages[id] as Control).visible, "%s：对应页面可见" % id)
		for pid in pages:
			if pid != id:
				_check(not (pages[pid] as Control).visible, "%s：其它页 %s 隐藏" % [id, pid])
	_check(phone.spread_viewport().render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"跨页态跨页视口在更新")

	pui.close_app()
	_check(phone.state == PaperPhone.State.FRONT, "返回后回正面态")
	_check(String(pui.get("_phone_open_app")) == "", "返回后 open_app 清空")

	# 小红花/集邮 app：服务端钱包驱动 3×3 花格点亮 + 盖章进度点
	scene.set("wallet", { "flowers": 2, "stampProgress": 1, "stampsTotal": 7, "hearts": 5 })
	scene._refresh_album()
	var fcells: Array = pui.get("_flower_cells")
	_check(fcells.size() == 9, "小红花 3×3 = 9 格")
	var lit := 0
	for c in fcells:
		if (c as TextureRect).modulate == Color.WHITE:
			lit += 1
	_check(lit == 2, "flowers=2 → 点亮 2 格花")
	var dots: Array = pui.get("_stamp_dots")
	var dlit := 0
	for d in dots:
		if (d as TextureRect).modulate == Color.WHITE:
			dlit += 1
	_check(dlit == 1, "stampProgress=1 → 点亮 1 个盖章进度点")
	_check(scene._red_flower_count() == 2, "banner 小红花数=钱包 flowers")
	var hearts_label: Label = pui.get("_hearts_label")
	_check(hearts_label != null and hearts_label.text == "x5", "集邮册爱心行=钱包 hearts（player-interaction 移植）")

	pui.refresh_banner()
	var clock: Label = pui.get("_phone_clock")
	_check(clock != null and String(clock.text).length() == 5 and String(clock.text).contains(":"), "banner 时钟 HH:MM")

	# 可玩时间真强制状态机（tick/reconcile 纯函数，budget=100s、cooldown=60s、now=1000）
	var t1: Dictionary = scene.tick_play_budget(0.0, 0.0, 1000.0, 40.0, 100.0, 60.0)
	_check(is_equal_approx(float(t1["used"]), 40.0) and not bool(t1["blocked"]) \
			and is_equal_approx(float(t1["remaining_frac"]), 0.6), "累计 40/100：剩 60%、不拦")
	var t2: Dictionary = scene.tick_play_budget(95.0, 0.0, 1000.0, 10.0, 100.0, 60.0)
	_check(bool(t2["blocked"]) and is_equal_approx(float(t2["cooldown_until"]), 1060.0), "满 100 → 进冷却(至 now+60)")
	var t3: Dictionary = scene.tick_play_budget(100.0, 1060.0, 1030.0, 1.0, 100.0, 60.0)
	_check(bool(t3["blocked"]) and is_equal_approx(float(t3["cooldown_frac"]), 0.5), "冷却中：拦、进度 50%")
	var t4: Dictionary = scene.tick_play_budget(100.0, 1060.0, 1060.0, 1.0, 100.0, 60.0)
	_check(not bool(t4["blocked"]) and is_equal_approx(float(t4["used"]), 0.0), "冷却到点 → 解锁、清零")
	var r1: Dictionary = scene.reconcile_play_budget(100.0, 1060.0, 1000.0, 1030.0, 60.0)
	_check(is_equal_approx(float(r1["cooldown_until"]), 1060.0), "隔会话：冷却期内重进仍锁")
	var r2: Dictionary = scene.reconcile_play_budget(80.0, 0.0, 1000.0, 1060.0, 60.0)
	_check(is_equal_approx(float(r2["used"]), 0.0), "隔会话：长休息(≥冷却)刷新预算")
	var pie = pui.get("_phone_playpie")
	_check(pie != null and pie is PlayTimePie, "widget 可玩时间饼图存在(PlayTimePie)")
	_check(scene.get("_cooldown_overlay") != null, "冷却拦截遮罩存在")
	# _step_phone_ui：手机开着时按节流刷新一次不崩
	scene._step_phone_ui(1.0)
	_check(true, "_step_phone_ui 运行不崩")

	# 收起：状态复位 + 两块视口停更新 + 遮罩隐藏
	scene._close_phone()
	_check(phone.state == PaperPhone.State.DOCKED, "收起回停靠态(DOCKED)")
	_check(not (scene.get("_phone_scrim") as Control).visible, "收起后遮罩隐藏")
	_check(phone.front_viewport().render_target_update_mode == SubViewport.UPDATE_DISABLED \
			and phone.spread_viewport().render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"收起后两视口停更新")
