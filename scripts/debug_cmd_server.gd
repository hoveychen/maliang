class_name DebugCmdServer
extends Node
## debug-gated 本地 TCP 命令口（docs/voice-e2e-harness-design.md §4.3）：真机 e2e 的控制通道。
## 仅 OS.is_debug_build() 时由 world._ready add_child；release 一行不跑——绝不流到孩子手里。
##
## 用法：设备侧监听 127.0.0.1:PORT；测试机 `adb forward tcp:PORT tcp:PORT` 后连上，
## 逐行发 JSON 命令（一行一条），每条回一行 JSON 应答。命令集见 parse_command / 设计 §2.1：
##   {"op":"say","text":"爬爬梯"}   排下一句 ASR 文本 + 喂合成 PCM 驱 VAD 断句（=真人说一句）
##   {"op":"tap","x":..,"y":..}      盲坐标触屏
##   {"op":"drag","x1":..,"y1":..,"x2":..,"y2":..,"ms":400}  跨帧拖动（swipe 同形，默认 250ms）
##   {"op":"long_press","x":..,"y":..,"ms":700}   按住不动再抬起（长按拾取 0.6s/按住跟随走路）
##   {"op":"pinch","x":..,"y":..,"scale":0.5,"ms":400,"dist":80}  双指捏合/张开（相机缩放）
##   {"op":"state"}                  回状态快照（fsm/玩家坐标/钱包/背包/手机/摆放/NPC/vc 各态）
##   {"op":"ui","texts":false}       可点/可读元素枚举（button/tap_area[/text] + 屏幕矩形 + viewport 标记）
##   {"op":"click_ui","text":"确认"}  语义点击（或 path=节点路径；Button 直发 pressed，SubViewport 内可达）
##   {"op":"phone","action":"open"}   手机便捷口：open/close/app（app 带 id，如 items/stickers/settings）
##   {"op":"screencap"}              截一帧落盘 user://harness_cap.png
##   {"op":"screencap","wire":true}  截图降采样 JPEG base64 直接回包（max_dim/quality 可选）
##   {"op":"accept"/"replay"/"retry"} 确认模式三键（说完先回放、采纳/重听/重说）
##
## say 只把 PCM 喂进 _vc；到底录不录仍由真实 should_capture 门禁决定（§3.2，门禁本身是被测对象）。

const PORT := 8577                 ## 与 [vad] logcat / perf_sweep 同级的 debug-only 口子
const MIC_RATE := 16000            ## 合成 PCM 采样率（对齐 VoiceCapture.MIC_RATE / MicRecorder 出的 16k）

var _world: Node = null            ## 宿主 world（懒查 _vc / 状态字段，避开 _ready 里的建节点顺序）
var _server: TCPServer = null
var _peer: StreamPeerTCP = null    ## 单连接（e2e 脚本一次一个）
var _rx := ""                      ## 收流缓冲：攒到换行才算一条命令

## 事件出口（可注入）：默认走引擎真输入管线（emulate_mouse_from_touch 让 UI 也响应）；
## headless 单测换成收集器，确定性断言事件序列（真机投递由 tap 先例背书）。
var event_sink: Callable = Callable(Input, "parse_input_event")

