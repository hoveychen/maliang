class_name Backend
extends Node
## 后端 WS 客户端：连接 maliang-server，发造角色/语音请求，收进度/回应。

signal connected
signal character_response(data: Dictionary)
signal tts_chunk(pcm: PackedByteArray)
signal tts_end
signal gen_progress(stage: String)
signal gen_complete(data: Dictionary)      ## 含 character + 最新 wallet
signal gen_denied(data: Dictionary)        ## 小红花不足，未进造角色（reason=no_flowers + 引导语 + wallet）
## 引导式造角色：小仙子追问一轮（含图标选项 + 仙子问句 TTS 资源）
signal creation_prompt(data: Dictionary)
signal prop_created(data: Dictionary)      ## 含 prop + 最新 wallet
signal prop_denied(data: Dictionary)       ## 小红花不足，未造物（reason=no_flowers + 引导语 + wallet）
signal prop_failed(reason: String)
signal failed(reason: String)
# 奖赏系统：world_info 后的状态同步 / 委托完成盖章升花
signal world_state(data: Dictionary)
signal task_complete(data: Dictionary)
signal praise_tts(data: Dictionary)
## tts_request 降级流（客户端 edge-tts 失败求服务端合成）：tts_start 带 mime，随后 tts_chunk/tts_end 同一通道
signal tts_start(mime: String)
signal tts_failed
## 舞台协议（剧本系统，见 docs/script-runtime-design.md）：下行由 StageAgent 消费，回执经 send_stage_event 上行
signal stage_begin(data: Dictionary)   ## 开演：{stageId, actors:[{id,name,isPlayer,voiceId}]}
signal stage_cmd(data: Dictionary)     ## 单条命令：{stageId, cmdId, actorId?, op, args}
signal stage_end(data: Dictionary)     ## 正常收场：{stageId, result?}
signal stage_abort(data: Dictionary)   ## 异常终止：{stageId, reason}
signal world_host(is_host: bool)       ## 多人所有权：本连接是否为 host（首位进入者，负责 NPC 模拟）
signal time_sync(data: Dictionary)     ## 时间握手回执：{t0, serverMs}（倒计时/插值时间戳用）
signal positions_relay(data: Dictionary) ## 其他端复制位置：{t, chars:[{id,x,y}], player?:{id,x,y}}（远端演员插值渲染）
signal actor_leave(player_id: String)  ## 某玩家离场：即时清掉其远端副本（不等插值缓冲陈旧）
## 出站消息观测（连接未开也发射）：headless 测试/调试用，正常逻辑不要依赖它
signal sent(msg: Dictionary)

@export var url := "ws://127.0.0.1:8080/ws"

var _ws := WebSocketPeer.new()
var _open := false
## 当前玩家 id（设备端稳定 UUID）：由 world.gd bootstrap 时从档案设入，_send 统一注入每条消息。
var player_id := ""

## WS 是否已连上（供手机状态栏信号格显示网络是否通畅）。
func is_online() -> bool:
	return _open

func connect_to_server() -> void:
	# 默认入站缓冲 64KB：慢帧场景（录屏/低端机）下一帧间隔内的 TTS 分片突发
	# 会撑爆缓冲直接断连，后续推送（如 prop_created）全部丢失——调大到 2MB。
	_ws.inbound_buffer_size = 2 * 1024 * 1024
	_ws.connect_to_url(full_url())

## 连接 URL 带 clientTts=1 能力声明：服务端全程跳过 TTS 合成只发文本+voiceId，
## 客户端 edge-tts 本地合成；edge 不通时逐句 send_tts_request 降级（服务端仍保留全套 TTS）。
func full_url() -> String:
	return url + ("&" if url.contains("?") else "?") + "clientTts=1"

func send_voice(world_id: String, character_id: String, audio_b64: String, fmt := "audio/wav") -> void:
	_send({ "type": "voice_input", "worldId": world_id, "characterId": character_id, "audio": audio_b64, "format": fmt })

## 边录边传：录音开始即开会话，录音中持续发分片，松手发 voice_end 收尾。
func send_voice_start(world_id: String, character_id: String) -> void:
	_send({ "type": "voice_start", "worldId": world_id, "characterId": character_id })

func send_voice_chunk(audio_b64: String) -> void:
	_send({ "type": "voice_chunk", "audio": audio_b64 })

func send_voice_end() -> void:
	_send({ "type": "voice_end" })

## 误触取消（按住说话太短就松手）：服务端丢弃本次会话，不回任何包。
func send_voice_cancel() -> void:
	_send({ "type": "voice_cancel" })

