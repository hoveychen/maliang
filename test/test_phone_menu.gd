extends SceneTree
## 手机菜单（左下角）冒烟测试：实例化整关，验证手机 HUD 结构与 app 导航在真实实例化下不崩、状态正确。
## 纯解析检查抓不到 _setup_hud 的运行期错误（空调用/类型错），故用整关实例化跑一遍关键路径。
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
	var album_panel: Control = scene.get("album_panel")
	_check(album_button != null and album_button is Button, "album_button 是 Button")
	_check(album_panel != null, "album_panel 存在")
	if album_panel == null:
		return
	_check(not album_panel.visible, "初始手机面板隐藏")

	var home: Control = scene.get("_phone_home")
	_check(home != null, "_phone_home 存在")
	# 遮罩 + 状态栏信号格存在
	_check(scene.get("_phone_scrim") != null, "_phone_scrim（点外部收起遮罩）存在")
	_check(scene.get("_phone_signal") != null, "_phone_signal（状态栏信号格）存在")
	# 主屏图标分页：3x3 网格、每页 columns=3；所有页图标总数 = 已实装 app 数（3）
	var pager: ScrollContainer = scene.get("_phone_pager")
	var pages_box: HBoxContainer = scene.get("_phone_pages_box")
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
	_check(icon_total == 3, "图标总数 = 已实装 app 数 3（stickers/items/settings）")

	scene._toggle_album()
	_check(album_panel.visible, "打开后面板可见")
	_check(home != null and home.visible, "打开后停在主屏")
	var appview: Control = scene.get("_phone_app_view")
	_check(appview != null and not appview.visible, "主屏时 app 视图隐藏")

	# 手机壳固定尺寸：打开任何 app 都不能把 album_panel 撑大（内容超出屏区应滚动/裁剪，不撑壳）。
	var fixed_w := album_panel.custom_minimum_size.x
	var fixed_h := album_panel.custom_minimum_size.y
	var pages: Dictionary = scene.get("_album_pages")
	for id in ["stickers", "items", "settings"]:
		scene._open_app(id)
		_check(String(scene.get("_phone_open_app")) == id, "打开 app: %s" % id)
		_check(appview.visible and not home.visible, "%s：app 视图显示、主屏隐藏" % id)
		_check((pages[id] as Control).visible, "%s：对应页面可见" % id)
		var cms := album_panel.get_combined_minimum_size()
		_check(cms.x <= fixed_w + 1.0, "%s：不撑宽手机壳 (壳宽 %.0f, 内容 %.0f)" % [id, fixed_w, cms.x])
		_check(cms.y <= fixed_h + 1.0, "%s：不撑高手机壳 (壳高 %.0f, 内容 %.0f)" % [id, fixed_h, cms.y])

	scene._close_phone_app()
	_check(home.visible and not appview.visible, "返回主屏")
	_check(String(scene.get("_phone_open_app")) == "", "返回后 open_app 清空")

	scene._update_phone_banner()
	var clock: Label = scene.get("_phone_clock")
	_check(clock != null and String(clock.text).length() == 5 and String(clock.text).contains(":"), "banner 时钟 HH:MM")

	# 可玩时间：_play_state 纯函数（每轮 45min 可玩→10min 冷却，循环），widget 闹钟饼图据此渲染。
	_check(int(scene.get("_play_start_ms")) > 0, "_play_start_ms 已初始化")
	var s0: Dictionary = scene._play_state(0)
	_check(is_equal_approx(float(s0["remaining"]), 1.0) and not bool(s0["cooldown"]), "0s：满格可玩、不冷却")
	var s_mid: Dictionary = scene._play_state(1350) # 45min 的一半
	_check(is_equal_approx(float(s_mid["remaining"]), 0.5) and not bool(s_mid["cooldown"]), "1350s(半程)：剩 50%")
	var s_cd: Dictionary = scene._play_state(2700 + 300) # 进冷却 5min（冷却 10min 的一半）
	_check(bool(s_cd["cooldown"]) and is_equal_approx(float(s_cd["cooldown_frac"]), 0.5), "45min 后：冷却中、进度 50%")
	var pie = scene.get("_phone_playpie")
	_check(pie != null and pie is PlayTimePie, "widget 可玩时间饼图存在(PlayTimePie)")
	# _step_phone_ui：手机开着时按节流刷新一次不崩
	scene.set("_phone_ui_t", 0.0)
	scene._step_phone_ui(1.0)
	_check(true, "_step_phone_ui 运行不崩")