## 在飞手势（同一时刻至多一个）：{kind,t,ms,...}。手势跨帧发事件序列，完成时才回包——
## 期间新到的命令留在 _rx 不执行，天然形成顺序语义（驱动方一问一答不乱序）。
var _gesture: Dictionary = {}

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
		"drag", "swipe":
			# 跨帧手势：按下→逐帧插值 ScreenDrag→抬起（swipe=快版 drag，默认时长更短）。
			for k in ["x1", "y1", "x2", "y2"]:
				if not dict.has(k):
					return {"ok": false, "error": "%s needs x1,y1,x2,y2" % op}
			return {"ok": true, "op": op, "kind": "drag",
				"from": Vector2(float(dict["x1"]), float(dict["y1"])),
				"to": Vector2(float(dict["x2"]), float(dict["y2"])),
				"ms": clampi(int(dict.get("ms", 400 if op == "drag" else 250)), 16, 10000)}
		"long_press":
			# 按住不动 ms 毫秒再抬起（>0.6s 触发长按拾取；按住空地=跟随走路）。
			if not dict.has("x") or not dict.has("y"):
				return {"ok": false, "error": "long_press needs x,y"}
			return {"ok": true, "op": op, "kind": "long_press",
				"from": Vector2(float(dict["x"]), float(dict["y"])),
				"ms": clampi(int(dict.get("ms", 700)), 16, 10000)}
		"pinch":
			# 双指捏合：两指沿水平轴从间距 dist 收/张到 dist*scale（scale<1 捏、>1 张）。
			if not dict.has("x") or not dict.has("y"):
				return {"ok": false, "error": "pinch needs x,y"}
			var pscale := float(dict.get("scale", 0.5))
			if pscale <= 0.0:
				return {"ok": false, "error": "pinch scale must be > 0"}
			return {"ok": true, "op": op, "kind": "pinch",
				"center": Vector2(float(dict["x"]), float(dict["y"])),
				"scale": pscale, "dist": maxf(8.0, float(dict.get("dist", 80.0))),
				"ms": clampi(int(dict.get("ms", 400)), 16, 10000)}
		"pick":
			# 引导式造物点卡（按 optionId 应答一轮 creation_prompt/build_prompt）。
			var oid := String(dict.get("optionId", ""))
			if oid.is_empty():
				return {"ok": false, "error": "pick needs optionId"}
			return {"ok": true, "op": "pick", "optionId": oid}
		"pickup":
			if not dict.has("tileX") or not dict.has("tileY"):
				return {"ok": false, "error": "pickup needs tileX,tileY"}
			return {"ok": true, "op": "pickup", "tileX": int(dict["tileX"]),
				"tileY": int(dict["tileY"]), "edgeSide": int(dict.get("edgeSide", -1))}
		"photo":
			# 摄影模式（menu 相册拍摄）：hud 显隐 / pitch,yaw,dist,lift 摄影机位 / clear_cam 撤机位，均可选。
			var out := {"ok": true, "op": "photo"}
			if dict.has("hud"):
				out["hud"] = bool(dict["hud"])
			if dict.has("pitch") or dict.has("yaw") or dict.has("dist") or dict.has("lift"):
				out["cam"] = {"pitch": float(dict.get("pitch", 35.0)), "yaw": float(dict.get("yaw", 0.0)),
					"dist": float(dict.get("dist", 18.0)), "lift": float(dict.get("lift", 0.0))}
			if bool(dict.get("clear_cam", false)):
				out["clear_cam"] = true
			return out
		"scene":
			var sid := String(dict.get("id", ""))
			if sid.is_empty():
				return {"ok": false, "error": "scene needs id"}
			return {"ok": true, "op": "scene", "id": sid}
		"teleport":
			# 摄影找机位：tileX/tileY 目标格，或 near=true 传到第一个村民旁（二选一，near 优先）。
			var near := bool(dict.get("near", false))
			if not near and (not dict.has("tileX") or not dict.has("tileY")):
				return {"ok": false, "error": "teleport needs tileX,tileY or near"}
			return {"ok": true, "op": "teleport", "tileX": int(dict.get("tileX", -1)),
				"tileY": int(dict.get("tileY", -1)), "near": near}
		"ui":
			# UI 可点元素枚举（AI 感知）：texts=true 时连可见 Label 文本一起导出（读屏用）。
			return {"ok": true, "op": "ui", "texts": bool(dict.get("texts", false))}
		"click_ui":
			# 语义点击：按节点 path 或可见文字找控件（Button 直发 pressed；SubViewport 内也可达）。
			var cpath := String(dict.get("path", ""))
			var ctext := String(dict.get("text", ""))
			if cpath.is_empty() and ctext.is_empty():
				return {"ok": false, "error": "click_ui needs path or text"}
			return {"ok": true, "op": "click_ui", "path": cpath, "text": ctext}
		"phone":
			# 手机便捷口：open/close/app（手机屏在 SubViewport，盲坐标到不了）。
			var act := String(dict.get("action", ""))
			if not act in ["open", "close", "app"]:
				return {"ok": false, "error": "phone action must be open/close/app"}
			var aid := String(dict.get("id", ""))
			if act == "app" and aid.is_empty():
				return {"ok": false, "error": "phone app needs id"}
			return {"ok": true, "op": "phone", "action": act, "id": aid}
		"screencap":
			# wire=true 时截图降采样转 JPEG base64 直接回包（真机 user:// adb 拉不出来）。
			var scap := {"ok": true, "op": "screencap"}
			if dict.has("wire"):
				scap["wire"] = bool(dict["wire"])
			if dict.has("max_dim"):
				scap["max_dim"] = int(dict["max_dim"])
			if dict.has("quality"):
				scap["quality"] = float(dict["quality"])
			return scap
		"inject", "state", "accept", "replay", "retry", "talk_fairy", "talk_npc", "reset_budget":
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
	# app 级 autoload（[autoload] HarnessCmd）：从 App 启动就常驻、跨 menu/onboarding/world，好让 onboarding
	# 的语音流程也能 e2e。debug 门禁在此（原来在 world.gd add_child 处）：release 一行不跑、绝不开 TCP 口。
	if not OS.is_debug_build():
		set_process(false)
		return
	# 端口可被 MALIANG_HARNESS_PORT 覆盖：桌面拍摄/回归与真机调试并存时 8577 常被 iproxy/adb
	# forward 转发到真机占走（IPv6 通配监听会把 127.0.0.1 的连接也吃掉）——桌面驱动换口，
	# 避免命令赛跑打到别人的设备上（踩过：拍 menu 相册时 tap/screencap 打进了 iOS 诊断机）。
	var port := PORT
	var env_port := OS.get_environment("MALIANG_HARNESS_PORT")
	if not env_port.is_empty() and env_port.is_valid_int():
		port = int(env_port)
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_warning("[harness] TCP 命令口监听失败(port=%d): %d" % [port, err])
		_server = null
		return
	print("[harness] debug 命令口就绪 127.0.0.1:%d（adb forward tcp:%d tcp:%d 后连）" % [port, port, port])

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _server != null:
		_server.stop()
		_server = null