## 端侧 ASR：平板本地已识别，只上传文本（跳过服务端 ASR）。
func send_voice_transcript(world_id: String, character_id: String, transcript: String) -> void:
	_send({ "type": "voice_transcript", "worldId": world_id, "characterId": character_id, "transcript": transcript })

## 进对话对方先开口：服务端按角色招呼风格随机选一句、用其 voiceId 走流式 TTS，
## 回 character_response(+tts_chunk) 与普通回复同路。招呼失败服务端静默跳过，不打断进对话。
func send_greeting(world_id: String, character_id: String) -> void:
	_send({ "type": "voice_greeting", "worldId": world_id, "characterId": character_id })

func send_create_character(world_id: String, intent_text: String) -> void:
	_send({ "type": "create_character_request", "worldId": world_id, "intentText": intent_text, "byFairy": true })

## 引导式造角色答复：小朋友点了图标卡（option_id）就传 option_id；否则语音答复走 voice_transcript/voice_end。
func send_creation_reply(world_id: String, character_id: String, option_id: String) -> void:
	_send({ "type": "creation_reply", "worldId": world_id, "characterId": character_id, "optionId": option_id })

## 取消引导式造角色（退出与小仙子的交互）：服务端清掉会话，后续语音不再当造角色答复。
func send_creation_cancel() -> void:
	_send({ "type": "creation_cancel" })

## 离开世界（玩家正常退出）：显式通知服务端收尾会话（Visit），触发批量抽记忆。
## 世界卸载后紧接着场景切换/节点释放，socket 可能来不及发——poll 一次尽量把帧推出；
## 万一没发到也不丢记忆，服务端 socket.close 会兜底 flush。
func send_leave_world(world_id: String) -> void:
	_send({ "type": "leave_world", "worldId": world_id })
	if _open:
		_ws.poll()

## 上报世界地点名清单（POI 名，连上后一次）：意图 LLM 用来归一「去某地」的地名。
## profile 非空时随 world_info 上报，供服务端首见建玩家档（面向 MMO；见 server types.Player）。
## scene_id：玩家当前所在场景（模型 B）——服务端据此回读该场景的 playerPos，避免用错场景的坐标降生。
func send_world_info(world_id: String, locations: Array, profile := {}, scene_id := "village") -> void:
	var msg := { "type": "world_info", "worldId": world_id, "locations": locations, "sceneId": scene_id }
	if not profile.is_empty():
		msg["profile"] = profile
	_send(msg)

## edge-tts 本地合成失败的逐句降级：文本+voiceId 交服务端合成，回 tts_start(mime)+tts_chunk+tts_end。
func send_tts_request(text: String, voice_id: String) -> void:
	_send({ "type": "tts_request", "text": text, "voiceId": voice_id })

## 舞台协议上行：命令回执/规则触发/终止请求。
## kind='ack' 携带 cmdId(+可选 result/error) 关联下行命令；kind='abort' 请求终止本场演出；
## kind='tap'|'timer'|'near' 携带 subId(+可选 payload) 把规则触发注回服务端脚本订阅。
## worldId 服务端按连接归属，省略也可（server 回落连接所在世界）。
func send_stage_event(kind: String, cmd_id := -1, result := {}, error := "", sub_id := "", payload := {}) -> void:
	var msg := { "type": "stage_event", "kind": kind }
	if cmd_id >= 0:
		msg["cmdId"] = cmd_id
	if not result.is_empty():
		msg["result"] = result
	if not error.is_empty():
		msg["error"] = error
	if not sub_id.is_empty():
		msg["subId"] = sub_id
	if not payload.is_empty():
		msg["payload"] = payload
	_send(msg)

## 时间偏移握手：发本地毫秒钟 t0，服务端原样回带 + serverMs（见 time_sync 信号）。
func send_time_sync() -> void:
	_send({ "type": "time_sync", "t0": Time.get_ticks_msec() })

## 委托完成事件（客户端确定性判定：送达/带到/到点）。服务端匹配进行中委托则盖 1 章，回 task_complete。
func send_task_event(world_id: String, kind: String, extra := {}) -> void:
	var msg := { "type": "task_event", "worldId": world_id, "kind": kind }
	msg.merge(extra)
	_send(msg)

## 角色/玩家坐标回报：空间权威在客户端，服务端只记最后位置供下次进世界读回。
## chars 只带本轮 tile 变化过的角色（静止时整条消息不发）；player_tile 传 Vector2i(-1,-1) 表示不带玩家。
## scene_id 标明这批坐标属于哪个场景（模型 B）——服务端据此按场景存位置、给角色打场景标签。
## 服务端成功无回包，越界 tile 静默丢弃。
func send_positions(world_id: String, chars: Array, player_tile := Vector2i(-1, -1), scene_id := "village") -> void:
	var msg := { "type": "positions_report", "worldId": world_id, "chars": chars, "sceneId": scene_id }
	if player_tile.x >= 0:
		msg["player"] = { "tileX": player_tile.x, "tileY": player_tile.y }
	_send(msg)

