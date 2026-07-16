extends SceneTree
## onboarding 形象对话页（avatar_chat）冒烟（docs/onboarding-avatar-redesign-design.md P4）：
## ① 离线降级：/onboarding/avatar-chat 不可达 → FB_QUESTIONS 本地静态题序出卡，答案进
##    avatar_attrs、本地拼简化描述——描述必须双手空着（绝无「抱着/拿着」）、图案印上衣。
## ② 在线一轮应用：_chat_apply 渲卡（color 类出色块）、state 存回；done 轮存描述+回填旧口径 gender。
## ③ PlayerProfile.avatar_description：首选 visual_description；旧模板兜底也不再「抱着玩偶」。
## 运行: godot --headless --path . --script res://test/test_onboarding_avatar_chat.gd
## 前置约定：MALIANG_API_BASE 指向不可达地址（scripts/test-headless.sh 缺省即是）。

var _ran := false
var _fails := 0
const FORBIDDEN := ["抱着", "拿着", "手持", "举着", "捧着", "牵着"]

func _new_ob() -> Control:
	# 解析失败时 load 返回的 GDScript 不能实例化——必须记失败并中止，
	# 否则后续全部 SCRIPT ERROR 被吞、_fails 仍是 0，假绿灯（首版真踩过）。
	var script: GDScript = load("res://scripts/onboarding.gd")
	if script == null or not script.can_instantiate():
		printerr("  FAIL onboarding.gd 解析失败，无法实例化")
		_fails += 1
		quit(_fails)
		return null
	var ob: Control = script.new()
	root.add_child(ob)
	for i in ob.PAGES.size():
		if String(ob.PAGES[i]["kind"]) == "avatar_chat":
			ob.page_idx = i
			break
	ob._voice.stop()
	ob._finishing = true # 测试里页面推进到底也不许真切场景
	return ob

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	await _test_offline_fallback()
	await _test_online_apply()
	_test_avatar_description()
	if _fails == 0:
		print("onboarding_avatar_chat tests PASS")
	else:
		printerr("onboarding_avatar_chat tests FAILED: %d" % _fails)
	quit(_fails)

## ① 离线降级题序全链
func _test_offline_fallback() -> void:
	var ob := _new_ob()
	var box := VBoxContainer.new()
	root.add_child(box)
	ob._build_avatar_chat(box, {})
	# 等 api 失败 → 降级出卡（离线连接错误应在数秒内；上限 20s 防卡死）
	var deadline := Time.get_ticks_msec() + 20000
	while not ob._chat_fallback and Time.get_ticks_msec() < deadline:
		await process_frame
	_check("离线: 进入降级题序", ob._chat_fallback, true)
	_check("离线: 降级出性别卡", ob._chat_cards.get_child_count() >= 2, true)
	_check("离线: 降级纯点选不开麦", ob._mic_allowed(), false)
	# 直接驱动三题（男生 / 红色 / 小兔子）；每题等 0.6s 反馈窗过完（_fb_picking 落回 false）
	for qi in ob.FB_QUESTIONS.size():
		var q := ob.FB_QUESTIONS[qi] as Dictionary
		ob._chat_fb_pick(q, (q["options"] as Array)[0] as Dictionary)
		deadline = Time.get_ticks_msec() + 10000
		while (ob._chat_fb_idx <= qi or ob._fb_picking) and Time.get_ticks_msec() < deadline:
			await process_frame
	# 等 _chat_fb_done 落 answers（最后一题反馈窗结束后同步执行）
	deadline = Time.get_ticks_msec() + 10000
	while not ob.answers.has("visual_description") and Time.get_ticks_msec() < deadline:
		await process_frame
	var desc := String(ob.answers.get("visual_description", ""))
	_check("离线: 描述非空", desc.is_empty(), false)
	_check("离线: 描述双手空着", desc.contains("双手空空"), true)
	_check("离线: 图案印上衣（小兔子转图案）", desc.contains("印着小兔子图案"), true)
	for w in FORBIDDEN:
		_check("离线: 描述无持物措辞「%s」" % w, desc.contains(w), false)
	_check("离线: 旧口径 gender 回填", String(ob.answers.get("gender", "")), "boy")
	var attrs := ob.answers.get("avatar_attrs", {}) as Dictionary
	_check("离线: attrs.motifs 收集", (attrs.get("motifs", []) as Array), ["小兔子"])
	ob.free()
	box.free()

## ② 在线一轮 / done 轮（直接喂服务端响应形状，不走网络）
func _test_online_apply() -> void:
	var ob := _new_ob()
	var box := VBoxContainer.new()
	root.add_child(box)
	# 手搭卡容器（绕开 _build_avatar_chat 的 _chat_start 网络请求）
	ob._chat_cards = HBoxContainer.new()
	box.add_child(ob._chat_cards)
	ob._chat_status = TextureRect.new()
	box.add_child(ob._chat_status)
	await ob._chat_apply({
		"replyText": "问你个问题呀", "done": false, "question": "想要什么颜色？", "category": "color",
		"options": [
			{ "id": "av_col_red", "label": "红色", "iconAsset": "" },
			{ "id": "av_col_blue", "label": "蓝色", "iconAsset": "" },
		],
		"state": { "attrs": { "gender": "小女生", "motifs": [], "extras": [] }, "turnCount": 2 },
	})
	var card_count := 0
	for c in ob._chat_cards.get_children():
		if c is Button:
			card_count += 1
	_check("在线: 渲出 2 张色块卡（不算书脊 gutter）", card_count, 2)
	_check("在线: 念完题开麦", ob._chat_busy, false)
	_check("在线: state 存回", int((ob._chat_state as Dictionary).get("turnCount", 0)), 2)
	await ob._chat_apply({
		"replyText": "画好啦", "done": true, "description": "一段服务端合成的描述",
		"state": { "attrs": { "gender": "小女生", "color": "粉色", "motifs": ["星星"], "extras": [] } },
	})
	_check("done: 描述入档", String(ob.answers.get("visual_description", "")), "一段服务端合成的描述")
	_check("done: 旧口径 gender=girl", String(ob.answers.get("gender", "")), "girl")
	_check("done: 旧口径 color 回填", String(ob.answers.get("color", "")), "粉色")
	ob.free()
	box.free()

## ③ 描述来源优先级与旧模板去「抱着玩偶」
func _test_avatar_description() -> void:
	var with_vd := { "visual_description": "对话产出的描述", "gender": "boy" }
	_check("desc: 首选 visual_description", PlayerProfile.avatar_description(with_vd), "对话产出的描述")
	var legacy := { "gender": "girl", "color": "粉色", "likes": "小恐龙", "interest": "画画" }
	var d := PlayerProfile.avatar_description(legacy)
	for w in FORBIDDEN:
		_check("desc: 旧模板无持物措辞「%s」" % w, d.contains(w), false)
	_check("desc: 旧模板图案上衣", d.contains("印着小恐龙图案"), true)
	_check("desc: 旧模板双手空着", d.contains("双手空空"), true)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		return
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	_fails += 1

func _initialize() -> void:
	process_frame.connect(_run_once)
