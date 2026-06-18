class_name Backend
extends Node
## 后端 WS 客户端：连接 maliang-server，发造角色/语音请求，收进度/回应。

signal connected
signal character_response(data: Dictionary)
signal gen_progress(stage: String)
signal gen_complete(character: Dictionary)
signal failed(reason: String)

@export var url := "ws://127.0.0.1:8080/ws"

var _ws := WebSocketPeer.new()
var _open := false

func connect_to_server() -> void:
	_ws.connect_to_url(url)

func send_voice(world_id: String, character_id: String, audio_b64: String, fmt := "audio/wav") -> void:
	_send({ "type": "voice_input", "worldId": world_id, "characterId": character_id, "audio": audio_b64, "format": fmt })

func send_create_character(world_id: String, intent_text: String) -> void:
	_send({ "type": "create_character_request", "worldId": world_id, "intentText": intent_text, "byFairy": true })

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
		"gen_progress":
			gen_progress.emit(String(data.get("stage", "")))
		"gen_complete":
			gen_complete.emit(data.get("character", {}))
		"gen_failed", "voice_failed", "error":
			failed.emit(String(data.get("reason", data.get("error", ""))))
