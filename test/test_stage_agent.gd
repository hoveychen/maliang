extends SceneTree
## StageAgent 舞台协议大脑（P4）：stage_cmd 分发、完成型回 ack、设置/占位型即刻 ack、
## 跨场/重复回执守护、多人 host 记录。用 FakeHost 注入观测，不依赖真实音频/执行器。
## 运行: godot --headless --path . --script res://test/test_stage_agent.gd

## 能力宿主 mock（与 test_screenplay_replay.gd 共用）。
const FakeHost = preload("res://test/support/stage_host_double.gd")

var _events: Array = []

func _init() -> void:
	var fails := 0
	var host := FakeHost.new()
	var agent := StageAgent.new()
	agent.setup(host, Callable(self, "_on_event"))
	fails += _eq("默认非 host", agent.is_host(), false)  # 握手前缺省非 host

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
	agent.on_world_host(true)  # 单机即 host：主流程 NPC 命令按本端模拟执行验证（非 host 过滤见文末）

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

	# 设置型（follow/flee/stop/banner/hud/prop_place/prop_remove）：路由到宿主 + 即刻回执
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 100, "op": "follow", "args": { "target": "p1" }, "actorId": "duck" })
	fails += _eq("follow 触宿主", String(host.last("follow").get("actor", "")), "duck")
	fails += _eq("follow 传目标", String(host.last("follow").get("target", "")), "p1")
	fails += _eq("follow 即刻回执", _ack_for(100).is_empty(), false)

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 101, "op": "flee", "args": { "target": "duck" }, "actorId": "p1" })
	fails += _eq("flee 触宿主", String(host.last("flee").get("target", "")), "duck")
	fails += _eq("flee 即刻回执", _ack_for(101).is_empty(), false)

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 102, "op": "stop", "args": {}, "actorId": "duck" })
	fails += _eq("stop 触宿主", String(host.last("stop").get("actor", "")), "duck")
	fails += _eq("stop 即刻回执", _ack_for(102).is_empty(), false)

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 103, "op": "hud_score", "args": { "id": "h1", "label": "抓到" } })
	fails += _eq("hud_score 触宿主", String(host.last("hud_score").get("label", "")), "抓到")
	fails += _eq("hud_score 即刻回执", _ack_for(103).is_empty(), false)

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 104, "op": "hud_score_add", "args": { "id": "h1", "n": 2 } })
	fails += _eq("hud_score_add 传增量", int(host.last("hud_score_add").get("n", 0)), 2)

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 105, "op": "hud_countdown", "args": { "id": "h2", "sec": 60, "serverStartMs": 111 } })
	fails += _eq("hud_countdown 传时长", int(host.last("hud_countdown").get("sec", 0)), 60)
	fails += _eq("hud_countdown 传服务端时戳", int(host.last("hud_countdown").get("start", 0)), 111)

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 106, "op": "hud_toast", "args": { "text": "开始！" } })
	fails += _eq("hud_toast 触宿主", String(host.last("hud_toast").get("text", "")), "开始！")

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 107, "op": "banner", "args": { "text": "第一幕" } })
	fails += _eq("banner 触宿主", String(host.last("banner").get("text", "")), "第一幕")

	# camera：路由到宿主运镜 + 即刻回执（cosmetic，不卡脚本）
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 108, "op": "camera", "args": { "mode": "overview" } })
	fails += _eq("camera overview 触宿主", String(host.last("camera").get("mode", "")), "overview")
	fails += _eq("camera 即刻回执", _ack_for(108).is_empty(), false)
	# focus 的演员在 args.actorId；dialog 的两人在 args.a / args.b
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 109, "op": "camera", "args": { "mode": "focus", "actorId": "duck" } })
	fails += _eq("camera focus 传演员", String(host.last("camera").get("a", "")), "duck")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 113, "op": "camera", "args": { "mode": "dialog", "a": "duck", "b": "p1" } })
	fails += _eq("camera dialog 传 a", String(host.last("camera").get("a", "")), "duck")
	fails += _eq("camera dialog 传 b", String(host.last("camera").get("b", "")), "p1")

	# prop_spawn：完成型——宿主落位后回 done 才 ack，回执带 prop id
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 110, "op": "prop_spawn", "args": { "id": "egg1", "spec": { "k": 1 }, "near": "duck" } })
	fails += _eq("prop_spawn 触宿主", String(host.last("prop_spawn").get("id", "")), "egg1")
	fails += _eq("prop_spawn 未完成不回执", _ack_for(110).is_empty(), true)
	host.last_prop_done.call(true, { "id": "egg1" })
	fails += _eq("prop_spawn 完成回执带 id", String((_ack_for(110).get("result", {}) as Dictionary).get("id", "")), "egg1")

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 111, "op": "prop_place", "args": { "id": "egg1", "at": { "x": 3, "y": 4 } } })
	fails += _eq("prop_place 触宿主", String(host.last("prop_place").get("id", "")), "egg1")
	fails += _eq("prop_place 即刻回执", _ack_for(111).is_empty(), false)

	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 112, "op": "prop_remove", "args": { "id": "egg1" } })
	fails += _eq("prop_remove 触宿主", String(host.last("prop_remove").get("id", "")), "egg1")

	# watch/unwatch（cmdId=-1，无 ack）+ 规则事件上行
	_events.clear()
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": -1, "op": "watch", "args": { "subId": "sub_tap", "ev": "tap", "params": { "actorId": "duck" } } })
	fails += _eq("watch 不回执", _events.size(), 0)
	# 点到被 watch 的演员 → 上行 tap 事件带 subId
	agent.on_local_tap("duck")
	fails += _eq("tap 上行 subId", String(_last_event_of("tap").get("subId", "")), "sub_tap")
	fails += _eq("tap 上行 payload actorId", String((_last_event_of("tap").get("payload", {}) as Dictionary).get("actorId", "")), "duck")
	# 去重：同角色紧邻两次点击（触屏 ScreenTouch + 仿真 MouseButton）只上行一次
	var taps_before := _count_kind("tap")
	agent.on_local_tap("duck")
	fails += _eq("tap 去重只上行一次", _count_kind("tap"), taps_before)
	# 点未被 watch 的演员 → 不上行
	agent.on_local_tap("p1")
	fails += _eq("未 watch 演员 tap 不上行", _count_kind("tap"), taps_before)

	# timer：watch 倒计时归零 → 上行 timer 事件带 subId
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": -1, "op": "watch", "args": { "subId": "sub_timer", "ev": "timer", "params": { "id": "h2" } } })
	agent.on_timer_done("h2")
	fails += _eq("timer 上行 subId", String(_last_event_of("timer").get("subId", "")), "sub_timer")
	# unwatch 后不再触发
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": -1, "op": "unwatch", "args": { "subId": "sub_timer" } })
	var timers_before := _count_kind("timer")
	agent.on_timer_done("h2")
	fails += _eq("unwatch 后 timer 不上行", _count_kind("timer"), timers_before)

	# prompt 占位：回执带空 text
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 200, "op": "prompt", "args": { "hint": "该你了" }, "actorId": "p1" })
	fails += _eq("prompt 回执带 result", (_ack_for(200).get("result", {}) as Dictionary).has("text"), true)

	# 未知命令：回执带 error
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 201, "op": "teleport", "args": {} })
	fails += _eq("未知命令回执带 error", String(_ack_for(201).get("error", "")).is_empty(), false)

	# 多人 host setter 往返
	agent.on_world_host(false)
	fails += _eq("world_host 置 false", agent.is_host(), false)
	agent.on_world_host(true)
	fails += _eq("world_host 置 true", agent.is_host(), true)

	# --- 多人所有权过滤（P6）：非 host 端不模拟 NPC 命令；玩家/say/旁白照跑 ---
	agent.on_world_host(false)
	# NPC 完成型（move_to/do_action）：非 host 不触宿主、不回 ack（完成 ack 由 host 权威）
	var move_before := host.count("move")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 300, "op": "move_to", "args": { "target": "pond" }, "actorId": "duck" })
	fails += _eq("非host NPC move 不触宿主", host.count("move"), move_before)
	fails += _eq("非host NPC move 不回 ack", _ack_for(300).is_empty(), true)
	var action_before := host.count("action")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 301, "op": "do_action", "args": { "action": "jump" }, "actorId": "duck" })
	fails += _eq("非host NPC do_action 不触宿主", host.count("action"), action_before)
	fails += _eq("非host NPC do_action 不回 ack", _ack_for(301).is_empty(), true)
	# NPC 设置型（follow/stop）：非 host 不触宿主，但即刻回 ack（脚本不卡）
	var follow_before := host.count("follow")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 302, "op": "follow", "args": { "target": "p1" }, "actorId": "duck" })
	fails += _eq("非host NPC follow 不触宿主", host.count("follow"), follow_before)
	fails += _eq("非host NPC follow 仍即刻回 ack", _ack_for(302).is_empty(), false)
	var stop_before := host.count("stop")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 303, "op": "stop", "args": {}, "actorId": "duck" })
	fails += _eq("非host NPC stop 不触宿主", host.count("stop"), stop_before)
	fails += _eq("非host NPC stop 仍即刻回 ack", _ack_for(303).is_empty(), false)
	# 玩家 avatar 永远本端模拟：非 host 也触宿主
	var pmove_before := host.count("move")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 304, "op": "move_to", "args": { "target": "home" }, "actorId": "p1" })
	fails += _eq("非host 玩家 move 仍触宿主", host.count("move"), pmove_before + 1)
	# say/narrate 是表现：非 host 全端播放
	var say_before := host.count("say")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 305, "op": "say", "args": { "text": "嘎" }, "actorId": "duck" })
	fails += _eq("非host NPC say 仍触宿主", host.count("say"), say_before + 1)
	var narrate_before := host.count("narrate")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 306, "op": "narrate", "args": { "text": "旁白" } })
	fails += _eq("非host 旁白仍触宿主", host.count("narrate"), narrate_before + 1)
	# host 端不过滤：NPC move 正常触宿主
	agent.on_world_host(true)
	var hmove_before := host.count("move")
	agent.on_stage_cmd({ "stageId": "s1", "cmdId": 307, "op": "move_to", "args": { "target": "pond" }, "actorId": "duck" })
	fails += _eq("host NPC move 触宿主", host.count("move"), hmove_before + 1)

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

func _on_event(kind: String, cmd_id: int, result: Dictionary, error: String, sub_id := "", payload := {}) -> void:
	_events.append({ "kind": kind, "cmdId": cmd_id, "result": result, "error": error, "subId": sub_id, "payload": payload })

## 找某 cmdId 的 ack 事件（无则 {}）。
func _ack_for(cmd_id: int) -> Dictionary:
	for e in _events:
		if String(e["kind"]) == "ack" and int(e["cmdId"]) == cmd_id:
			return e
	return {}

## 最后一个某 kind 的事件（无则 {}）。
func _last_event_of(kind: String) -> Dictionary:
	for i in range(_events.size() - 1, -1, -1):
		if String(_events[i]["kind"]) == kind:
			return _events[i]
	return {}

## 某 kind 事件计数。
func _count_kind(kind: String) -> int:
	var n := 0
	for e in _events:
		if String(e["kind"]) == kind:
			n += 1
	return n

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
