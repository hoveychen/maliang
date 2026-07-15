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
		"inject", "state", "screencap", "accept", "replay", "retry", "talk_fairy", "talk_npc", "reset_budget":
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
			for n in (npcs as Array):
				var nd := n as Dictionary
				var tag := String(nd.get("id", "?"))
				if bool(nd.get("is_fairy", false)):
					tag += "(fairy)"
				var node: Variant = nd.get("node")
				if not is_instance_valid(node):
					tag += "(dead)"
				ids.append(tag)
			snap["npc_ids"] = ids
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
