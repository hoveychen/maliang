class_name DebugCmdServer
extends Node
## debug-gated 本地 TCP 命令口（docs/voice-e2e-harness-design.md §4.3）：真机 e2e 的控制通道。
## 仅 OS.is_debug_build() 时由 world._ready add_child；release 一行不跑——绝不流到孩子手里。
##
## 用法：设备侧监听 127.0.0.1:PORT；测试机 `adb forward tcp:PORT tcp:PORT` 后连上，
## 逐行发 JSON 命令（一行一条），每条回一行 JSON 应答。命令集见 parse_command / 设计 §2.1：
##   {"op":"say","text":"爬爬梯"}   排下一句 ASR 文本 + 喂合成 PCM 驱 VAD 断句（=真人说一句）
##   {"op":"tap","x":..,"y":..}      盲坐标触屏
##   {"op":"state"}                  回状态快照（_naming_item/selected/banner/bag/vc 各态）
##   {"op":"screencap"}              截一帧落盘 user://harness_cap.png
##   {"op":"accept"/"replay"/"retry"} 确认模式三键（说完先回放、采纳/重听/重说）
##
## say 只把 PCM 喂进 _vc；到底录不录仍由真实 should_capture 门禁决定（§3.2，门禁本身是被测对象）。

const PORT := 8577                 ## 与 [vad] logcat / perf_sweep 同级的 debug-only 口子
const MIC_RATE := 16000            ## 合成 PCM 采样率（对齐 VoiceCapture.MIC_RATE / MicRecorder 出的 16k）

var _world: Node = null            ## 宿主 world（懒查 _vc / 状态字段，避开 _ready 里的建节点顺序）
var _server: TCPServer = null
var _peer: StreamPeerTCP = null    ## 单连接（e2e 脚本一次一个）
var _rx := ""                      ## 收流缓冲：攒到换行才算一条命令

static func make(world: Node) -> DebugCmdServer:
	var s := DebugCmdServer.new()
	s.name = "DebugCmdServer"
	s._world = world
	return s

# ── 纯函数：解析一行 → 结构化命令 / 错误（与 IO 分离，供 headless 单测）─────────────
## 返回 {ok=true, op, <args>} 或 {ok=false, error}。不触碰任何节点/IO。
static func parse_command(line: String) -> Dictionary:
	var stripped := line.strip_edges()
	if stripped.is_empty():
		return {"ok": false, "error": "empty"}
	var json := JSON.new()
	var perr := json.parse(stripped)
	if perr != OK:
		return {"ok": false, "error": "bad json: %s" % json.get_error_message()}
	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "not a json object"}
	var dict: Dictionary = data
	var op := String(dict.get("op", ""))
	if op.is_empty():
		return {"ok": false, "error": "missing op"}
	match op:
		"say":
			var text := String(dict.get("text", ""))
			if text.is_empty():
				return {"ok": false, "error": "say needs non-empty text"}
			return {"ok": true, "op": "say", "text": text}
		"tap":
			if not dict.has("x") or not dict.has("y"):
				return {"ok": false, "error": "tap needs x,y"}
			return {"ok": true, "op": "tap", "x": float(dict["x"]), "y": float(dict["y"])}
		"inject", "state", "screencap", "accept", "replay", "retry":
			return {"ok": true, "op": op}
		_:
			return {"ok": false, "error": "unknown op: %s" % op}

## 合成一段裸 PCM16（mono/16k）：交替正负半波近似 amp 的响度。ms 毫秒长、amp 归一化幅度。
## 与 test_scripted_asr._pcm 同款，供 say 喂 VAD 断句（静→响→静 复现「说一句」）。
static func synth_pcm(ms: int, amp: float) -> PackedByteArray:
	var samples := (MIC_RATE / 1000) * ms
	var buf := PackedByteArray()
	buf.resize(samples * 2)
	for i in samples:
		var v := int(amp * 32767.0) * (1 if (i / 8) % 2 == 0 else -1)
		buf.encode_s16(i * 2, v)
	return buf

# ── TCP 生命周期 ─────────────────────────────────────────────────────────────
func _ready() -> void:
	_server = TCPServer.new()
	var err := _server.listen(PORT, "127.0.0.1")
	if err != OK:
		push_warning("[harness] TCP 命令口监听失败(port=%d): %d" % [PORT, err])
		_server = null
		return
	print("[harness] debug 命令口就绪 127.0.0.1:%d（adb forward tcp:%d tcp:%d 后连）" % [PORT, PORT, PORT])

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _server != null:
		_server.stop()
		_server = null

func _process(_delta: float) -> void:
	if _server == null:
		return
	# 只保一个活连接：新连接进来时顶掉旧的（e2e 脚本一次一个客户端）。
	if _server.is_connection_available():
		if _peer != null:
			_peer.disconnect_from_host()
		_peer = _server.take_connection()
		_rx = ""
	if _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_peer = null
		return
	var avail := _peer.get_available_bytes()
	if avail > 0:
		var chunk := _peer.get_data(avail)
		if int(chunk[0]) == OK:
			var bytes: PackedByteArray = chunk[1]
			_rx += bytes.get_string_from_utf8()
	# 逐行取出完整命令执行。
	while true:
		var nl := _rx.find("\n")
		if nl < 0:
			break
		var line := _rx.substr(0, nl)
		_rx = _rx.substr(nl + 1)
		_handle_line(line)

func _handle_line(line: String) -> void:
	var cmd := parse_command(line)
	if not bool(cmd.get("ok", false)):
		_reply({"ok": false, "error": String(cmd.get("error", "?"))})
		return
	_reply(_execute(cmd))

