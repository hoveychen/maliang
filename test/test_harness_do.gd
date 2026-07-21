extends SceneTree
## do op 真输入执行单测（game-pilot 重写 P2）。验：
##  1) parse_command 解析 do op（缺 action 拒）；
##  2) press 走【真触屏】：do press:btn:<path> 经 event_sink 发出 InputEventScreenTouch 到按钮中心
##     （而非 pressed.emit 穿透——遮罩吞点击盲区由此关闭），回包 execution=tap；
##  3) 异步动作延迟落定：off-screen talk（无相机→投影不出屏）回退 handler，挂 _act_wait；
##     谓词未满足不回包，selected 置位后 _step_act_wait 落定清空 _act_wait。
## 运行: godot --headless --path . --script res://test/test_harness_do.gd

## 触屏事件收集器（替换 event_sink，观察真输入是否发出）。
class TouchCollector extends Object:
	var touches: Array = []
	func capture(ev: InputEvent) -> void:
		if ev is InputEventScreenTouch:
			var t := ev as InputEventScreenTouch
			touches.append({"pos": t.position, "pressed": t.pressed})

## stub 3D 角色：只要能被 get("char_name") 读到名字 + 是 Node3D（投影用 global_position）。
class StubChar3D extends Node3D:
	var char_name := "猪小弟"

## stub fsm inputs：_fsm_inputs().speaking() —— 真 utterance 播放位来源（§3.3）。
class StubInputs extends RefCounted:
	var sp := false
	func speaking() -> bool:
		return sp

## stub 宿主 world：提供 _collect_entities / _snapshot / _gather_facts 读的字段 + talk handler 记录。
class StubWorld extends Node:
	var npcs: Array = []
	var player: Dictionary = {}
	var selected: Node = null
	var camera: Camera3D = null           # 无相机 → 投影一律 off-screen → talk 走 handler 回退
	var pois: Array = []
	var _portals: Array = []
	var _remote_actors: Dictionary = {}
	var chunk_manager = null
	var bag: Dictionary = {}
	var _scene_id := "s1"
	var _in_creation := false
	var _creation_options: Array = []
	var _phone_cam := false
	var _bench_freeze := false
	var _play_blocked := false
	var _stage_active := false
	var talk_npc_calls: Array = []
	var talk_fairy_calls := 0
	func harness_talk_fairy() -> bool:
		talk_fairy_calls += 1
		return true
	var _speaking := false
	func _fsm_state() -> InteractionFsm.State:
		return InteractionFsm.State.LISTENING
	func _fsm_inputs() -> StubInputs:
		var i := StubInputs.new(); i.sp = _speaking; return i
	func harness_talk_npc(who := "") -> bool:
		talk_npc_calls.append(who)
		return true
	func harness_walk_to(_tile: Vector2i) -> bool:
		return true

