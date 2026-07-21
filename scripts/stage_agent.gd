class_name StageAgent
extends RefCounted
## 舞台协议客户端大脑：把服务端下发的 stage_cmd 翻译成本地演出能力调用，完成后回 ack。
## 与具体演出实现解耦——host 是能力执行器（world.gd 实现；单测注入 mock），
## send_event 是上行通道 Callable(kind:String, cmd_id:int, result:Dictionary, error:String)。
## 设计文档: docs/script-runtime-design.md
##
## 完成语义（每条 cmd 恰好一个 ack）：
##   - 完成型 narrate/say/move_to/do_action/prop_spawn：host 演完调 done 回调才 ack。
##   - 设置型（follow/flee/stop/banner/hud/prop_place/prop_remove/camera）：即刻 ack，脚本不卡。
##   - watch/unwatch（cmdId=-1）：布置/撤销规则探测器，无 ack。
##   - prompt：完成型——宿主开麦让小朋友说一段（尾声复述），说完/超时/离线跳过后带 { text } ack。
##
## 规则事件（tap/timer）：客户端本地探测（点角色 / 倒计时归零）→ send_event(kind,subId) 上行，
## 服务端注回脚本对应订阅回调。near 由服务端对复制位置求值（不下发客户端探测器），客户端对 near 不做本地探测。
## 多人所有权（P6）：非 host 端不模拟 NPC 命令（走位/跟随/停/动作），只渲染 host 复制来的位置；
## say/HUD/旁白等表现型命令全端执行；玩家 avatar 永远本端模拟。见 _skip_npc_sim。

var _host: Object
var _send: Callable
var _stage_id := ""           ## 当前演出 id（stage_begin 起，end/abort 清）
var _is_host := false         ## 多人所有权：本连接是否 host（NPC 命令过滤用，见 _skip_npc_sim）
var _server_offset_ms := 0    ## 服务端时间偏移 serverMs - 本地钟（倒计时读数换算/P6 插值用）
var _actors := {}             ## actorId → { name, is_player, voice_id }
var _acked := {}              ## 本场已回执的 cmdId（防重复 ack）
var _subs := {}               ## subId → { ev, params }：活动规则订阅（watch 布置，unwatch/收场撤销）
var _tap_seen := {}           ## actorId → 上次 tap 毫秒：去重触屏一次点击的 ScreenTouch+仿真 MouseButton 双发

const TAP_DEBOUNCE_MS := 150  ## 同角色两次 tap 上行的最小间隔（滤掉同一物理点击的双事件）

func setup(host: Object, send_event: Callable) -> void:
	_host = host
	_send = send_event

func active() -> bool:
	return not _stage_id.is_empty()

func is_host() -> bool:
	return _is_host

func server_offset_ms() -> int:
	return _server_offset_ms

## 多人所有权回执：首位进入者为 host（负责 NPC 模拟，P6 消费）。
func on_world_host(is_host: bool) -> void:
	_is_host = is_host

## 时间握手回执：单次偏移估算（忽略 RTT/2，P6 做多采样精修）。serverMs 为服务端墙钟毫秒。
func on_time_sync(data: Dictionary) -> void:
	var server_ms := int(data.get("serverMs", 0))
	if server_ms > 0:
		_server_offset_ms = server_ms - Time.get_ticks_msec()

func on_stage_begin(data: Dictionary) -> void:
	_stage_id = String(data.get("stageId", ""))
	_acked.clear()
	_actors.clear()
	_subs.clear()
	var actors: Array = data.get("actors", [])
	for a in actors:
		var info: Dictionary = a
		_actors[String(info.get("id", ""))] = {
			"name": String(info.get("name", "")),
			"is_player": bool(info.get("isPlayer", false)),
			"voice_id": String(info.get("voiceId", "")),
		}
	if _host != null:
		_host.stage_begin(actors)

func on_stage_end(data: Dictionary) -> void:
	_finish(data.get("result", {}), false, "")

func on_stage_abort(data: Dictionary) -> void:
	_finish({}, true, String(data.get("reason", "")))

func _finish(result: Dictionary, aborted: bool, reason: String) -> void:
	if _stage_id.is_empty():
		return
	_stage_id = ""
	_actors.clear()
	_acked.clear()
	_subs.clear()
	if _host != null:
		_host.stage_finish(result, aborted, reason)