func _reply(obj: Dictionary) -> void:
	if _peer == null:
		return
	_peer.put_data((JSON.stringify(obj) + "\n").to_utf8_buffer())

# ── 命令执行（IO：碰节点/树，不做解析）──────────────────────────────────────────
func _execute(cmd: Dictionary) -> Dictionary:
	var op := String(cmd["op"])
	match op:
		"inject":
			return _do_inject()
		"say":
			return _do_say(String(cmd["text"]))
		"tap":
			_do_tap(float(cmd["x"]), float(cmd["y"]))
			return {"ok": true, "op": "tap"}
		"state":
			return _snapshot()
		"screencap":
			return _do_screencap()
		"accept", "replay", "retry":
			return _do_confirm_key(op)
		_:
			return {"ok": false, "error": "unhandled op: %s" % op}

func _vc() -> VoiceCapture:
	if _world == null:
		return null
	return _world.get("_vc") as VoiceCapture

## inject：运行时把 _vc 的端侧 ASR 换成 ScriptedAsr（真机 handshake 入口——不依赖推 user:// 标志）。
## 换完 e2e 脚本才能用 say 排预排文本；未换时 say 会因 _asr 不认 enqueue 而报错。
func _do_inject() -> Dictionary:
	var vc := _vc()
	if vc == null:
		return {"ok": false, "error": "no VoiceCapture on world"}
	var s := vc.use_scripted_asr()
	if s == null:
		return {"ok": false, "error": "inject 失败（非 debug 构建？）"}
	return {"ok": true, "op": "inject", "injected": true, "ready": vc.is_ready()}

## say：排一句预排文本进 ScriptedAsr + 喂 静→响→静 合成 PCM 驱 VAD 断句。
## 到底录不录由真实门禁（is_open + should_capture）决定——门禁是被测对象，不绕过（§3.2）。
func _do_say(text: String) -> Dictionary:
	var vc := _vc()
	if vc == null:
		return {"ok": false, "error": "no VoiceCapture on world"}
	var asr: Object = vc._asr
	if asr == null or not asr.has_method("enqueue"):
		return {"ok": false, "error": "asr 不是 ScriptedAsr（harness 未注入？需 user://asr_harness 标志）"}
	asr.call("enqueue", text)
	# 门禁：没开聆听窗 / 门禁不放行 → 不喂（正确复现「没在听时说了没用」）。
	if not vc.is_open() or not bool(vc.should_capture.call()):
		return {"ok": true, "op": "say", "fed": false, "reason": "gate_closed",
			"pending": _asr_pending(asr)}
	# 一句：静音底噪 600ms → 说话 600ms → 静音 1200ms（>END_SILENCE_MS 断句）。
	for _i in 20: vc._feed(synth_pcm(30, 0.0))
	for _i in 20: vc._feed(synth_pcm(30, 0.3))
	for _i in 40: vc._feed(synth_pcm(30, 0.0))
	return {"ok": true, "op": "say", "fed": true, "pending": _asr_pending(asr)}

func _asr_pending(asr: Object) -> int:
	if asr != null and asr.has_method("pending"):
		return int(asr.call("pending"))
	return -1

## tap：合成一次按下+抬起触屏事件（emulate_mouse_from_touch 默认开，UI 按钮照样响应）。
func _do_tap(x: float, y: float) -> void:
	var pos := Vector2(x, y)
	var down := InputEventScreenTouch.new()
	down.index = 0
	down.position = pos
	down.pressed = true
	Input.parse_input_event(down)
	var up := InputEventScreenTouch.new()
	up.index = 0
	up.position = pos
	up.pressed = false
	Input.parse_input_event(up)

## state：一份可断言的状态快照。世界字段用 get() 读（避免对 Node 的 unsafe 属性访问告警）。
func _snapshot() -> Dictionary:
	var snap := {"ok": true, "op": "state"}
	if _world != null:
		snap["naming_item"] = String(_world.get("_naming_item") if _world.get("_naming_item") != null else "")
		var sel := _world.get("selected") as Node
		snap["selected"] = String(sel.get("char_name")) if sel != null else ""
		var banner := _world.get("banner") as Label
		snap["banner_text"] = banner.text if banner != null else ""
		snap["banner_visible"] = banner.visible if banner != null else false
		var bag: Variant = _world.get("bag")
		snap["bag_size"] = (bag as Dictionary).size() if typeof(bag) == TYPE_DICTIONARY else -1
	var vc := _vc()
	if vc != null:
		snap["vc_open"] = vc.is_open()
		snap["vc_recording"] = vc.is_recording()
		snap["vc_confirming"] = vc.is_confirming()
		snap["vc_ready"] = vc.is_ready()
		snap["asr_pending"] = _asr_pending(vc._asr)
	return snap

func _do_screencap() -> Dictionary:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return {"ok": false, "error": "no scene tree"}
	var img := tree.root.get_texture().get_image()
	if img == null:
		return {"ok": false, "error": "no viewport image"}
	var path := "user://harness_cap.png"
	var err := img.save_png(path)
	if err != OK:
		return {"ok": false, "error": "save_png failed: %d" % err}
	return {"ok": true, "op": "screencap", "path": ProjectSettings.globalize_path(path)}

func _do_confirm_key(op: String) -> Dictionary:
	var vc := _vc()
	if vc == null:
		return {"ok": false, "error": "no VoiceCapture on world"}
	match op:
		"accept": vc.accept()
		"replay": vc.replay()
		"retry": vc.retry()
	return {"ok": true, "op": op, "vc_confirming": vc.is_confirming()}
