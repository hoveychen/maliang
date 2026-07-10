extends SceneTree
## P8 端到端冒烟：把服务端两个手写剧本**真实产生**的命令流回放进 StageAgent。
## 命令流 test/fixtures/screenplay_cmds.json 由 server/test/screenplay_e2e.test.ts 录制
## （改了剧本就 UPDATE_GOLDEN=1 npm test 重录）——所以这里验的是跨端契约：
## 服务端会发的每一条命令，客户端都认得、都回执、没有一条落进「未知命令」。
## 运行: godot --headless --path . --script res://test/test_screenplay_replay.gd

const FakeHost = preload("res://test/support/stage_host_double.gd")

var _events: Array = []

func _init() -> void:
	var fails := 0
	var raw := FileAccess.get_file_as_string("res://test/fixtures/screenplay_cmds.json")
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		printerr("  FAIL 读不到命令流 golden: res://test/fixtures/screenplay_cmds.json")
		quit(1)
		return
	var golden := data as Dictionary

	# --- 躲猫猫：事件驱动 + HUD + 换鬼 ---
	var hide := _replay("hide_and_seek", golden)
	fails += _fails
	fails += _eq("躲猫猫: 鬼追人一次", hide.count("follow"), 1)
	fails += _eq("躲猫猫: 换鬼后鬼开逃一次", hide.count("flee"), 1)
	fails += _eq("躲猫猫: 两轮各停一次", hide.count("stop"), 2)
	fails += _eq("躲猫猫: 计分板建一次", hide.count("hud_score"), 1)
	fails += _eq("躲猫猫: 两轮各计一分", hide.count("hud_score_add"), 2)
	fails += _eq("躲猫猫: 倒计时建一次", hide.count("hud_countdown"), 1)
	fails += _eq("躲猫猫: 收场前撤倒计时", hide.count("hud_cancel"), 1)
	fails += _eq("躲猫猫: 抓到弹一次 toast", hide.count("hud_toast"), 1)
	fails += _eq("躲猫猫: 三段旁白", hide.count("narrate"), 3)
	fails += _eq("躲猫猫: 倒计时 60 秒", int(hide.last("hud_countdown").get("sec", 0)), 60)
	# near 由服务端对复制位置求值，不下发客户端探测器；只有 timer 需要客户端布置
	fails += _eq("躲猫猫: near 不下发客户端探测器", _count_watch(golden["hide_and_seek"], "near"), 0)
	fails += _eq("躲猫猫: timer 下发一个客户端探测器", _count_watch(golden["hide_and_seek"], "timer"), 1)

	# --- 三幕小剧场：旁白 + 并行走位 + 对话运镜 ---
	var play := _replay("three_act_play", golden)
	fails += _fails
	fails += _eq("小剧场: 三段旁白", play.count("narrate"), 3)
	fails += _eq("小剧场: 三次幕次横幅", play.count("banner"), 3)
	fails += _eq("小剧场: 四次走位", play.count("move"), 4)
	fails += _eq("小剧场: 四句台词", play.count("say"), 4)
	fails += _eq("小剧场: 一个动作", play.count("action"), 1)
	# 造物要真跑一趟 LLM+生图，几十秒卡在幕中间：剧本刻意不碰道具（原语覆盖在服务端单测）
	fails += _eq("小剧场: 演出全程不等造物", play.count("prop_spawn"), 0)
	# 台词用的是角色自己的音色（服务端随 stage_begin 下发的 voiceId）
	fails += _eq("小剧场: 天鹅用自己的音色", String(play.last("say").get("voice", "")), "zh-CN-XiaoyiNeural")

	if fails == 0:
		print("screenplay_replay tests PASS")
	else:
		printerr("screenplay_replay tests FAILED: %d" % fails)
	quit(fails)

var _fails := 0