## 高频世界坐标流（演出/多人期间）：owned actors 的实时世界坐标 + tile（tile 仍供服务端持久化）。
## chars 形如 [{id, x, y, tileX, tileY}]；player 形如 {x, y, tileX, tileY} 或空。
## t 为服务端钟毫秒（本地钟 + 时间偏移），接收端据此对齐插值时间戳。
## 服务端把带 x,y 的条目转发给同世界其他连接，并喂 near 规则求值。
func send_position_stream(world_id: String, chars: Array, player: Dictionary, t: int) -> void:
	var msg := { "type": "positions_report", "worldId": world_id, "chars": chars, "t": t }
	if not player.is_empty():
		msg["player"] = player
	_send(msg)

## 语音生成物件的落位回报：客户端就近找到空位后上报 tile，服务端持久化供重载恢复。
func send_prop_place(world_id: String, prop_id: String, tile: Vector2i) -> void:
	_send({ "type": "prop_place", "worldId": world_id, "propId": prop_id, "tileX": tile.x, "tileY": tile.y })

## 物品摆放/背包（占地校验在客户端 OccupancyMap，服务端只记状态机+持久化）。
func send_prop_store(world_id: String, prop_id: String) -> void:
	_send({ "type": "prop_store", "worldId": world_id, "propId": prop_id })

func send_prop_take(world_id: String, prop_id: String, tile: Vector2i) -> void:
	_send({ "type": "prop_take", "worldId": world_id, "propId": prop_id, "tileX": tile.x, "tileY": tile.y })

func send_prop_move(world_id: String, prop_id: String, tile: Vector2i) -> void:
	_send({ "type": "prop_move", "worldId": world_id, "propId": prop_id, "tileX": tile.x, "tileY": tile.y })

func _send(obj: Dictionary) -> void:
	# 统一注入玩家身份：每条出站消息带 playerId（设备端 UUID），服务端按玩家归属记忆/Visit。
	if not player_id.is_empty() and not obj.has("playerId"):
		obj["playerId"] = player_id
	sent.emit(obj)
	if _open:
		_ws.send_text(JSON.stringify(obj))

func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_poll_ws()
	ProcProf.add("ws", Time.get_ticks_usec() - t0)

func _poll_ws() -> void:
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _open:
			_open = true
			connected.emit()
		while _ws.get_available_packet_count() > 0:
			var raw := _ws.get_packet().get_string_from_utf8()
			var data: Variant = JSON.parse_string(raw)
			if typeof(data) == TYPE_DICTIONARY:
				_dispatch(data)
	elif st == WebSocketPeer.STATE_CLOSED:
		_open = false

func _dispatch(data: Dictionary) -> void:
	if OS.get_environment("MALIANG_WS_DEBUG") != "":
		print("[ws] ", String(data.get("type", "")))
	match String(data.get("type", "")):
		"character_response":
			character_response.emit(data)
		"tts_chunk":
			tts_chunk.emit(Marshalls.base64_to_raw(String(data.get("audio", ""))))
		"tts_end":
			tts_end.emit()
		"gen_progress":
			gen_progress.emit(String(data.get("stage", "")))
		"gen_complete":
			gen_complete.emit(data)
		"gen_denied":
			gen_denied.emit(data)
		"creation_prompt":
			creation_prompt.emit(data)
		"world_state":
			world_state.emit(data)
		"task_complete":
			task_complete.emit(data)
		"praise_tts":
			praise_tts.emit(data)
		"tts_start":
			tts_start.emit(String(data.get("ttsMime", "")))
		"tts_failed":
			tts_failed.emit()
		"prop_created":
			prop_created.emit(data)
		"prop_denied":
			prop_denied.emit(data)
		"prop_failed":
			prop_failed.emit(String(data.get("reason", "")))
		"stage_begin":
			stage_begin.emit(data)
		"stage_cmd":
			stage_cmd.emit(data)
		"stage_end":
			stage_end.emit(data)
		"stage_abort":
			stage_abort.emit(data)
		"world_host":
			world_host.emit(bool(data.get("isHost", false)))
		"time_sync":
			time_sync.emit(data)
		"positions_relay":
			positions_relay.emit(data)
		"actor_leave":
			actor_leave.emit(String(data.get("playerId", "")))
		"gen_failed", "voice_failed", "error":
			failed.emit(String(data.get("reason", data.get("error", ""))))