## 玩家/观众主动叫停（"不玩了"）：请求服务端终止本场演出（服务端杀 worker，回 stage_abort）。
func request_abort() -> void:
	if active():
		_send.call("abort", -1, {}, "")

func on_stage_cmd(data: Dictionary) -> void:
	if _stage_id.is_empty() or String(data.get("stageId", "")) != _stage_id:
		return  # 无演出 / 串场旧命令：忽略
	var cmd_id := int(data.get("cmdId", -1))
	var actor_id := String(data.get("actorId", ""))
	var op := String(data.get("op", ""))
	var args: Dictionary = data.get("args", {})
	match op:
		"narrate":
			_host.stage_narrate(String(args.get("text", "")), _done(cmd_id))
		"say":
			_dispatch_say(cmd_id, actor_id, args)
		"move_to":
			# NPC 走位是模拟：非 host 不跑，静候 host 复制位置；完成 ack 由 host 权威（此端不回 ack）。
			if _skip_npc_sim(actor_id):
				return
			_host.stage_move(actor_id, args.get("target"), _done(cmd_id))
		"do_action":
			# NPC 动作动画是模拟：非 host 不跑、不 ack（位置复制不含动作，属可接受的表现降级）。
			if _skip_npc_sim(actor_id):
				return
			_host.stage_action(actor_id, String(args.get("action", "wave")), _done(cmd_id))
		"prompt":
			# 尾声复述等：交给宿主开麦，让小朋友说一段（讲给外婆听）。说完/超时/离线跳过后由宿主
			# 带 { text } 回 done → ack（完成型，宿主收尾前不回执，脚本停在 await 处等孩子说）。
			_host.stage_prompt(actor_id, String(args.get("hint", "")), _done(cmd_id))
		"follow":
			# 设置型：即刻 ack 保持脚本不卡；非 host 不真跑跟随（NPC 位置由 host 复制）。
			if not _skip_npc_sim(actor_id):
				_host.stage_follow(actor_id, String(args.get("target", "")))
			_ack(cmd_id)
		"flee":
			if not _skip_npc_sim(actor_id):
				_host.stage_flee(actor_id, String(args.get("target", "")))
			_ack(cmd_id)
		"stop":
			if not _skip_npc_sim(actor_id):
				_host.stage_stop(actor_id)
			_ack(cmd_id)
		"banner":
			_host.stage_banner(String(args.get("text", "")))
			_ack(cmd_id)
		"hud_score":
			_host.stage_hud_score(String(args.get("id", "")), String(args.get("label", "")))
			_ack(cmd_id)
		"hud_score_add":
			_host.stage_hud_score_add(String(args.get("id", "")), int(args.get("n", 1)))
			_ack(cmd_id)
		"hud_countdown":
			_host.stage_hud_countdown(String(args.get("id", "")), int(args.get("sec", 0)), \
				int(args.get("serverStartMs", 0)), _server_offset_ms)
			_ack(cmd_id)
		"hud_cancel":
			_host.stage_hud_cancel(String(args.get("id", "")))
			_ack(cmd_id)
		"hud_toast":
			_host.stage_hud_toast(String(args.get("text", "")))
			_ack(cmd_id)
		"camera":
			# 运镜是纯表现：全端都跑（非 host 也得看戏），发出即回执，不卡脚本。
			# focus 带 args.actorId；dialog 带 args.a / args.b；overview / reset 不带演员。
			_host.stage_camera(
				String(args.get("mode", "")),
				String(args.get("actorId", args.get("a", ""))),
				String(args.get("b", "")))
			_ack(cmd_id)
		"prop_spawn":
			# 服务端造好 spec 下发落位（完成型）：host 落位后回 done → ack 带 prop id 回脚本。
			_host.stage_prop_spawn(String(args.get("id", "")), args.get("spec", {}), args.get("near"), _done(cmd_id))
		"prop_place":
			_host.stage_prop_place(String(args.get("id", "")), args.get("at"))
			_ack(cmd_id)
		"prop_remove":
			_host.stage_prop_remove(String(args.get("id", "")))
			_ack(cmd_id)
		"spawn_ball":
			# C 档球落位（完成型）：host 建球节点（默认所有者）后回 done → ack。球位置像角色一样
			# 进复制流，全端都渲染同一个球，故不走 _skip_npc_sim（同 prop_spawn，非 host 也建可见球）。
			# 踢球是客户端玩家动作、不在脚本；所有权转移/预测/和解见 P2c。
			_host.stage_spawn_ball(String(args.get("id", "")), args.get("at"), _done(cmd_id))
		"ball_reset":
			# 进球后复位（完成型）：host 把球移回落点、清零速度，落位后回 done → ack。
			_host.stage_ball_reset(String(args.get("id", "")), args.get("at"), _done(cmd_id))
		"watch":
			_on_watch(args)  # 布置规则探测器（无 ack，cmdId=-1）
		"unwatch":
			_subs.erase(String(args.get("subId", "")))  # 撤销订阅（无 ack）
		_:
			_ack(cmd_id, {}, "未知舞台命令: %s" % op)