var _ran := false

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ✓ %s" % name)
		return 0
	printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _find_action_id(elements: Array, prefix: String) -> String:
	for el in elements:
		for a in (el as Dictionary).get("actions", []):
			var aid := String((a as Dictionary).get("action_id", ""))
			if aid.begins_with(prefix):
				return aid
	return ""

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	print("[parse_command：do]")
	var pd := DebugCmdServer.parse_command('{"op":"do","action":"press:btn:/root/X"}')
	fails += _check("do ok", pd.get("ok"), true)
	fails += _check("do action", pd.get("action"), "press:btn:/root/X")
	var pd2 := DebugCmdServer.parse_command('{"op":"do"}')
	fails += _check("do 缺 action 拒", pd2.get("ok"), false)

	# 搭好宿主 + 命令服务器 + 收集器。
	var stub := StubWorld.new()
	var npc := StubChar3D.new()
	get_root().add_child(npc)
	var fairy_node := StubChar3D.new()
	get_root().add_child(fairy_node)
	stub.npcs = [{"node": npc, "id": "pig", "is_fairy": false, "logical": Vector2(5, 5)},
		{"node": fairy_node, "id": "dot", "is_fairy": true, "logical": Vector2(1, 1)}]
	get_root().add_child(stub)
	var server := DebugCmdServer.make(stub)
	get_root().add_child(server)          # 进树才有 get_tree()（_collect_ui 遍历用）
	server.set_process(false)             # 关自动 _process，手动驱 _step_act_wait 保确定性
	var collector := TouchCollector.new()
	server.event_sink = Callable(collector, "capture")

	# 一个根视口按钮（造 press 元素）。
	var btn := Button.new()
	btn.text = "确认"
	btn.position = Vector2(100, 50)
	btn.size = Vector2(80, 40)
	get_root().add_child(btn)

	print("[press：真触屏发到按钮中心（非 pressed.emit）]")
	var els := server._collect_all_elements(false)
	var press_id := _find_action_id(els, "press:btn:")
	fails += _check("press 动作存在", press_id.is_empty(), false)
	var pr: Dictionary = server._do_do(press_id, {})
	fails += _check("press 回包 ok", pr.get("ok"), true)
	fails += _check("press execution=tap", pr.get("execution"), "tap")
	fails += _check("press 发了触屏(按下+抬起)", collector.touches.size(), 2)
	if collector.touches.size() == 2:
		var c: Vector2 = collector.touches[0]["pos"]
		fails += _check("触屏落按钮中心 x", c.x, 140.0)
		fails += _check("触屏落按钮中心 y", c.y, 70.0)
		fails += _check("首事件是按下", collector.touches[0]["pressed"], true)
		fails += _check("次事件是抬起", collector.touches[1]["pressed"], false)

	print("[图标卡：text 空但 tooltip_text 作无障碍名，通用 access 采得到 label]")
	# 造物 build-part 卡是图标卡(text=\"\")——世界给它 tooltip_text=label,describe_control 回退 tooltip,
	# 于是 press:btn 元素带 label,驱动方按名选卡,不需 pick_option 后门。
	var icard := Button.new()
	icard.text = ""                    # 图标卡不显字(幼儿不识字)
	icard.tooltip_text = "三角屋顶"     # 但保留无障碍名
	icard.position = Vector2(300, 200); icard.size = Vector2(120, 120)
	get_root().add_child(icard)
	var els2 := server._collect_all_elements(false)
	var icard_path := String(icard.get_path())
	var found_label := ""
	for el in els2:
		if String((el as Dictionary).get("id", "")) == "ui:" + icard_path:
			found_label = String((el as Dictionary).get("label", ""))
	fails += _check("图标卡 label 回退到 tooltip_text", found_label, "三角屋顶")

	print("[talk：off-screen 回退 handler + _act_wait 延迟落定]")
	var talk_id := _find_action_id(els, "talk:npc:")
	fails += _check("talk 动作存在", talk_id.is_empty(), false)
	var tr: Dictionary = server._do_do(talk_id, {})
	fails += _check("talk 延迟回包(__deferred)", tr.get("__deferred"), true)
	fails += _check("talk 走了 handler 回退", stub.talk_npc_calls.size(), 1)
	fails += _check("handler 收到角色名", stub.talk_npc_calls[0], "猪小弟")
	fails += _check("_act_wait 已挂", server._act_wait.is_empty(), false)
	fails += _check("_act_wait 谓词=talk", server._act_wait.get("predicate"), "talk")
	# selected 未置位：不该落定。
	server._step_act_wait(0.1)
	fails += _check("未 selected 不落定", server._act_wait.is_empty(), false)
	# 置 selected → 下一步落定清空。
	stub.selected = npc
	server._step_act_wait(0.1)
	fails += _check("selected 后落定清空", server._act_wait.is_empty(), true)

	print("[talk:fairy 改点自己（dogfood 实证：直点仙子精灵打不中）；无相机→回退 handler]")
	var fairy_id := _find_action_id(els, "talk:fairy:")
	fails += _check("fairy talk 动作存在", fairy_id.is_empty(), false)
	stub.selected = null
	server._act_wait = {}
	var fr: Dictionary = server._do_do(fairy_id, {})
	fails += _check("fairy talk 延迟回包", fr.get("__deferred"), true)
	# 本单测无相机 → _player_screen_rect() 返 null → 回退 handler harness_talk_fairy（带相机时改 tap 玩家矩形）
	fails += _check("无相机 fairy talk 回退 handler harness_talk_fairy", stub.talk_fairy_calls, 1)
	server._act_wait = {}

	print("[strict click：多命中不静默点首个，报 ambiguous（对齐 Playwright §3.2）]")
	var btn_dup := Button.new()
	btn_dup.text = "确认"                       # 与前面的 btn 同文字 → 2 命中
	btn_dup.position = Vector2(500, 50); btn_dup.size = Vector2(80, 40)
	get_root().add_child(btn_dup)
	var amb: Dictionary = server._do_click_ui("", "确认")
	fails += _check("多命中 ok=false", amb.get("ok"), false)
	fails += _check("多命中 matches>=2", int(amb.get("matches", 0)) >= 2, true)
	fails += _check("错误含 ambiguous", String(amb.get("error", "")).contains("ambiguous"), true)
	# 单命中仍正常（唯一文字）
	var uniq: Dictionary = server._do_click_ui("", "三角屋顶")  # 只有 icard 的 tooltip 匹配? 不——tooltip 非 text
	# icard.text 为空,fuzzy 用 e.text；icard 的 describe text 回退到 tooltip「三角屋顶」→ 唯一命中
	fails += _check("单命中放行(ok 或 not-visible 皆非 ambiguous)", String(uniq.get("error", "")).contains("ambiguous"), false)

	print("[settle 超时诊断：带 settle_reason 说明为什么没落定（对齐 Playwright §3.5）]")
	var base2 := {"ok": true, "op": "do", "action": "talk:npc:ghost"}
	stub.selected = null
	server._act_wait = {"predicate": "talk", "base": base2, "elapsed": 9.0, "deadline": 8.0}
	server._step_act_wait(0.1)                  # elapsed→9.1 ≥ 8.0 → 超时
	fails += _check("超时 settled=false", base2.get("settled"), false)
	fails += _check("超时带 settle_reason", base2.has("settle_reason"), true)
	fails += _check("settle_reason 谓词=talk", (base2.get("settle_reason") as Dictionary).get("predicate"), "talk")
	fails += _check("settle_reason 有 note", (base2.get("settle_reason") as Dictionary).has("note"), true)
	fails += _check("settle_reason 记 waited_sec", (base2.get("settle_reason") as Dictionary).has("waited_sec"), true)

	print("[手机没开:SubViewport 内元素不枚举（老板发现关着的手机按钮不该出现）]")
	var sub_vp := SubViewport.new()
	sub_vp.name = "PhoneScreen"
	get_root().add_child(sub_vp)
	var sub_btn := Button.new()
	sub_btn.text = "手机内按钮"
	sub_vp.add_child(sub_btn)
	stub._phone_cam = false
	var has_sub := func(els: Array) -> bool:
		for el in els:
			if String((el as Dictionary).get("viewport", "root")) != "root":
				return true
		return false
	fails += _check("手机关→无 SubViewport 元素", has_sub.call(server._collect_all_elements(false)), false)
	stub._phone_cam = true
	fails += _check("手机开→SubViewport 元素出现", has_sub.call(server._collect_all_elements(false)), true)
	stub._phone_cam = false

	print("[统一输入门 _act_gate：loading/intro(_bench_freeze) 等阻塞态一处判，交互动作 disabled+reason]")
	stub._bench_freeze = true
	fails += _check("bench_freeze → gated", server._act_gate()["gated"], true)
	fails += _check("bench_freeze → reason loading_intro", server._act_gate()["reason"], "loading_intro")
	var gated_els := server._collect_all_elements(false)
	var npc_el := {}
	for el in gated_els:
		if String((el as Dictionary).get("kind", "")) == "npc":
			npc_el = el
	fails += _check("gated 下有 npc 元素", npc_el.is_empty(), false)
	if not npc_el.is_empty():
		var ta := (npc_el["actions"][0]) as Dictionary
		fails += _check("bench_freeze 下 npc talk disabled", ta.get("enabled"), false)
		fails += _check("bench_freeze npc talk reason", ta.get("reason_disabled"), "loading_intro")
	stub._bench_freeze = false

	print("[真 speaking 位：快照反映 _fsm_inputs().speaking()（对齐 Playwright §3.3）]")
	stub._speaking = true
	fails += _check("说话中 speaking=true", server._snapshot().get("speaking"), true)
	stub._speaking = false
	fails += _check("说完 speaking=false", server._snapshot().get("speaking"), false)

	print("[服务端 wait op：条件满足即回 / 未满足挂 _act_wait 逐帧查（§3.3 干掉客户端轮询）]")
	var wp := DebugCmdServer.parse_command('{"op":"wait","field":"speaking","falsy":true}')
	fails += _check("wait parse ok", wp.get("ok"), true)
	fails += _check("wait conds mode=falsy", ((wp.get("conds") as Array)[0] as Dictionary).get("mode"), "falsy")
	fails += _check("cond truthy 命中", server._cond_match({"x": 1}, {"field": "x", "mode": "truthy"}), true)
	fails += _check("cond gte 命中", server._cond_match({"n": 8}, {"field": "n", "mode": "gte", "target": 8}), true)
	fails += _check("cond gte 不足", server._cond_match({"n": 7}, {"field": "n", "mode": "gte", "target": 8}), false)
	fails += _check("cond equals 命中", server._cond_match({"s": "a"}, {"field": "s", "mode": "equals", "target": "a"}), true)
	# ★ null 安全：缺失字段的 truthy/falsy 不能 bool(null) 抛错（GDScript 无 null→bool 构造）
	fails += _check("cond truthy 缺失=false", server._cond_match({}, {"field": "gone", "mode": "truthy"}), false)
	fails += _check("cond falsy 缺失=true", server._cond_match({}, {"field": "gone", "mode": "falsy"}), true)
	fails += _check("conds 全 AND", server._conds_all_match({"a": 1, "b": 0}, [{"field": "a", "mode": "truthy"}, {"field": "b", "mode": "falsy"}]), true)
	# 已满足即回（speaking=false → falsy 满足）
	stub._speaking = false
	var wi := server._do_wait([{"field": "speaking", "mode": "falsy"}], 5.0)
	fails += _check("已满足即回 matched", wi.get("matched"), true)
	fails += _check("已满足非 deferred", wi.has("__deferred"), false)
	# 未满足挂 _act_wait（speaking=true → falsy 不满足）
	stub._speaking = true
	var wd := server._do_wait([{"field": "speaking", "mode": "falsy"}], 5.0)
	fails += _check("未满足 deferred", wd.get("__deferred"), true)
	fails += _check("挂 _act_wait predicate=conds", server._act_wait.get("predicate"), "conds")
	# 变满足 → 逐帧查落定清空
	stub._speaking = false
	server._step_act_wait(0.1)
	fails += _check("满足后落定清空 _act_wait", server._act_wait.is_empty(), true)

	if fails == 0:
		print("[PASS] test_harness_do")
	else:
		printerr("[FAIL] test_harness_do: %d 处" % fails)
	quit(fails)
