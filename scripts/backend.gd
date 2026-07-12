class_name Backend
extends Node
## 后端 WS 客户端：连接 maliang-server，发造角色/语音请求，收进度/回应。

signal connected
## 连接断开（曾 open 后转 closed）：供手机状态栏改信号格、也标记进入重连退避
signal disconnected
signal character_response(data: Dictionary)
signal tts_chunk(pcm: PackedByteArray)
signal tts_end
signal gen_progress(stage: String)
signal gen_complete(data: Dictionary)      ## 含 character + 最新 wallet
signal gen_denied(data: Dictionary)        ## 小红花不足，未进造角色（reason=no_flowers + 引导语 + wallet）
## 引导式造角色：小仙子追问一轮（含图标选项 + 仙子问句 TTS 资源 + goal 决定占位符）
signal creation_prompt(data: Dictionary)
## 引导会话被取消（小朋友说「算了/不要了」，服务端 guide 判的）：收创造视图 + 收占位符 + 念安抚语
signal creation_cancelled(data: Dictionary)
signal prop_pending(data: Dictionary)      ## 造物开工（已扣花）：客户端立起魔法熔炉，含最新 wallet
signal item_created(data: Dictionary)      ## 造物落成：{ item(实体行), wallet, bag }（万物皆物品）
signal prop_denied(data: Dictionary)       ## 小红花不足，未造物（reason=no_flowers + 引导语 + wallet）
signal prop_failed(reason: String)
signal bag_update(data: Dictionary)        ## 背包变化（摆放/拾起后）：{ worldId, bag }
signal sticker_bought(data: Dictionary)    ## 贴纸小铺购入：{ worldId, itemId, bag, wallet }
signal sticker_denied(data: Dictionary)    ## 小红花不足未买成：{ worldId, reason, wallet }
## 角色贴纸挂/摘（character-anchors §5）：{ worldId, sceneId, characterId, slot, itemId|null }。
## 场景定向广播，发起者也靠它落地渲染（与 terrain_patch 同哲学）。
signal character_attach(data: Dictionary)
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
## 在场玩家名单（进世界/换场景时一次性下发）：{ sceneId, actors:[{playerId,name,spriteAsset,tile?}] }。
## 位置流只在人动起来时才发，光靠它静止的玩家在本端根本不存在——presence 让进场即可见。
signal actors_snapshot(data: Dictionary)
## 某玩家进场：{ sceneId, actor:{playerId,name,spriteAsset,tile?} }。带 spriteAsset，据此渲染真实立绘。
signal actor_join(data: Dictionary)
## 别人造出了新伙伴：{ sceneId, character }。本端据此就地降生（否则要重进场景才看得到）。
signal character_spawned(data: Dictionary)
## 别的小朋友的表情动作：{ sceneId, fromPlayerId, targetPlayerId, action }（wave/jump/spin/nod/heart）。
signal player_emote(data: Dictionary)
## 别的小朋友的喊话（ASR 文本中继，见 docs/player-interaction-design.md）：
## { sceneId, fromPlayerId, targetPlayerId, text, lang, voiceId }。voiceId 服务端按发送者盖章，
## 本端据此 TTS 出声 + 头顶气泡；targetPlayerId==自己 ⇒ 对我说的（自动回礼判定用）。
signal player_speech(data: Dictionary)
## 收到爱心（别的小朋友送❤）：{ wallet }。爱心只增不减、不动小红花，集邮册展示。
signal hearts_update(data: Dictionary)
## 换场景（模型 B，走 portal）：收到目标场景的地形 + 角色 + items 实体 + pois + 该场景玩家最后位置。
## data = { worldId, sceneId, scene:Dictionary|null, characters:Array, items:Array, playerPos:Dictionary|null }
## （摆着的造物在场景矩阵物品层里，不再单发 props）
signal scene_entered(data: Dictionary)
## 地形矩阵增量更新（scene-items）：{ worldId, sceneId, version, paletteAppend?, items?, edits }。
## version 必须恰是本地 +1，否则全量重拉（world._on_terrain_patch）。
signal terrain_patch(data: Dictionary)
## 出站消息观测（连接未开也发射）：headless 测试/调试用，正常逻辑不要依赖它
signal sent(msg: Dictionary)

@export var url := "ws://127.0.0.1:8080/ws"

var _ws := WebSocketPeer.new()
var _open := false
## 当前玩家 id（设备端稳定 UUID）：由 world.gd bootstrap 时从档案设入，_send 统一注入每条消息。
var player_id := ""