## say：用角色自己的音色本地合成 TTS，说完 ack。玩家/无音色角色不合成、即刻 ack（其戏份走 prompt 开麦）。
func _dispatch_say(cmd_id: int, actor_id: String, args: Dictionary) -> void:
	var info: Dictionary = _actors.get(actor_id, {})
	var voice := String(info.get("voice_id", ""))
	var text := String(args.get("text", ""))
	if voice.is_empty():
		_ack(cmd_id)
		return
	_host.stage_say(actor_id, text, String(args.get("action", "")), voice, _done(cmd_id))

## 布置规则探测器：记下订阅（tap 本地点击探测 / timer 倒计时归零 / near 留 P6 服务端求值）。
func _on_watch(args: Dictionary) -> void:
	var sub_id := String(args.get("subId", ""))
	if sub_id.is_empty():
		return
	_subs[sub_id] = { "ev": String(args.get("ev", "")), "params": args.get("params", {}) }

## 多人所有权过滤：该命令针对的 NPC 本端是否「不模拟」。
## 非 host 端只渲染 host 复制来的 NPC 位置，不跑其走位/跟随/停/动作。
##   - is_host → 自己模拟 NPC，正常执行，不过滤；
##   - 玩家演员（is_player）→ 永远本端模拟（自己的输入零延迟），不算 NPC，不过滤；
##   - 未知 actor + 非 host → 保守视作 NPC 交给 host。
## 注：单机离线时不进演出（无 stage_cmd），此判定不触发，故不影响单机 NPC 自主行为。
func _skip_npc_sim(actor_id: String) -> bool:
	if _is_host or actor_id.is_empty():
		return false
	var info: Dictionary = _actors.get(actor_id, {})
	return not bool(info.get("is_player", false))

## 本地点击探测回传（world 在观演态点到某演员时调）：命中 tap 订阅则上行 tap 事件。
## 触屏一次点击会同时来 ScreenTouch + 仿真 MouseButton，按 TAP_DEBOUNCE_MS 去重只上行一次。
func on_local_tap(actor_id: String) -> void:
	if _stage_id.is_empty() or actor_id.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - int(_tap_seen.get(actor_id, -100000)) < TAP_DEBOUNCE_MS:
		return
	_tap_seen[actor_id] = now
	for sub_id in _subs:
		var s: Dictionary = _subs[sub_id]
		if String(s.get("ev", "")) == "tap" \
				and String((s.get("params", {}) as Dictionary).get("actorId", "")) == actor_id:
			_send.call("tap", -1, {}, "", sub_id, { "actorId": actor_id })

## 倒计时归零回传（world 的 HudFactory 归零时按 hud id 调）：命中 timer 订阅则上行 timer 事件。
func on_timer_done(hud_id: String) -> void:
	if _stage_id.is_empty() or hud_id.is_empty():
		return
	for sub_id in _subs:
		var s: Dictionary = _subs[sub_id]
		if String(s.get("ev", "")) == "timer" \
				and String((s.get("params", {}) as Dictionary).get("id", "")) == hud_id:
			_send.call("timer", -1, {}, "", sub_id, {})

## 生成「完成即回执」回调（携带 cmd_id 与当场 stage_id）：跨场后迟到的完成回调直接吞掉。
## host 约定始终以 (ok:bool, result:Dictionary) 两参调用；失败时 result 可携带 error 字段。
func _done(cmd_id: int) -> Callable:
	var stage := _stage_id
	return func(ok: bool, result: Dictionary) -> void:
		if _stage_id != stage:
			return
		if ok:
			_ack(cmd_id, result)
		else:
			_ack(cmd_id, {}, String(result.get("error", "命令执行失败")))

func _ack(cmd_id: int, result := {}, error := "") -> void:
	if cmd_id < 0 or _acked.has(cmd_id):
		return
	_acked[cmd_id] = true
	_send.call("ack", cmd_id, result, error)
