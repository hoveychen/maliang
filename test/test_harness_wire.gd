extends SceneTree
## 端侧语音 e2e 注入 harness P3：TCP 线路冒烟——真机联调前在本机(127.0.0.1)把
## socket 收发 + inject handshake + state 快照整条走通，de-risk 只能在设备上调的管线。
## 一个真 StreamPeerTCP 客户端连上 DebugCmdServer，逐条发命令、读回一行 JSON 应答并断言。
## 跨帧驱动（socket 握手/收发要几帧）：process_frame 步进 + MAX_FRAMES 兜底防挂。
## 运行(需帧): godot --headless --path . --fixed-fps 30 --quit-after 120 --script res://test/test_harness_wire.gd

class StubWorld extends Node:
	var _vc: VoiceCapture = null
	var _naming_item := ""
	var banner: Label = null
	var bag := {}
	var selected: Node = null

const MAX_FRAMES := 90

var _client: StreamPeerTCP = null
var _rx := ""
var _step := 0
var _frames := 0
var _fails := 0
var _done := false
var _sent := false  ## 本步命令是否已发出（发一次，等应答）

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ✓ %s" % name)
		return 0
	printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _initialize() -> void:
	var world := StubWorld.new()
	world.banner = Label.new()
	root.add_child(world)
	var vc := VoiceCapture.new()
	world._vc = vc
	world.add_child(vc)
	root.add_child(DebugCmdServer.make(world)) # _ready 里 listen(8577)；_process 自动每帧 poll
	# 连接推迟到首帧：server 的 listen 在其 _ready 里，_initialize 期间 add_child 的 _ready 尚未跑，
	# 此刻 connect 会撞「无人 listen」被拒。首帧时 server 已就绪。
	process_frame.connect(_tick)

## 发一行命令（附换行）。
func _send(obj: Dictionary) -> void:
	_client.put_data((JSON.stringify(obj) + "\n").to_utf8_buffer())

## 取一整行应答（不足一行返回 ""）。
func _recv_line() -> String:
	_client.poll()
	var avail := _client.get_available_bytes()
	if avail > 0:
		var chunk := _client.get_data(avail)
		if int(chunk[0]) == OK:
			var bytes: PackedByteArray = chunk[1]
			_rx += bytes.get_string_from_utf8()
	var nl := _rx.find("\n")
	if nl < 0:
		return ""
	var line := _rx.substr(0, nl)
	_rx = _rx.substr(nl + 1)
	return line

func _parse(line: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(line) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data

func _tick() -> void:
	if _done:
		return
	_frames += 1
	if _frames > MAX_FRAMES:
		printerr("  ✗ 超帧未完成（socket 挂了？step=%d）" % _step)
		_finish(1)
		return
	# 首帧起连；出错/断开则重连（server 首帧才 listen）。
	if _client == null:
		_client = StreamPeerTCP.new()
		var port := DebugCmdServer.PORT
		var env_port := OS.get_environment("MALIANG_HARNESS_PORT")
		if not env_port.is_empty() and env_port.is_valid_int():
			port = int(env_port) # 与 server 同一约定：8577 被 iproxy/adb forward 占走时回测换口
		_client.connect_to_host("127.0.0.1", port)
	_client.poll()
	var status := _client.get_status()
	if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		_client = null # 下一帧重连
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return # CONNECTING：等握手完成

	match _step:
		0: # say 未先 inject：_do_say 应自动补 inject，而非报「asr 不是 ScriptedAsr」（P1，say 自动 inject）
			if not _sent:
				_send({"op": "say", "text": "自动注入测试"}); _sent = true; return
			var line := _recv_line()
			if line.is_empty(): return
			print("[线路：say 未先 inject 自动补]")
			var r := _parse(line)
			# 关键：ok==true（不是 asr-不是-ScriptedAsr 的错误）证明 say 自动补了 inject。
			_fails += _check("say 未先 inject 也 ok", r.get("ok"), true)
			_advance()
		1: # inject handshake：换 ScriptedAsr（真机不推 user:// 标志的入口；此刻 say 已自动切过，幂等）
			if not _sent:
				_send({"op": "inject"}); _sent = true; return
			var line := _recv_line()
			if line.is_empty(): return
			print("[线路：inject handshake]")
			var r := _parse(line)
			_fails += _check("inject ok", r.get("ok"), true)
			_fails += _check("inject injected", r.get("injected"), true)
			_fails += _check("inject 后 ready", r.get("ready"), true)
			_advance()
		2: # state 快照往返
			if not _sent:
				_send({"op": "state"}); _sent = true; return
			var line := _recv_line()
			if line.is_empty(): return
			print("[线路：state 往返]")
			var r := _parse(line)
			_fails += _check("state ok", r.get("ok"), true)
			_fails += _check("state 带 vc_ready", r.get("vc_ready"), true)
			_advance()
		3: # 坏输入被拒（错误也回一行）
			if not _sent:
				_client.put_data("this is not json\n".to_utf8_buffer()); _sent = true; return
			var line := _recv_line()
			if line.is_empty(): return
			print("[线路：坏输入回错误]")
			var r := _parse(line)
			_fails += _check("坏输入 ok=false", r.get("ok"), false)
			_advance()
		_:
			if _fails == 0:
				print("test_harness_wire: 全部通过")
			else:
				printerr("test_harness_wire: %d 处失败" % _fails)
			_finish(_fails)

func _advance() -> void:
	_step += 1
	_sent = false
	_frames = 0 # 每步重置超帧预算

func _finish(code: int) -> void:
	_done = true
	if _client != null:
		_client.disconnect_from_host()
	quit(1 if code > 0 else 0)
