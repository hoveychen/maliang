class_name Backend
extends Node
## 后端 WS 客户端：连接 maliang-server，发造角色/语音请求，收进度/回应。

signal connected
signal character_response(data: Dictionary)
signal tts_chunk(pcm: PackedByteArray)
signal tts_end
signal gen_progress(stage: String)
signal gen_complete(character: Dictionary)
signal prop_created(prop: Dictionary)
signal prop_failed(reason: String)
signal failed(reason: String)
# 奖赏系统：world_info 后的状态同步 / 委托完成发奖 / 转赠结果
signal world_state(data: Dictionary)
signal task_complete(data: Dictionary)
signal give_result(data: Dictionary)
signal praise_tts(asset: String)
## 出站消息观测（连接未开也发射）：headless 测试/调试用，正常逻辑不要依赖它
signal sent(msg: Dictionary)

@export var url := "ws://127.0.0.1:8080/ws"

var _ws := WebSocketPeer.new()
var _open := false
## 当前玩家 id（设备端稳定 UUID）：由 world.gd bootstrap 时从档案设入，_send 统一注入每条消息。
var player_id := ""

func connect_to_server() -> void:
	# 默认入站缓冲 64KB：慢帧场景（录屏/低端机）下一帧间隔内的 TTS 分片突发
	# 会撑爆缓冲直接断连，后续推送（如 prop_created）全部丢失——调大到 2MB。
	_ws.inbound_buffer_size = 2 * 1024 * 1024
	_ws.connect_to_url(url)

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

## 离开世界（玩家正常退出）：显式通知服务端收尾会话（Visit），触发批量抽记忆。
## 世界卸载后紧接着场景切换/节点释放，socket 可能来不及发——poll 一次尽量把帧推出；
## 万一没发到也不丢记忆，服务端 socket.close 会兜底 flush。
func send_leave_world(world_id: String) -> void:
	_send({ "type": "leave_world", "worldId": world_id })
	if _open:
		_ws.poll()

## 上报世界地点名清单（POI 名，连上后一次）：意图 LLM 用来归一「去某地」的地名。
## profile 非空时随 world_info 上报，供服务端首见建玩家档（面向 MMO；见 server types.Player）。
func send_world_info(world_id: String, locations: Array, profile := {}) -> void:
	var msg := { "type": "world_info", "worldId": world_id, "locations": locations }
	if not profile.is_empty():
		msg["profile"] = profile
	_send(msg)

## 委托完成事件（客户端确定性判定：送达/带到/到点）。服务端匹配进行中委托则回 task_complete。
func send_task_event(world_id: String, kind: String, extra := {}) -> void:
	var msg := { "type": "task_event", "worldId": world_id, "kind": kind }
	msg.merge(extra)
	_send(msg)

## 转赠贴纸给 NPC（走到对方旁交接后调用）。服务端扣背包+写受赠记忆，回 give_result。
func send_give_item(world_id: String, to_character_id: String, item_id: String) -> void:
	_send({ "type": "give_item", "worldId": world_id, "toCharacterId": to_character_id, "itemId": item_id })

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
			gen_complete.emit(data.get("character", {}))
		"world_state":
			world_state.emit(data)
		"task_complete":
			task_complete.emit(data)
		"give_result":
			give_result.emit(data)
		"praise_tts":
			praise_tts.emit(String(data.get("ttsAsset", "")))
		"prop_created":
			prop_created.emit(data.get("prop", {}))
		"prop_failed":
			prop_failed.emit(String(data.get("reason", "")))
		"gen_failed", "voice_failed", "error":
			failed.emit(String(data.get("reason", data.get("error", ""))))