func _process(delta: float) -> void:
	# 手势推进放在最前：即便 TCP 口没起来（单测直接调 start_gesture）也要能走完。
	if not _gesture.is_empty():
		_step_gesture(delta)
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
	# 手势在飞：后续命令留在 _rx，做完（回包后）下一帧再执行——保证一问一答顺序。
	if not _gesture.is_empty():
		return
	# 逐行取出完整命令执行。
	while true:
		var nl := _rx.find("\n")
		if nl < 0:
			break
		var line := _rx.substr(0, nl)
		_rx = _rx.substr(nl + 1)
		_handle_line(line)
		if not _gesture.is_empty():
			break # 这条命令开了手势：停止取行，等它完成

func _handle_line(line: String) -> void:
	var cmd := parse_command(line)
	if not bool(cmd.get("ok", false)):
		_reply({"ok": false, "error": String(cmd.get("error", "?"))})
		return
	# 手势 op 异步：现在只发起，完成时（_step_gesture 收尾）才回包。
	if cmd.has("kind"):
		var err := start_gesture(cmd)
		if not err.is_empty():
			_reply({"ok": false, "error": err})
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
		"ui":
			return _do_ui(bool(cmd.get("texts", false)))
		"click_ui":
			return _do_click_ui(String(cmd["path"]), String(cmd["text"]))
		"phone":
			return _do_phone(String(cmd["action"]), String(cmd["id"]))
		"screencap":
			return _do_screencap(cmd)
		"accept", "replay", "retry":
			return _do_confirm_key(op)
		"talk_fairy":
			return _do_talk_fairy()
		"talk_npc":
			return _do_talk_npc()
		"pick":
			return _do_pick(String(cmd["optionId"]))
		"pickup":
			return _do_pickup(int(cmd["tileX"]), int(cmd["tileY"]), int(cmd["edgeSide"]))
		"reset_budget":
			return _do_reset_budget()
		"photo":
			return _do_photo(cmd)
		"scene":
			return _do_scene(String(cmd["id"]))
		"teleport":
			return _do_teleport(cmd)
		_:
			return {"ok": false, "error": "unhandled op: %s" % op}

## 当前活跃的 VoiceCapture（VoiceCapture.current，各 VC 的 _ready 置 / _exit 清）——app 级 harness 跨场景
## 定位它：onboarding 页用 onboarding 的 VC、world 用 world 的 _vc，谁在树上就打给谁，不再绑死 world。
func _vc() -> VoiceCapture:
	return VoiceCapture.current

## 当前宿主场景：app 级 autoload 由 Godot 默认构造，_world 恒为 null（make 才设）→ 回退到当前活跃场景。
## 在 world 时 current_scene 即 world 节点（带 harness_talk_fairy/harness_reset_play_budget 钩子）；
## 在 onboarding 时 current_scene 是 onboarding，没这些钩子——talk_fairy/reset_budget 会如实报错（本就不该在那触发）。
func _host() -> Node:
	return _world if _world != null else get_tree().current_scene

## inject：运行时把 _vc 的端侧 ASR 换成 ScriptedAsr（真机 handshake 入口——不依赖推 user:// 标志）。
## 换完 e2e 脚本才能用 say 排预排文本；未换时 say 会因 _asr 不认 enqueue 而报错。
func _do_inject() -> Dictionary:
	var vc := _vc()
	if vc == null:
		return {"ok": false, "error": "no active VoiceCapture (current)"}
	var s := vc.use_scripted_asr()
	if s == null:
		return {"ok": false, "error": "inject 失败（非 debug 构建？）"}
	return {"ok": true, "op": "inject", "injected": true, "ready": vc.is_ready()}

## say：排一句预排文本进 ScriptedAsr + 喂 静→响→静 合成 PCM 驱 VAD 断句。
## 到底录不录由真实门禁（is_open + should_capture）决定——门禁是被测对象，不绕过（§3.2）。
func _do_say(text: String) -> Dictionary:
	var vc := _vc()
	if vc == null:
		return {"ok": false, "error": "no active VoiceCapture (current)"}
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
	_send_touch(0, pos, true)
	_send_touch(0, pos, false)

