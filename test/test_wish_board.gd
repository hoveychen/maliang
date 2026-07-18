extends SceneTree
## A4 心愿清单（M1，docs/kids-thinking-little-boss.md + m1-wish-supply-design §2.4）headless 验收：
## ≤3 张卡硬上限 / wish 同 ability 去重 / npc_wishes 驱动增删 / 空态零催促 /
## 页面里不存在任何倒计时、进度条节点（§3.1 防回归：幼儿绝不能被追赶）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --script res://test/test_wish_board.gd

var _fails := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		printerr("  ✗ ", msg)
		_fails += 1

func _entry(cid: String, source: String, ability: String) -> Dictionary:
	var d := { "characterId": cid, "voiceId": "v-" + cid, "lines": ["嗯…"] }
	if not source.is_empty():
		d["source"] = source
	if not ability.is_empty():
		d["ability"] = ability
	return d

func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.ready.connect(func() -> void:
		await _run(scene)
		print("wish_board: fails=%d" % _fails)
		quit(_fails))

func _run(scene: Node) -> void:
	var pui: Variant = scene.get("phone_ui")
	_check(pui != null and pui is PhoneUi, "phone_ui 存在")
	if pui == null:
		return
	# app 已注册：PHONE_APPS 有 wishes、页面在 _album_pages
	var has_app := false
	for entry in PhoneUi.PHONE_APPS:
		if String(entry[0]) == "wishes":
			has_app = true
	_check(has_app, "PHONE_APPS 含 wishes（心愿清单）")
	var pages: Dictionary = pui.get("_album_pages")
	var page := pages.get("wishes") as Control
	_check(page != null, "_album_pages 有 wishes 页")
	if page == null:
		return

	# 喂 5 条供给 + 1 条纯氛围：cap 3、同 ability 去重、纯氛围不进清单
	var wishes := [
		_entry("npc1", "wish", "create_prop"),
		_entry("npc2", "wish", "create_prop"),   # 与 npc1 同 ability → 去重掉
		_entry("npc3", "chain", "play_game"),
		_entry("npc4", "errand", ""),
		_entry("npc5", "wish", "guide_to"),      # 第 4 张供给 → 被 cap 挡在幕后
		_entry("npc6", "", ""),                  # 纯氛围（无 source）→ 不进清单
	]
	scene._on_npc_wishes(wishes, [], null)
	var board: Array = scene.get("wish_board")
	_check(board.size() == 3, "清单硬上限 3 张（5 条供给只留 3）: %d" % board.size())
	var cids := []
	for e in board:
		cids.append(String((e as Dictionary).get("characterId", "")))
	_check(cids == ["npc1", "npc3", "npc4"], "同 ability 去重 + 保序 + 纯氛围不进: %s" % str(cids))
	var cards: Dictionary = pui.get("_wish_cards")
	_check(cards.size() == 3, "渲染出 3 张卡: %d" % cards.size())
	var empty_label := pui.get("_wishes_empty") as Label
	_check(empty_label != null and not empty_label.visible, "有卡时不显示空态")

	# 防回归（§3.1 零催促）：清单页子树里绝不允许倒计时/进度条类节点
	var timers := page.find_children("*", "Timer", true, false)
	var bars := page.find_children("*", "ProgressBar", true, false)
	var tbars := page.find_children("*", "TextureProgressBar", true, false)
	_check(timers.is_empty() and bars.is_empty() and tbars.is_empty(),
		"清单页无任何倒计时/进度条节点（timers=%d bars=%d tbars=%d）" % [timers.size(), bars.size(), tbars.size()])

	# npc_wishes 驱动增删：重推只剩 1 条 → 卡收敛到 1（页面不可见走即时拆，无动画等待）
	scene._on_npc_wishes([_entry("npc3", "chain", "play_game")], [], null)
	cards = pui.get("_wish_cards")
	_check(cards.size() == 1 and cards.has("npc3"), "重推后卡增删正确（只剩 npc3）")

	# 清空 → 空态出现，文案不催促（不含「快/马上/时间」类字眼）
	scene._on_npc_wishes([], [], null)
	cards = pui.get("_wish_cards")
	_check(cards.is_empty(), "清空后无卡")
	_check(empty_label.visible, "空态提示可见")
	var t := empty_label.text
	_check(not ("快" in t) and not ("马上" in t) and not ("时间" in t), "空态文案零催促: %s" % t)
