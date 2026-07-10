extends SceneTree
## StageAgent 舞台协议大脑（P4）：stage_cmd 分发、完成型回 ack、设置/占位型即刻 ack、
## 跨场/重复回执守护、多人 host 记录。用 FakeHost 注入观测，不依赖真实音频/执行器。
## 运行: godot --headless --path . --script res://test/test_stage_agent.gd

## 能力宿主 mock：记录被调命令，扣住 done 回调供测试手动触发（模拟演出完成）。
class FakeHost:
	extends RefCounted
	var calls: Array = []
	var last_move_done := Callable()
	var last_action_done := Callable()
	var last_say_done := Callable()
	var last_narrate_done := Callable()
	func stage_begin(actors: Array) -> void:
		calls.append({ "m": "begin", "actors": actors })
	func stage_finish(result: Dictionary, aborted: bool, reason: String) -> void:
		calls.append({ "m": "finish", "result": result, "aborted": aborted, "reason": reason })
	func stage_move(actor_id: String, target: Variant, done: Callable) -> void:
		calls.append({ "m": "move", "actor": actor_id, "target": target })
		last_move_done = done
	func stage_action(actor_id: String, action: String, done: Callable) -> void:
		calls.append({ "m": "action", "actor": actor_id, "action": action })
		last_action_done = done
	func stage_say(actor_id: String, text: String, action: String, voice_id: String, done: Callable) -> void:
		calls.append({ "m": "say", "actor": actor_id, "text": text, "action": action, "voice": voice_id })
		last_say_done = done
	func stage_narrate(text: String, done: Callable) -> void:
		calls.append({ "m": "narrate", "text": text })
		last_narrate_done = done
	func count(m: String) -> int:
		var n := 0
		for c in calls:
			if String(c["m"]) == m:
				n += 1
		return n
	func last(m: String) -> Dictionary:
		for i in range(calls.size() - 1, -1, -1):
			if String(calls[i]["m"]) == m:
				return calls[i]
		return {}

var _events: Array = []