# ── 跨帧手势（ai-harness P3）────────────────────────────────────────────────
func _send_touch(index: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = pressed
	event_sink.call(ev)

func _send_drag(index: int, pos: Vector2, last: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	ev.relative = pos - last
	event_sink.call(ev)

func gesture_active() -> bool:
	return not _gesture.is_empty()

## 发起手势：立即发按下事件，后续由 _step_gesture 逐帧推进。返回错误串（空=成功）。
func start_gesture(cmd: Dictionary) -> String:
	if not _gesture.is_empty():
		return "gesture already active"
	var kind := String(cmd.get("kind", ""))
	var g := {"kind": kind, "op": String(cmd.get("op", kind)), "t": 0.0, "ms": int(cmd.get("ms", 400))}
	match kind:
		"drag":
			g["from"] = cmd["from"] as Vector2
			g["to"] = cmd["to"] as Vector2
			g["last"] = cmd["from"] as Vector2
			_send_touch(0, g["from"], true)
		"long_press":
			g["from"] = cmd["from"] as Vector2
			_send_touch(0, g["from"], true)
		"pinch":
			g["center"] = cmd["center"] as Vector2
			g["d0"] = float(cmd["dist"])
			g["d1"] = float(cmd["dist"]) * float(cmd["scale"])
			var c: Vector2 = g["center"]
			var d: float = g["d0"]
			g["last0"] = c - Vector2(d, 0)
			g["last1"] = c + Vector2(d, 0)
			_send_touch(0, g["last0"], true)
			_send_touch(1, g["last1"], true)
		_:
			return "unknown gesture kind: %s" % kind
	_gesture = g
	return ""

## 逐帧推进在飞手势；到时发抬起并回包 {ok,op,done:true}。无手势时调用是 no-op。
func _step_gesture(delta: float) -> void:
	if _gesture.is_empty():
		return
	var g := _gesture
	g["t"] = float(g["t"]) + delta
	var k := clampf(float(g["t"]) * 1000.0 / float(g["ms"]), 0.0, 1.0)
	match String(g["kind"]):
		"drag":
			var pos := (g["from"] as Vector2).lerp(g["to"] as Vector2, k)
			_send_drag(0, pos, g["last"] as Vector2)
			g["last"] = pos
			if k >= 1.0:
				_send_touch(0, pos, false)
		"long_press":
			if k >= 1.0:
				_send_touch(0, g["from"] as Vector2, false)
		"pinch":
			var c: Vector2 = g["center"]
			var d: float = lerpf(float(g["d0"]), float(g["d1"]), k)
			var p0 := c - Vector2(d, 0)
			var p1 := c + Vector2(d, 0)
			_send_drag(0, p0, g["last0"] as Vector2)
			_send_drag(1, p1, g["last1"] as Vector2)
			g["last0"] = p0
			g["last1"] = p1
			if k >= 1.0:
				_send_touch(0, p0, false)
				_send_touch(1, p1, false)
	if k >= 1.0:
		_gesture = {}
		_reply({"ok": true, "op": String(g["op"]), "done": true, "ms": int(g["ms"])})

## state：一份可断言的状态快照。世界字段用 get() 读（避免对 Node 的 unsafe 属性访问告警）。
func _snapshot() -> Dictionary:
	var snap := {"ok": true, "op": "state"}
	# app 级：不在 world 时（如 onboarding）current_scene 没有这些字段，get() 返 null → best-effort 跳过。
	var w: Node = _host()
	if w != null:
		snap["naming_item"] = String(w.get("_naming_item") if w.get("_naming_item") != null else "")
		var sel := w.get("selected") as Node
		snap["selected"] = String(sel.get("char_name")) if sel != null else ""
		var banner := w.get("banner") as Label
		snap["banner_text"] = banner.text if banner != null else ""
		snap["banner_visible"] = banner.visible if banner != null else false
		var bag: Variant = w.get("bag")
		snap["bag_size"] = (bag as Dictionary).size() if typeof(bag) == TYPE_DICTIONARY else -1
		# 摄影驱动（menu 相册拍摄）轮询用：当前场景 + 是否在换场景过场中。
		var sid: Variant = w.get("_scene_id")
		snap["scene_id"] = String(sid) if sid != null else ""
		var trans: Variant = w.get("_transitioning")
		snap["transitioning"] = bool(trans) if trans != null else false
		# 探针：WS 是否连着（voice-e2e 查 name_creation 落库失败——疑因 _send 在 WS 断时静默丢弃）。
		var bk: Variant = w.get("backend")
		if bk != null and (bk as Object).has_method("is_online"):
			snap["ws_open"] = bool((bk as Object).call("is_online"))
		# 引路态（P3 验引路链）：_fairy_guide 非空 = guide_to 已下发并 start_guide 生效。
		var guide: Variant = w.get("_fairy_guide")
		snap["guide_active"] = typeof(guide) == TYPE_DICTIONARY and not (guide as Dictionary).is_empty()
		if snap["guide_active"]:
			var plan: Variant = (guide as Dictionary).get("plan")
			snap["guide_target"] = String((plan as Dictionary).get("targetName", "")) if typeof(plan) == TYPE_DICTIONARY else ""
		# 复用提示态（P3 验复用链）：_pending_reuse 挂起 = 服务端判出背包旧物能用上、已下发。
		var reuse: Variant = w.get("_pending_reuse")
		snap["pending_reuse"] = String((reuse as Dictionary).get("itemName", "")) if typeof(reuse) == TYPE_DICTIONARY else ""
		# 招呼态（P3 验招呼链）：最近一次「对方先开口」的招呼词（收到 character_response(greeting) 时记）。
		snap["last_greeting"] = String(w.get("_last_greeting") if w.get("_last_greeting") != null else "")
		# 引导式造物态（e2e 验造物链）：_in_creation 置位 = 服务端下发了 creation_prompt/build_prompt，
		# 正等孩子点卡或语音应答。harness 据 creation_options 决定点哪张卡（pick op），无卡则 say 开放答复。
		var in_creation: Variant = w.get("_in_creation")
		snap["in_creation"] = bool(in_creation) if in_creation != null else false
		if snap["in_creation"]:
			snap["creation_goal"] = String(w.get("_creation_goal") if w.get("_creation_goal") != null else "")
			snap["creation_category"] = String(w.get("_creation_category") if w.get("_creation_category") != null else "")
			var cq := w.get("_creation_q") as Label
			snap["creation_question"] = cq.text if cq != null else ""
			# 选项拍平成 [{id,label}]（去掉 iconAsset 等 harness 用不上的字段，回包精简）
			var opts: Variant = w.get("_creation_options")
			var out := []
			if typeof(opts) == TYPE_ARRAY:
				for o in (opts as Array):
					if typeof(o) == TYPE_DICTIONARY:
						out.append({"id": String((o as Dictionary).get("id", "")), "label": String((o as Dictionary).get("label", ""))})
			snap["creation_options"] = out
		# NPC 诊断（空村根因排查）：客户端 npcs 里到底有哪些角色——真村民 spawn 出来没有。
		var npcs: Variant = w.get("npcs")
		if typeof(npcs) == TYPE_ARRAY:
			snap["npc_count"] = (npcs as Array).size()
			var ids := PackedStringArray()
			var detail := []
			for n in (npcs as Array):
				var nd := n as Dictionary
				var tag := String(nd.get("id", "?"))
				if bool(nd.get("is_fairy", false)):
					tag += "(fairy)"
				var node: Variant = nd.get("node")
				if not is_instance_valid(node):
					tag += "(dead)"
				ids.append(tag)
				# AI 感知：结构化明细（含名字与 tile 位置，决策「去找谁」的空间基准）。
				var ent := {"id": String(nd.get("id", "?")), "fairy": bool(nd.get("is_fairy", false)),
					"dead": not is_instance_valid(node)}
				if is_instance_valid(node):
					var nm: Variant = (node as Object).get("char_name")
					ent["name"] = String(nm) if nm != null else ""
				var lg: Variant = nd.get("logical")
				if typeof(lg) == TYPE_VECTOR2:
					var nt := WorldGrid.to_tile(lg)
					ent["tile"] = {"x": nt.x, "y": nt.y}
				detail.append(ent)
			snap["npc_ids"] = ids
			snap["npcs"] = detail
		# ── AI 驱动感知扩展（ai-harness P1）────────────────────────────────────
		# 权威交互态：现在能不能说话/动看 fsm_state/mic_open，不再猜零散标志位。
		if w.has_method("_fsm_state"):
			var fs: int = int(w.call("_fsm_state"))
			snap["fsm_state"] = InteractionFsm.name_of(fs)
			snap["mic_open"] = InteractionFsm.mic_open(fs)
		# 玩家空间基准（逻辑坐标 + tile）：AI 决策移动/靠近全靠它。
		var player: Variant = w.get("player")
		if typeof(player) == TYPE_DICTIONARY and typeof((player as Dictionary).get("logical")) == TYPE_VECTOR2:
			var pl: Vector2 = (player as Dictionary)["logical"]
			snap["player_pos"] = {"x": pl.x, "y": pl.y}
			var pt := WorldGrid.to_tile(pl)
			snap["player_tile"] = {"x": pt.x, "y": pt.y}
		# 钱包 / 委托 / 背包明细（bag_size 保留兼容，明细供摆放/复用决策）。
		var wlt: Variant = w.get("wallet")
		if typeof(wlt) == TYPE_DICTIONARY:
			snap["wallet"] = wlt
		var task: Variant = w.get("active_task")
		if typeof(task) == TYPE_DICTIONARY and not (task as Dictionary).is_empty():
			snap["active_task"] = task
		if typeof(bag) == TYPE_DICTIONARY:
			snap["bag_items"] = bag
		# 手机态：开着没有、停在哪个 app（空=主屏）。
		var pcam: Variant = w.get("_phone_cam")
		snap["phone_open"] = bool(pcam) if pcam != null else false
		var pu: Variant = w.get("phone_ui")
		if pu != null and pu is Object and is_instance_valid(pu):
			var app: Variant = (pu as Object).get("_phone_open_app")
			snap["phone_app"] = String(app) if app != null else ""
		# 摆放模式：等落位确认时 AI 需知道幽灵在哪、合不合法。
		var placing: Variant = w.get("_placing")
		snap["placing"] = bool(placing) if placing != null else false
		if snap["placing"]:
			snap["place_item_id"] = String(w.get("_place_item_id") if w.get("_place_item_id") != null else "")
			snap["place_legal"] = bool(w.get("_place_legal")) if w.get("_place_legal") != null else false
			var ptile: Variant = w.get("_place_tile")
			if typeof(ptile) == TYPE_VECTOR2I:
				snap["place_tile"] = {"x": (ptile as Vector2i).x, "y": (ptile as Vector2i).y}
		# 输入被吞/被拦的门禁位：AI 发动作前先看这些，别对着遮罩空点。
		var blocked: Variant = w.get("_play_blocked")
		snap["play_blocked"] = bool(blocked) if blocked != null else false
		var stg: Variant = w.get("_stage_active")
		snap["stage_active"] = bool(stg) if stg != null else false
		var rfn: Variant = w.get("_refine_active")
		snap["refine_active"] = bool(rfn) if rfn != null else false
		var rmx: Variant = w.get("_remixing")
		snap["remixing"] = bool(rmx) if rmx != null else false
		# 会话标识 / 喊话对象。
		snap["world_id"] = String(w.get("world_id") if w.get("world_id") != null else "")
		snap["talk_pid"] = String(w.get("_talk_pid") if w.get("_talk_pid") != null else "")
	var vc := _vc()
	if vc != null:
		snap["vc_open"] = vc.is_open()
		snap["vc_recording"] = vc.is_recording()
		snap["vc_confirming"] = vc.is_confirming()
		snap["vc_ready"] = vc.is_ready()
		snap["asr_pending"] = _asr_pending(vc._asr)
	return snap

func _do_screencap(cmd: Dictionary) -> Dictionary:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return {"ok": false, "error": "no scene tree"}
	var img := tree.root.get_texture().get_image()
	if img == null:
		return {"ok": false, "error": "no viewport image"}
	# wire 回传（AI 感知主路）：真机 user:// 是 app 私有目录 adb 拉不出来，图必须走 TCP 回包。
	if bool(cmd.get("wire", false)):
		var enc := encode_jpg_b64(img, int(cmd.get("max_dim", 960)), float(cmd.get("quality", 0.75)))
		if not bool(enc.get("ok", false)):
			return enc
		enc["op"] = "screencap"
		return enc
	var path := "user://harness_cap.png"
	var err := img.save_png(path)
	if err != OK:
		return {"ok": false, "error": "save_png failed: %d" % err}
	return {"ok": true, "op": "screencap", "path": ProjectSettings.globalize_path(path)}

## 纯函数：Image → 降采样 JPEG base64（长边收到 max_dim，质量 quality）。供 headless 单测。
static func encode_jpg_b64(img: Image, max_dim: int, quality: float) -> Dictionary:
	var work := img.duplicate() as Image
	if work.is_compressed():
		work.decompress()
	work.convert(Image.FORMAT_RGB8)
	var longest := maxi(work.get_width(), work.get_height())
	if max_dim > 0 and longest > max_dim:
		var k := float(max_dim) / float(longest)
		work.resize(maxi(1, int(work.get_width() * k)), maxi(1, int(work.get_height() * k)),
			Image.INTERPOLATE_LANCZOS)
	var buf := work.save_jpg_to_buffer(clampf(quality, 0.1, 1.0))
	if buf.is_empty():
		return {"ok": false, "error": "jpg encode failed"}
	return {"ok": true, "w": work.get_width(), "h": work.get_height(),
		"jpg_b64": Marshalls.raw_to_base64(buf)}

## ui：可点/可读元素枚举（AI 感知）——遍历整棵树收可见 Control：
##   button   BaseButton 族（text/disabled/屏幕矩形）
##   tap_area gui_input 有连接或脚本重写 _gui_input 的 Control（menu 全屏进入/手机遮罩/集章卡这类自绘点击区）
##   text     texts=true 时附带非空 Label（读屏：menu/onboarding 页面文字）
## viewport 字段标记元素住在哪个视口："root" 直接盲坐标 tap 可达；SubViewport 名（如手机屏）
## 则坐标系不通——驱动方须走语义点击（click_ui，P4）。
func _do_ui(with_texts: bool) -> Dictionary:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return {"ok": false, "error": "no scene tree"}
	var out := []
	_collect_ui(tree.root, "root", with_texts, out)
	return {"ok": true, "op": "ui", "elements": out}

func _collect_ui(node: Node, viewport: String, with_texts: bool, out: Array) -> void:
	var vp := viewport
	if node is SubViewport:
		vp = String(node.name)
	if node is Control:
		var entry := describe_control(node as Control, vp, with_texts)
		if not entry.is_empty():
			out.append(entry)
	for child in node.get_children():
		_collect_ui(child, vp, with_texts, out)

## 纯判定：单个 Control → 元素描述（不感兴趣返回空 dict）。供 headless 单测。
static func describe_control(c: Control, vp: String, with_texts: bool) -> Dictionary:
	if not c.is_visible_in_tree():
		return {}
	var kind := ""
	if c is BaseButton:
		kind = "button"
	elif c.gui_input.get_connections().size() > 0 or _script_overrides(c, "_gui_input"):
		kind = "tap_area"
	elif with_texts and c is Label and not (c as Label).text.strip_edges().is_empty():
		kind = "text"
	if kind.is_empty():
		return {}
	var r := c.get_global_rect()
	var entry := {"kind": kind, "class": c.get_class(), "path": String(c.get_path()),
		"viewport": vp,
		"rect": {"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y}}
	var label := ""
	if c is Button:
		label = (c as Button).text
	elif c is Label:
		label = (c as Label).text
	if label.is_empty():
		label = c.tooltip_text
	if label.is_empty():
		label = String(c.name)
	entry["text"] = label
	if c is BaseButton:
		entry["disabled"] = (c as BaseButton).disabled
	return entry

## click_ui：语义点击。BaseButton 直发 pressed 信号（本仓 UI 全是代码连 pressed 的按钮，语义等价、
## 且 SubViewport 内也可达）；根视口的自绘点击区按矩形中心走真触屏 tap；SubViewport 内的自绘
## 点击区喂本地坐标鼠标事件（脚本重写 _gui_input 的直调、信号连接的走 gui_input.emit）。
## 按 text 找时先精确匹配、无则子串匹配，多命中取第一个并在回包报 matches 数。
func _do_click_ui(path: String, text: String) -> Dictionary:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return {"ok": false, "error": "no scene tree"}
	var target: Control = null
	var matches := 1
	if not path.is_empty():
		target = tree.root.get_node_or_null(NodePath(path)) as Control
		if target == null:
			return {"ok": false, "error": "no control at path: %s" % path}
	else:
		var els := []
		_collect_ui(tree.root, "root", false, els)
		var exact := []
		var fuzzy := []
		for e in els:
			var t := String((e as Dictionary).get("text", ""))
			if t == text:
				exact.append(e)
			elif t.contains(text):
				fuzzy.append(e)
		var hits: Array = exact if not exact.is_empty() else fuzzy
		if hits.is_empty():
			return {"ok": false, "error": "no clickable with text: %s" % text}
		matches = hits.size()
		target = tree.root.get_node_or_null(
			NodePath(String((hits[0] as Dictionary)["path"]))) as Control
		if target == null:
			return {"ok": false, "error": "matched node vanished"}
	if not target.is_visible_in_tree():
		return {"ok": false, "error": "control not visible: %s" % String(target.get_path())}
	var res := {"ok": true, "op": "click_ui", "clicked": String(target.get_path()), "matches": matches}
	if target is BaseButton:
		var b := target as BaseButton
		if b.disabled:
			return {"ok": false, "error": "button disabled: %s" % String(target.get_path())}
		b.pressed.emit()
		res["method"] = "signal"
		return res
	if target.get_viewport() == tree.root:
		var c := target.get_global_rect().get_center()
		_do_tap(c.x, c.y)
		res["method"] = "tap"
		return res
	# SubViewport 内自绘点击区：真 tap 到不了，喂本地坐标鼠标按下+抬起。
	var center := target.size * 0.5
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = center
		ev.global_position = center
		if _script_overrides(target, "_gui_input"):
			target.call("_gui_input", ev)
		else:
			target.gui_input.emit(ev)
	res["method"] = "gui_input"
	return res

## phone：手机开/关/开 app——透传宿主 harness_phone（world 才有；别处如实报错）。
func _do_phone(action: String, app_id: String) -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_phone"):
		return {"ok": false, "error": "world 无 harness_phone"}
	var okp := bool(w.call("harness_phone", action, app_id))
	return {"ok": okp, "op": "phone", "action": action, "id": app_id}

## 脚本（含基类链）是否重写了某方法——识别自绘点击区（重写 _gui_input 的 Control）。
static func _script_overrides(o: Object, method: String) -> bool:
	var s: Script = o.get_script()
	while s != null:
		for md in s.get_script_method_list():
			if String((md as Dictionary).get("name", "")) == method:
				return true
		s = s.get_base_script()
	return false

## photo：摄影模式（menu 相册拍摄）——HUD 显隐 + 摄影机位覆盖，透传 world.harness_photo。
func _do_photo(cmd: Dictionary) -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_photo"):
		return {"ok": false, "error": "world 无 harness_photo"}
	var args := {}
	if cmd.has("hud"):
		args["hud"] = cmd["hud"]
	if cmd.has("cam"):
		args["cam"] = cmd["cam"]
	if bool(cmd.get("clear_cam", false)):
		args["clear_cam"] = true
	var st: Dictionary = w.call("harness_photo", args)
	var out := {"ok": true, "op": "photo"}
	out.merge(st)
	return out

## teleport：摄影找机位——玩家就地搬到目标 tile / 第一个村民旁（world.harness_teleport）。
func _do_teleport(cmd: Dictionary) -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_teleport"):
		return {"ok": false, "error": "world 无 harness_teleport"}
	var ok := bool(w.call("harness_teleport",
		Vector2i(int(cmd["tileX"]), int(cmd["tileY"])), bool(cmd["near"])))
	return {"ok": ok, "op": "teleport"}

## scene：摄影切场景（走正常黑幕过场），脚本随后轮询 state.scene_id / transitioning 等落地。
func _do_scene(sid: String) -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_enter_scene"):
		return {"ok": false, "error": "world 无 harness_enter_scene"}
	var ok := bool(w.call("harness_enter_scene", sid))
	return {"ok": ok, "op": "scene", "id": sid}

## talk_fairy：不靠屏幕坐标直接进与小仙子「点点」的对话（走宿主已验证的 _approach_npc 路径）。
## 坐标盲点不可靠——tap 没命中玩家会被当点地面把玩家支使走，越走越偏；这条命令直接从 npcs 找仙子发起
## 靠近+进对话，e2e 脚本随后轮询 vc_open 即可。返回 entered=是否找到仙子并发起（对话开在几帧后）。
func _do_talk_fairy() -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_talk_fairy"):
		return {"ok": false, "error": "world 无 harness_talk_fairy"}
	var ok := bool(w.call("harness_talk_fairy"))
	return {"ok": ok, "op": "talk_fairy", "entered": ok}

## talk_npc：进与第一个真实非仙子村民的对话（走宿主 harness_talk_npc），验 NPC 招呼链。
func _do_talk_npc() -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_talk_npc"):
		return {"ok": false, "error": "world 无 harness_talk_npc"}
	var ok := bool(w.call("harness_talk_npc"))
	return {"ok": ok, "op": "talk_npc", "entered": ok}

## pickup：拾起 tile 上一件物品进背包（走宿主 harness_pickup → 服务端 item_pickup），验复用提示需背包旧物。
## pick：引导式造物按 optionId 点卡（走宿主 harness_pick_option → _on_creation_card → send_creation_reply）。
## 仅引导会话中生效；不在引导（harness_pick_option 返 false）时 picked=false，harness 据此改走 say 开放答复。
func _do_pick(option_id: String) -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_pick_option"):
		return {"ok": false, "error": "world 无 harness_pick_option"}
	var ok := bool(w.call("harness_pick_option", option_id))
	return {"ok": ok, "op": "pick", "picked": ok}

func _do_pickup(tile_x: int, tile_y: int, edge_side: int) -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_pickup"):
		return {"ok": false, "error": "world 无 harness_pickup"}
	var ok := bool(w.call("harness_pickup", tile_x, tile_y, edge_side))
	return {"ok": ok, "op": "pickup", "sent": ok}

## reset_budget：清掉游玩时长冷却门（45min 玩满 → 10min 冷却模态挡住造物/交互），供 e2e 连测不被拦。
## 仅重置本地预算+落盘，不碰服务端；debug 构建专用，绝不进 release。
func _do_reset_budget() -> Dictionary:
	var w := _host()
	if w == null or not w.has_method("harness_reset_play_budget"):
		return {"ok": false, "error": "world 无 harness_reset_play_budget"}
	w.call("harness_reset_play_budget")
	return {"ok": true, "op": "reset_budget"}

func _do_confirm_key(op: String) -> Dictionary:
	var vc := _vc()
	if vc == null:
		return {"ok": false, "error": "no active VoiceCapture (current)"}
	match op:
		"accept": vc.accept()
		"replay": vc.replay()
		"retry": vc.retry()
	return {"ok": true, "op": op, "vc_confirming": vc.is_confirming()}
