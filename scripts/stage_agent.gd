class_name StageAgent
extends RefCounted
## 舞台协议客户端大脑：把服务端下发的 stage_cmd 翻译成本地演出能力调用，完成后回 ack。
## 与具体演出实现解耦——host 是能力执行器（world.gd 实现；单测注入 mock），
## send_event 是上行通道 Callable(kind:String, cmd_id:int, result:Dictionary, error:String)。
## 设计文档: docs/script-runtime-design.md
##
## 完成语义（每条 cmd 恰好一个 ack）：
##   - 完成型 narrate/say/move_to/do_action：host 演完调 done 回调才 ack。
##   - 设置/占位型（P5 域：follow/flee/stop/banner/hud/prop/camera/prompt）：即刻 ack，脚本不卡。

var _host: Object
var _send: Callable
var _stage_id := ""           ## 当前演出 id（stage_begin 起，end/abort 清）
var _is_host := false         ## 多人所有权：本连接是否 host（P6 用于 NPC 命令过滤，P4 仅记录）
var _server_offset_ms := 0    ## 服务端时间偏移 serverMs - 本地钟（P6 倒计时/插值用）
var _actors := {}             ## actorId → { name, is_player, voice_id }
var _acked := {}              ## 本场已回执的 cmdId（防重复 ack）

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
			_host.stage_move(actor_id, args.get("target"), _done(cmd_id))
		"do_action":
			_host.stage_action(actor_id, String(args.get("action", "wave")), _done(cmd_id))
		"prompt":
			# P5 接开麦提词回填小朋友的话；P4 占位即刻 ack 空串，脚本不卡。
			_ack(cmd_id, { "text": "" })
		"follow", "flee", "stop", "banner", \
		"prop_create", "prop_place", "prop_remove", \
		"hud_score", "hud_score_add", "hud_countdown", "hud_cancel", "hud_toast", \
		"camera":
			# P5 域（设置型命令 / HUD / 道具 / 相机）：即刻 ack 占位，P5 接真实实现。
			_ack(cmd_id)
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