func _init() -> void:
	var fails := 0
	var host := FakeHost.new()
	var agent := StageAgent.new()
	agent.setup(host, Callable(self, "_on_event"))

	# 无演出：命令被忽略，不触宿主不回执
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 1, "op": "narrate", "args": { "text": "x" } })
	fails += _eq("无演出忽略命令-无宿主调用", host.calls.size(), 0)
	fails += _eq("无演出忽略命令-无 ack", _events.size(), 0)
	fails += _eq("初始未激活", agent.active(), false)

	# 开演：宿主收到 actors，激活
	agent.on_stage_begin({ "stageId": "s1", "actors": [
		{ "id": "duck", "name": "丑小鸭", "isPlayer": false, "voiceId": "zh-CN-YunxiaNeural" },
		{ "id": "p1", "name": "小明", "isPlayer": true },
	] })
	fails += _eq("开演激活", agent.active(), true)
	fails += _eq("宿主收到 begin", host.count("begin"), 1)
	fails += _eq("begin 带两个演员", (host.last("begin")["actors"] as Array).size(), 2)

	# 串场旧命令（stageId 不符）：忽略
	agent.on_stage_cmd({ "stageId": "OTHER", "cmdId": 2, "op": "narrate", "args": { "text": "y" } })
	fails += _eq("异场命令忽略", host.count("narrate"), 0)

	# narrate：完成型，宿主调用但暂不回执，done 后才 ack
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 10, "op": "narrate", "args": { "text": "从前…" } })
	fails += _eq("narrate 触宿主", host.count("narrate"), 1)
	fails += _eq("narrate 未完成不回执", _ack_for(10).is_empty(), true)
	host.last_narrate_done.call(true, {})
	fails += _eq("narrate 完成回执", _ack_for(10).is_empty(), false)
	fails += _eq("narrate ack kind", String(_ack_for(10).get("kind", "")), "ack")

	# say（有音色）：宿主收角色音色，done 后回执
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 11, "op": "say", "args": { "text": "嘎", "action": "wave" } , "actorId": "duck" })
	fails += _eq("say 触宿主", host.count("say"), 1)
	fails += _eq("say 传对音色", String(host.last("say").get("voice", "")), "zh-CN-YunxiaNeural")
	fails += _eq("say 传动作", String(host.last("say").get("action", "")), "wave")
	fails += _eq("say 未完成不回执", _ack_for(11).is_empty(), true)
	host.last_say_done.call(true, {})
	fails += _eq("say 完成回执", _ack_for(11).is_empty(), false)

	# say（玩家无音色）：不触 TTS 宿主，即刻回执
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 12, "op": "say", "args": { "text": "我来啦" }, "actorId": "p1" })
	fails += _eq("玩家 say 不触 TTS 宿主", host.count("say"), 1)
	fails += _eq("玩家 say 即刻回执", _ack_for(12).is_empty(), false)

	# move_to：完成型，target 原样透传
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 13, "op": "move_to", "args": { "target": "pond" }, "actorId": "duck" })
	fails += _eq("move 触宿主", host.count("move"), 1)
	fails += _eq("move target 透传", String(host.last("move").get("target", "")), "pond")
	fails += _eq("move 未完成不回执", _ack_for(13).is_empty(), true)
	var move_done := host.last_move_done
	move_done.call(true, {})
	fails += _eq("move 完成回执", _ack_for(13).is_empty(), false)
	# 重复完成：只回执一次（守护）
	var acks_before := _count_ack(13)
	move_done.call(true, {})
	fails += _eq("重复完成只回执一次", _count_ack(13), acks_before)

	# do_action：完成型
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 14, "op": "do_action", "args": { "action": "jump" }, "actorId": "duck" })
	fails += _eq("do_action 触宿主", host.count("action"), 1)
	fails += _eq("do_action 传动作", String(host.last("action").get("action", "")), "jump")
	host.last_action_done.call(true, {})
	fails += _eq("do_action 完成回执", _ack_for(14).is_empty(), false)

	# 完成型失败：回执带 error
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 15, "op": "move_to", "args": { "target": "nowhere" }, "actorId": "duck" })
	host.last_move_done.call(false, { "error": "无法解析" })
	fails += _eq("move 失败回执带 error", String(_ack_for(15).get("error", "")), "无法解析")

	# 设置/占位型（P5 域）：即刻回执，不触宿主
	var stub_ops := ["follow", "flee", "stop", "banner", "hud_score", "hud_countdown", "camera", "prop_create"]
	for i in range(stub_ops.size()):
		var op: String = stub_ops[i]
		var cid := 100 + i
		var before := host.calls.size()
		agent.on_stage_cmd({ "stageId": "s1", "cmdId": cid, "op": op, "args": {}, "actorId": "duck" })
		fails += _eq("%s 不触宿主" % op, host.calls.size(), before)
		fails += _eq("%s 即刻回执" % op, _ack_for(cid).is_empty(), false)

	# prompt 占位：回执带空 text
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 200, "op": "prompt", "args": { "hint": "该你了" }, "actorId": "p1" })
	fails += _eq("prompt 回执带 result", (_ack_for(200).get("result", {}) as Dictionary).has("text"), true)

	# 未知命令：回执带 error
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 201, "op": "teleport", "args": {} })
	fails += _eq("未知命令回执带 error", String(_ack_for(201).get("error", "")).is_empty(), false)

	# 多人 host 记录
	fails += _eq("默认非 host", agent.is_host(), false)
	agent.on_world_host(true)
	fails += _eq("world_host 更新", agent.is_host(), true)

	# 收场：宿主 finish（正常），失活；跨场后迟到的完成回调被吞
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 30, "op": "move_to", "args": { "target": "pond" }, "actorId": "duck" })
	var stale_done := host.last_move_done
	agent.on_stage_end({ "stageId": "s1", "result": { "praise": "真棒" } })
	fails += _eq("收场失活", agent.active(), false)
	fails += _eq("宿主收到 finish", host.count("finish"), 1)
	fails += _eq("finish 非 abort", bool(host.last("finish").get("aborted", true)), false)
	fails += _eq("finish 带 result", String((host.last("finish").get("result", {}) as Dictionary).get("praise", "")), "真棒")
	stale_done.call(true, {}) # 跨场迟到完成：不应回执
	fails += _eq("跨场迟到完成被吞", _ack_for(30).is_empty(), true)

	# 终止：finish(aborted=true, reason)
	agent.on_stage_begin({ "stageId": "s2", "actors": [] })
	agent.on_stage_abort({ "stageId": "s2", "reason": "超时" })
	fails += _eq("终止失活", agent.active(), false)
	fails += _eq("finish abort=true", bool(host.last("finish").get("aborted", false)), true)
	fails += _eq("finish 带 reason", String(host.last("finish").get("reason", "")), "超时")

	# request_abort：无演出不发；有演出发 abort 上行
	_events.clear()
	agent.request_abort()
	fails += _eq("无演出不发 abort", _events.size(), 0)
	agent.on_stage_begin({ "stageId": "s3", "actors": [] })
	agent.request_abort()
	fails += _eq("有演出发 abort", String(_events[-1].get("kind", "")), "abort")

	if fails == 0:
		print("stage_agent tests PASS")
	else:
		printerr("stage_agent tests FAILED: %d" % fails)
	quit(fails)

func _on_event(kind: String, cmd_id: int, result: Dictionary, error: String) -> void:
	_events.append({ "kind": kind, "cmdId": cmd_id, "result": result, "error": error })

## 找某 cmdId 的 ack 事件（无则 {}）。
func _ack_for(cmd_id: int) -> Dictionary:
	for e in _events:
		if String(e["kind"]) == "ack" and int(e["cmdId"]) == cmd_id:
			return e
	return {}

func _count_ack(cmd_id: int) -> int:
	var n := 0
	for e in _events:
		if String(e["kind"]) == "ack" and int(e["cmdId"]) == cmd_id:
			n += 1
	return n

func _eq(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