## 自动重连（弱网/半开连接兜底）：connect_to_server 起意后，断线即指数退避重拨，
## 重连成功走 _open false→true 复用 connected 信号自动重握手（world.gd 已连好 _send_world_info+time_sync）。
const RECONNECT_BASE_S := 1.0   ## 首次退避
const RECONNECT_MAX_S := 15.0   ## 退避封顶
var _should_reconnect := false  ## 是否要维持连接（connect 起、disconnect_from_server 止）
var _reconnect_backoff := RECONNECT_BASE_S ## 当前退避时长（连上即重置为 base）
var _reconnect_wait := 0.0      ## 距下次重拨的倒计时

## 心跳（app 层 JSON ping/pong）：客户端定时发 ping，服务端回 pong。
## 任意回包都算「链路活着」；超时无任何回包即判半开连接，强制关连触发上面的自动重连。
const PING_INTERVAL_S := 10.0    ## 发 ping 间隔
const HEARTBEAT_TIMEOUT_S := 30.0 ## 无任何回包多久判死（三个 ping 周期）
var _ping_accum := 0.0          ## 距下次发 ping 的累计
var _since_rx := 0.0            ## 距上次收到任意回包的累计

## WS 是否已连上（供手机状态栏信号格显示网络是否通畅）。
func is_online() -> bool:
	return _open

func connect_to_server() -> void:
	_should_reconnect = true
	_reconnect_backoff = RECONNECT_BASE_S
	_reconnect_wait = 0.0
	_open_socket()

## 主动断开（离开世界/退出）：停掉自动重连，避免后台不停重拨。
func disconnect_from_server() -> void:
	_should_reconnect = false
	_ws.close()
	_open = false

func _open_socket() -> void:
	# CLOSED 的 WebSocketPeer 不复用（残留状态），每次重拨换新 peer。
	_ws = WebSocketPeer.new()
	# 默认入站缓冲 64KB：慢帧场景（录屏/低端机）下一帧间隔内的 TTS 分片突发
	# 会撑爆缓冲直接断连，后续推送（如 item_created）全部丢失——调大到 2MB。
	_ws.inbound_buffer_size = 2 * 1024 * 1024
	_ws.connect_to_url(full_url())

## 退避序列：翻倍封顶。抽成纯函数供单测。
func _next_backoff(cur: float) -> float:
	return minf(cur * 2.0, RECONNECT_MAX_S)

## 心跳步进（抽出供单测）：到点发 ping；有回包则复位活跃时钟，否则累计。
## 返回是否已超时（无任何回包超过 HEARTBEAT_TIMEOUT_S）——调用方据此强制关连。
func _step_heartbeat(delta: float, got_rx: bool) -> bool:
	_since_rx = 0.0 if got_rx else _since_rx + delta
	_ping_accum += delta
	if _ping_accum >= PING_INTERVAL_S:
		_ping_accum = 0.0
		_send({ "type": "ping" })
	return _since_rx > HEARTBEAT_TIMEOUT_S

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

## 玩家互动：对着别的小朋友做表情动作（喊话态表情盘，见 docs/player-interaction-design.md）。
## 服务端白名单校验后按同世界同场景定向转发（player_emote 下行），发送者不回环。
func send_player_emote(world_id: String, target_player_id: String, action: String) -> void:
	_send({ "type": "player_emote", "worldId": world_id, "targetPlayerId": target_player_id, "action": action })

## 玩家喊话（ASR 文本中继）：本端 ASR 出的文本发给同场景的人，对端用发送者音色 TTS 出声。
## lang 是跨语言翻译钩子（本期恒 zh，服务端透传）。
func send_player_speech(world_id: String, target_player_id: String, text: String, lang := "zh") -> void:
	_send({ "type": "player_speech", "worldId": world_id, "targetPlayerId": target_player_id, "text": text, "lang": lang })

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

## 走 portal 换场景（模型 B）：请求进入目标场景，服务端换 currentScene 并回 scene_entered
## （该场景的地形/角色/物件/pois + 玩家在该场景的最后位置）。触发点见 world.gd enter_scene。
func send_enter_scene(world_id: String, scene_id: String) -> void:
	_send({ "type": "enter_scene", "worldId": world_id, "sceneId": scene_id })

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

## 摆放：背包一份实体摆到指定 tile。服务端校验（占地/背包）→ tile 编辑 → terrain_patch 广播
## + bag_update 回包；失败回 error 不动账。渲染统一等广播回来落地（万物皆物品）。
## edge_side >= 0（0..3=N/E/S/W）= 贴纸挂 tile 边缘（docs/sticker-items-design.md §2.2）。
func send_item_place(world_id: String, item_id: String, tile: Vector2i, yaw_deg := 0.0, edge_side := -1) -> void:
	var msg := { "type": "item_place", "worldId": world_id, "itemId": item_id, "tileX": tile.x, "tileY": tile.y, "yawDeg": yaw_deg }
	if edge_side >= 0:
		msg["edgeSide"] = edge_side
	_send(msg)

