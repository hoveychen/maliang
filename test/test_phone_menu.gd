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
	# ⚠️ 必须 await _run —— 它内部要等盖章/种花仪式的 Tween 跑完（真协程）。不 await 的话
	# 第一个 await 一挂起，这个 lambda 就直接 print+quit(0) 了：后半段断言一条都没执行，
	# 却报 fails=0 的假绿灯。
	scene.ready.connect(func() -> void:
		await _run(scene)
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
	_check(icon_total == 4, "图标总数 = 已实装 app 数 4（home/flowers/items/settings）")

	var cover: Control = pui.get("_screen_cover")
	_check(cover != null and cover.visible, "停靠常驻=熄屏黑屏")
	scene._toggle_album()
	_check(phone.state == PaperPhone.State.FRONT, "打开后正面态(FRONT)")
	_check(not cover.visible, "打开=点亮（熄屏遮罩隐藏）")
	_check(phone.visible, "打开后可见")
	_check(String(pui.get("_phone_open_app")) == "", "打开后停在主屏")
	_check((scene.get("_phone_scrim") as Control).visible, "打开后遮罩可见")
	_check(phone.front_viewport().render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"正面态主屏视口在更新")

	# 打开各 app：翻转到跨页、只显示该页
	var pages: Dictionary = pui.get("_album_pages")
	for id in ["home", "flowers", "items", "settings"]:
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

	# ⚠️ 先等离线兜底那次 _apply_wallet 落定（连不上后端 → 几十帧后套用默认钱包）。仪式现在要跑
	# 真 Tween（好几秒的真帧），期间那个迟到的 bootstrap 会把测试塞的钱包冲成默认值 {3,0,0}，
	# 演完 snap 过去，断言就莫名其妙地对不上了。
	for _f in 60:
		await scene.get_tree().process_frame

	# 小红花/集邮 app：花田/章卡画的是**见证游标**（小朋友亲眼见过的），不是服务端钱包——
	# 欠盖的章要等他开手机亲手盖上去。这里钱包与游标一致（无欠章），画面应等于钱包。
	# 游标显式落到「刚见证完 7 个章」——否则 world._ready 从本机 profile.json 读到的残留会让
	# 这段随上次跑测留下的状态飘（同一台机器连跑两次结论不同）。
	scene.set("stamp_seen", { "flowers": 2, "stampProgress": 1, "stampsTotal": 7 })
	scene.set("wallet", { "flowers": 2, "stampProgress": 1, "stampsTotal": 7, "hearts": 5 })
	scene._apply_wallet(scene.get("wallet"))  # 走对账：无欠章 → 立刻认账 → 游标=钱包
	var seen: Dictionary = scene.get("stamp_seen")
	_check(int(seen.get("flowers", -1)) == 2 and int(seen.get("stampsTotal", -1)) == 7,
		"无欠章：见证游标立刻对齐钱包")
	var field: FlowerField = pui.get("_flower_field")
	var card: StampCard = pui.get("_stamp_card")
	_check(field != null and card != null, "花田/章卡控件就位")
	var lit := 0
	for i in 9:
		if field.bloom_of(i) > 0.5:
			lit += 1
	_check(lit == 2, "flowers=2 → 花田长出 2 朵")
	_check(not card.has_tool(), "无欠章：橡皮章不出来")
	_check(scene._red_flower_count() == 2, "banner 小红花数=钱包 flowers")

	# 欠 2 个章（服务端已算完账，小朋友还没见证）：画面停在游标上，等他开手机盖。
	# 钱包按服务端的算术给：7+2=9 个章，第 9 个把第三格盖满 → 立刻兑成第 3 朵花、progress 归零。
	scene.set("wallet", { "flowers": 3, "stampProgress": 0, "stampsTotal": 9, "hearts": 5 })
	scene._apply_wallet(scene.get("wallet"))
	seen = scene.get("stamp_seen")
	_check(int(seen.get("stampsTotal", -1)) == 7, "有欠章：见证游标先不动")
	_check(pui.has_pending_stamps(), "有欠章：手机该亮角标")
	var beats := StampCeremony.plan(seen, scene.get("wallet"), [])
	pui.hover_timeout = 0.0  # 回测不空等小朋友点橡皮章
	_check(beats.size() == 3, "欠 2 章 → 2 拍盖章 + 1 拍开花")
	await pui.play_ceremony(beats)
	seen = scene.get("stamp_seen")
	_check(int(seen.get("stampsTotal", -1)) == 9 and int(seen.get("flowers", -1)) == 3,
		"仪式演完：见证游标推到钱包（长出第 3 朵花）")
	_check(not pui.has_pending_stamps(), "仪式演完：角标灭")

	# 摘花（造角色扣 1 朵）：花田少一朵，游标跟上
	scene.set("wallet", { "flowers": 2, "stampProgress": 0, "stampsTotal": 9, "hearts": 5 })
	scene._apply_wallet(scene.get("wallet"))
	await pui.play_ceremony(StampCeremony.plan(scene.get("stamp_seen"), scene.get("wallet"), []))
	_check(int((scene.get("stamp_seen") as Dictionary).get("flowers", -1)) == 2, "摘花：游标跟到 2 朵")
	_check(field.bloom_of(2) < 0.5, "摘花：第 3 格空了")

	# 花田满 9：章卡攒满也不长花，只提示（不崩、不多长花）
	scene.set("stamp_seen", { "flowers": 9, "stampProgress": 2, "stampsTotal": 30 })
	scene.set("wallet", { "flowers": 9, "stampProgress": 3, "stampsTotal": 31, "hearts": 5 })
	scene._apply_wallet(scene.get("wallet"))
	var full_beats := StampCeremony.plan(scene.get("stamp_seen"), scene.get("wallet"), [])
	await pui.play_ceremony(full_beats)
	_check(int((scene.get("stamp_seen") as Dictionary).get("stampProgress", -1)) == 3, "满 9：章卡停在攒满")
	var grown := 0
	for i in 9:
		if field.bloom_of(i) > 0.5:
			grown += 1
	_check(grown == 9, "满 9：还是 9 朵，没多长")

	StampCeremony.save_seen(StampCeremony.empty_seen())  # 别把本次测试的游标留给别的测试
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
	_check((pui.get("_screen_cover") as Control).visible, "收起=熄屏")
	_check((phone.get("_base_rot") as Vector3).is_equal_approx(PaperPhone.DOCK_ROT) or phone.get("_tween") != null,
		"停靠侧摆角已入姿态（动画目标=DOCK_ROT）")
	_check(not (scene.get("_phone_scrim") as Control).visible, "收起后遮罩隐藏")
	_check(phone.front_viewport().render_target_update_mode == SubViewport.UPDATE_ONCE \
			and phone.spread_viewport().render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"收起后跨页停更、正面渲一帧熄屏黑底后自动停（UPDATE_ONCE）")

	# 回家 app：跨页有「回家」按钮；离线且已在 village 时点回家 → 就地把玩家挪回原点附近空位解卡。
	_check(pui.get("_home_btn") != null and pui.get("_home_btn") is Button, "回家页有「回家」按钮(_home_btn)")
	var far := WorldGrid.from_tile_center(Vector2i(50, 50))
	(scene.get("player") as Dictionary)["logical"] = far
	scene._go_home()
	var home_pos: Vector2 = (scene.get("player") as Dictionary)["logical"]
	var d_home := WorldGrid.shortest_delta(home_pos, WorldGrid.from_tile_center(Vector2i.ZERO)).length()
	_check(d_home <= 20.0, "离线回家：玩家从(50,50)挪回原点附近（环面距原点 %.1f ≤ 20 单位）" % d_home)
	_check(WorldGrid.shortest_delta(scene.get("focus_logical"), home_pos).length() < 0.01, "回家后相机聚焦跟到玩家")

	# 过场 loading 遮罩：_setup_hud 建好、初始隐藏；步进一帧仙子动画不崩
	var overlay: Control = scene.get("_transition_overlay")
	_check(overlay != null and not overlay.visible, "过场 loading 遮罩存在且初始隐藏")
	scene._step_transition_fairy(0.1)
	_check(true, "_step_transition_fairy 运行不崩")