## 命令流里 watch(ev=…) 的条数：验证哪些规则要客户端布探测器。
func _count_watch(spec: Dictionary, ev: String) -> int:
	var n := 0
	for c: Dictionary in spec.get("cmds", []):
		if String(c["op"]) == "watch" and String((c.get("args", {}) as Dictionary).get("ev", "")) == ev:
			n += 1
	return n

## 回放一份剧本的命令流：逐条喂给 StageAgent，完成型命令立刻回报完成。
## 断言每条需回执的命令都回了执、且没有一条带 error（= 客户端认得全部 op）。
func _replay(name: String, golden: Dictionary) -> FakeHost:
	_fails = 0
	_events.clear()
	var spec := golden.get(name, {}) as Dictionary
	var host := FakeHost.new()
	var agent := StageAgent.new()
	agent.setup(host, Callable(self, "_on_event"))
	agent.on_stage_begin({ "stageId": "s1", "actors": spec.get("actors", []) })
	agent.on_world_host(true)  # 单端回放：本端就是 host，NPC 命令都要本端模拟

	var need_ack := 0
	for c: Dictionary in spec.get("cmds", []):
		var cmd_id := int(c["cmdId"])
		var op := String(c["op"])
		var args := c.get("args", {}) as Dictionary
		var cmd := { "stageId": "s1", "cmdId": cmd_id, "op": op, "args": args }
		if c.has("actorId"):
			cmd["actorId"] = c["actorId"]
		agent.on_stage_cmd(cmd)
		if cmd_id > 0:
			need_ack += 1
		_complete(host, op, args)

	_fails += _eq(name + ": 每条命令都回执", _count_kind("ack"), need_ack)
	var errs := _ack_errors()
	_fails += _eq(name + ": 没有命令被判未知/失败 %s" % [errs], errs.size(), 0)

	# watch(timer) 的 params.id 必须对得上 hud_countdown 的 id，否则客户端计时归零找不到订阅
	if name == "hide_and_seek":
		agent.on_timer_done(String(host.last("hud_countdown").get("id", "")))
		_fails += _eq(name + ": 倒计时归零上行绑定服务端 subId", String(_last_event_of("timer").get("subId", "")), "s1")

	agent.on_stage_end({ "stageId": "s1", "result": { "praise": "真棒" } })
	_fails += _eq(name + ": 收场失活", agent.active(), false)
	_fails += _eq(name + ": 宿主收到 finish", host.count("finish"), 1)
	return host

## 完成型命令：宿主这边立刻回报「演完了」，让下一条命令得以推进。
func _complete(host: FakeHost, op: String, args: Dictionary) -> void:
	match op:
		"narrate":
			if host.last_narrate_done.is_valid():
				host.last_narrate_done.call(true, {})
		"say":
			if host.last_say_done.is_valid():
				host.last_say_done.call(true, {})
		"move_to":
			if host.last_move_done.is_valid():
				host.last_move_done.call(true, {})
		"do_action":
			if host.last_action_done.is_valid():
				host.last_action_done.call(true, {})
		"prop_spawn":
			if host.last_prop_done.is_valid():
				host.last_prop_done.call(true, { "id": String(args.get("id", "")) })

func _on_event(kind: String, cmd_id: int, result: Dictionary, error: String, sub_id := "", payload := {}) -> void:
	_events.append({ "kind": kind, "cmdId": cmd_id, "result": result, "error": error, "subId": sub_id, "payload": payload })

## 所有带 error 的回执（未知命令/执行失败都会落这里）。
func _ack_errors() -> Array:
	var out: Array = []
	for e in _events:
		if String(e["kind"]) == "ack" and not String(e["error"]).is_empty():
			out.append("cmd#%d: %s" % [int(e["cmdId"]), String(e["error"])])
	return out

func _count_kind(kind: String) -> int:
	var n := 0
	for e in _events:
		if String(e["kind"]) == kind:
			n += 1
	return n

func _last_event_of(kind: String) -> Dictionary:
	for i in range(_events.size() - 1, -1, -1):
		if String(_events[i]["kind"]) == kind:
			return _events[i]
	return {}

func _eq(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