## 拾起：tile 上的语音造物收进背包（内置树/石/建筑服务端拒拾；边缘贴纸例外可拾回）。
func send_item_pickup(world_id: String, tile: Vector2i, edge_side := -1) -> void:
	var msg := { "type": "item_pickup", "worldId": world_id, "tileX": tile.x, "tileY": tile.y }
	if edge_side >= 0:
		msg["edgeSide"] = edge_side
	_send(msg)

## 贴纸小铺：1 朵小红花买一张贴纸进背包（sticker_bought / sticker_denied 回包）。
func send_sticker_buy(world_id: String, item_id: String) -> void:
	_send({ "type": "sticker_buy", "worldId": world_id, "itemId": item_id })

## 角色贴纸挂/摘：item_id 空串 = 摘下该槽。贴上扣背包/摘下回背包，服务端权威。
func send_character_attach(world_id: String, character_id: String, slot: String, item_id: String) -> void:
	_send({ "type": "character_attach", "worldId": world_id, "characterId": character_id, "slot": slot, "itemId": item_id })

func _send(obj: Dictionary) -> void:
	# 统一注入玩家身份：每条出站消息带 playerId（设备端 UUID），服务端按玩家归属记忆/Visit。
	if not player_id.is_empty() and not obj.has("playerId"):
		obj["playerId"] = player_id
	sent.emit(obj)
	if _open:
		_ws.send_text(JSON.stringify(obj))

func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_poll_ws(delta)
	ProcProf.add("ws", Time.get_ticks_usec() - t0)

func _poll_ws(delta: float) -> void:
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _open:
			_open = true
			_reconnect_backoff = RECONNECT_BASE_S # 连上即重置退避，下次断线从 base 起
			_ping_accum = 0.0
			_since_rx = 0.0                       # 心跳时钟随新连接归零
			connected.emit()
		var got_rx := false
		while _ws.get_available_packet_count() > 0:
			got_rx = true
			var raw := _ws.get_packet().get_string_from_utf8()
			var data: Variant = JSON.parse_string(raw)
			if typeof(data) == TYPE_DICTIONARY:
				_dispatch(data)
		if _step_heartbeat(delta, got_rx):
			# 超时无回包：半开连接，强制关连；下一帧回落 CLOSED 触发自动重连。
			_ws.close()
	elif st == WebSocketPeer.STATE_CLOSED:
		if _open:
			_open = false
			_reconnect_wait = _reconnect_backoff # 从当前退避起算（刚断=base）
			disconnected.emit()
		_tick_reconnect(delta)

## 断线后的重拨节拍：倒计时到点换新 peer 重拨，并把退避翻倍备下次。
## CONNECTING 期间状态既非 OPEN 也非 CLOSED，本函数不被调用；只有回落 CLOSED 才继续倒计时。
func _tick_reconnect(delta: float) -> void:
	if not _should_reconnect:
		return
	_reconnect_wait -= delta
	if _reconnect_wait > 0.0:
		return
	_open_socket()
	_reconnect_backoff = _next_backoff(_reconnect_backoff)
	_reconnect_wait = _reconnect_backoff       # 本次若失败，下次按翻倍后的间隔再拨

func _dispatch(data: Dictionary) -> void:
	if OS.get_environment("MALIANG_WS_DEBUG") != "":
		print("[ws] ", String(data.get("type", "")))
	match String(data.get("type", "")):
		"pong":
			pass # 心跳回执：活跃时钟已在 _poll_ws 靠「收到任意回包」复位，无需额外处理
		"ping":
			_send({ "type": "pong" }) # 服务端反向探活时回执（当前服务端不发，留作对称兜底）
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
		"creation_cancelled":
			creation_cancelled.emit(data)
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
		"scene_entered":
			scene_entered.emit(data)
		"terrain_patch":
			terrain_patch.emit(data)
		"prop_pending":
			prop_pending.emit(data)
		"item_created":
			item_created.emit(data)
		"prop_denied":
			prop_denied.emit(data)
		"prop_failed":
			prop_failed.emit(String(data.get("reason", "")))
		"bag_update":
			bag_update.emit(data)
		"sticker_bought":
			sticker_bought.emit(data)
		"sticker_denied":
			sticker_denied.emit(data)
		"character_attach":
			character_attach.emit(data)
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
		"actors_snapshot":
			actors_snapshot.emit(data)
		"actor_join":
			actor_join.emit(data)
		"character_spawned":
			character_spawned.emit(data)
		"player_emote":
			player_emote.emit(data)
		"player_speech":
			player_speech.emit(data)
		"hearts_update":
			hearts_update.emit(data)
		"gen_failed", "voice_failed", "error":
			failed.emit(String(data.get("reason", data.get("error", ""))))
