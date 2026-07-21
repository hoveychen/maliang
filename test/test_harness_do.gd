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
	var _play_blocked := false
	var _stage_active := false
	var talk_npc_calls: Array = []
	func _fsm_state() -> InteractionFsm.State:
		return InteractionFsm.State.LISTENING
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
	stub.npcs = [{"node": npc, "id": "pig", "is_fairy": false, "logical": Vector2(5, 5)}]
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

	if fails == 0:
		print("[PASS] test_harness_do")
	else:
		printerr("[FAIL] test_harness_do: %d 处" % fails)
	quit(fails)
