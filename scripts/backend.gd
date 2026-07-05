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

@export var url := "ws://127.0.0.1:8080/ws"

var _ws := WebSocketPeer.new()
var _open := false

func connect_to_server() -> void:
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

func send_create_character(world_id: String, intent_text: String) -> void:
	_send({ "type": "create_character_request", "worldId": world_id, "intentText": intent_text, "byFairy": true })

## 上报世界地点名清单（POI 名，连上后一次）：意图 LLM 用来归一「去某地」的地名。
func send_world_info(world_id: String, locations: Array) -> void:
	_send({ "type": "world_info", "worldId": world_id, "locations": locations })

## 语音生成物件的落位回报：客户端就近找到空位后上报 tile，服务端持久化供重载恢复。
func send_prop_place(world_id: String, prop_id: String, tile: Vector2i) -> void:
	_send({ "type": "prop_place", "worldId": world_id, "propId": prop_id, "tileX": tile.x, "tileY": tile.y })

func _send(obj: Dictionary) -> void:
	if _open:
		_ws.send_text(JSON.stringify(obj))

func _process(_delta: float) -> void:
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
		"prop_created":
			prop_created.emit(data.get("prop", {}))
		"prop_failed":
			prop_failed.emit(String(data.get("reason", "")))
		"gen_failed", "voice_failed", "error":
			failed.emit(String(data.get("reason", data.get("error", ""))))
