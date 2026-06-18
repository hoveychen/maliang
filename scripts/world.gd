extends Node3D
## Demo 世界控制器（P5）。
## 浮动原点 + chunk streaming + world-bending + HD-2D 纸片角色 + 点击进交互模式。
## 逻辑/数据是纯平铺环面；弯曲只在渲染。角色精灵不走 shader，改用 CPU 复算
## 弯曲量、沿相机上方向落到弯曲地表（曲面世界放置物体的通用解法）。

const PAN_SPEED := 28.0           ## god 相机平移速度（世界单位/秒）
const GOD_PITCH_DEG := 47.0       ## 默认 god 视角：地平线落屏幕 ~4/5 高度（约 20% 天空）
const LOCK_PITCH_DEG := 30.0      ## lock 跟随：明显放平（3/4 平视，地平线 ~3/4、约 25% 天空）
const SPRITE_LEAN_FACTOR := 0.55  ## 角色固定倾角 = (90-相机角)*该系数（站立感+面向相机折中）
const GOD_DIST := 36.0
const LOCK_DIST := 20.0
const ZOOM_MIN := 16.0
const ZOOM_MAX := 64.0
const CAM_EASE := 6.0             ## 视角过渡速度（pitch/dist/focus 一起缓动）
const PICK_RADIUS_PX := 80.0
const THINK_TIMEOUT := 40.0       ## 「思考中」最长等待秒数；超时(响应丢失/网络/TLS)自动清除，杜绝永久卡死

var focus_logical := Vector2.ZERO ## god 相机在环面上聚焦的逻辑坐标（取代玩家）
var _cur_pitch := GOD_PITCH_DEG
var _cur_dist := GOD_DIST
var _target_pitch := GOD_PITCH_DEG
var _target_dist := GOD_DIST
var _locked: PaperCharacter = null ## lock 跟随的角色（null=god 自由模式）
var camera: Camera3D
var chunk_manager: ChunkManager
var coord_label: Label
var banner: Label
var heard_label: Label   ## 顶部显示 ASR 识别到的文字（"👂 听到：…"）

var critter_tex: Texture2D
var ear_tex: Texture2D
var npcs: Array = []              ## [{ node:PaperCharacter, logical:Vector2 }]
var selected: PaperCharacter = null
var ear_icon: Sprite3D
var _cam_up := Vector3.UP         ## 相机上方向（弯曲补偿用，随相机更新）
var _dragging := false
var _press_pos := Vector2.ZERO

# M2 语音交互
var backend: Backend
var listen_btn: Button
var send_btn: Button
var thinking_label: Label
var _think_timer: Timer            ## 「思考中」兜底超时（响应没回来时自动解卡）
var emotion_bubble: Label3D
var _recording := false
var _executors: Array = []        ## 活跃的 BehaviorExecutor
var world_id := ""

# M2-real 在线
var api: Api
var online := false
var _villager_count := 0          ## 村民散开序号（避免堆叠在中心）

# 音频 I/O（真机：麦克风采集 + TTS 播放）
var _mic_player: AudioStreamPlayer
var _tts_player: AudioStreamPlayer
var _capture: AudioEffectCapture
var _rec_rate := 44100
# 边录边传：录音时持续把采集到的 PCM 攒成小块发给后端（上传与说话重叠）
var _pending_pcm := PackedByteArray()
var _chunk_accum := 0.0   ## 距上次发分片的累计秒数
var _streamed_any := false

func _ready() -> void:
	critter_tex = load("res://assets/critter.svg")
	ear_tex = load("res://assets/ear.svg")
	_setup_environment()
	chunk_manager = ChunkManager.new()
	chunk_manager.name = "ChunkManager"
	add_child(chunk_manager)
	_setup_camera()
	_setup_npcs()
	_setup_ear()
	_setup_hud()
	_setup_backend()
	api = Api.new()
	api.name = "Api"
	add_child(api)
	_setup_audio()
	_bootstrap() # 在线引导（best-effort，离线则保留占位 NPC）

func _setup_audio() -> void:
	# 录音总线 + 采集效果（静音，不外放麦克风）
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "Record")
	AudioServer.set_bus_mute(idx, true)
	_capture = AudioEffectCapture.new()
	AudioServer.add_bus_effect(idx, _capture)
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = "Record"
	add_child(_mic_player)
	_rec_rate = int(AudioServer.get_mix_rate())
	_tts_player = AudioStreamPlayer.new()
	add_child(_tts_player)

func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-55.0, -40.0, 0.0)
	light.light_energy = 1.15
	light.shadow_enabled = false  # 弯曲后阴影投影会错位
	add_child(light)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.82, 0.97)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.78, 0.85)
	env.ambient_light_energy = 0.6
	# 深度雾：远处地面渐隐到天空色 → chunk 边界雾化进天空、自然无限地平线
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.62, 0.82, 0.97)
	env.fog_light_energy = 1.0
	env.fog_depth_begin = 40.0
	env.fog_depth_end = 95.0  ## 小世界(span 150)：~95 外渐隐进天空，藏住远端循环，保留无限地平线感
	env.fog_depth_curve = 1.0
	we.environment = env
	add_child(we)

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 50.0
	camera.far = 900.0
	add_child(camera)
	_update_camera()

## 相机固定在渲染原点上方、看向原点；平移靠改 focus_logical（世界相对滚动），
## 角度(pitch)/距离(dist) 由 god/lock 目标缓动得到。
func _update_camera() -> void:
	var pitch := deg_to_rad(_cur_pitch)
	camera.global_position = Vector3(0.0, sin(pitch) * _cur_dist, cos(pitch) * _cur_dist)
	camera.look_at(Vector3.ZERO, Vector3.UP)
	_cam_up = camera.global_transform.basis.y

func _setup_npcs() -> void:
	var defs := [
		{ "logical": Vector2(10.0, -10.0), "color": Color(0.62, 0.80, 1.0), "name": "小蓝" },
		{ "logical": Vector2(-11.0, -9.0), "color": Color(0.70, 1.0, 0.62), "name": "小绿" },
		{ "logical": Vector2(1.0, -18.0), "color": Color(1.0, 0.82, 0.5), "name": "小黄" },
	]
	for d in defs:
		var npc := PaperCharacter.new()
		add_child(npc)
		npc.setup(critter_tex, d["color"], d["name"])
		npcs.append({ "node": npc, "logical": d["logical"] })
		_start_ambient_wander(npcs[npcs.size() - 1])

## 让角色自主活动：循环「等一会 → 就近 wander」。
func _start_ambient_wander(npc_dict: Dictionary) -> void:
	var ex := BehaviorExecutor.new()
	ex.setup(npc_dict, {
		"commands": [
			{ "type": "wait", "params": { "duration": randf_range(1.0, 3.5) } },
			{ "type": "wander", "params": { "radius": 7.0 } },
		],
		"loop": true,
	})
	_executors.append(ex)

func _setup_ear() -> void:
	ear_icon = Sprite3D.new()
	ear_icon.texture = ear_tex
	ear_icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	ear_icon.pixel_size = 0.02
	ear_icon.shaded = false
	ear_icon.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	ear_icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	ear_icon.visible = false
	add_child(ear_icon)

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	coord_label = Label.new()
	coord_label.position = Vector2(16.0, 12.0)
	_style_label(coord_label, 22)
	layer.add_child(coord_label)

	banner = Label.new()
	banner.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	banner.offset_top = -96.0
	banner.offset_bottom = -36.0
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_label(banner, 28)
	banner.visible = false
	layer.add_child(banner)

	# 顶部「听到的文字」反馈：让大人能确认 ASR 是否识别成功
	heard_label = Label.new()
	heard_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	heard_label.offset_top = 36.0
	heard_label.offset_bottom = 96.0
	heard_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heard_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_label(heard_label, 24)
	heard_label.visible = false
	layer.add_child(heard_label)

	# 聆听 / 发送 按钮（交互模式下显示）
	listen_btn = Button.new()
	listen_btn.text = "🎤 聆听"
	listen_btn.add_theme_font_size_override("font_size", 30)
	listen_btn.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	listen_btn.offset_left = -210.0
	listen_btn.offset_right = -30.0
	listen_btn.offset_top = -150.0
	listen_btn.offset_bottom = -100.0
	listen_btn.visible = false
	listen_btn.pressed.connect(_on_listen)
	layer.add_child(listen_btn)

	send_btn = Button.new()
	send_btn.text = "✓ 发送"
	send_btn.add_theme_font_size_override("font_size", 30)
	send_btn.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	send_btn.offset_left = 30.0
	send_btn.offset_right = 210.0
	send_btn.offset_top = -150.0
	send_btn.offset_bottom = -100.0
	send_btn.visible = false
	send_btn.disabled = true
	send_btn.pressed.connect(_on_send)
	layer.add_child(send_btn)

	thinking_label = Label.new()
	thinking_label.set_anchors_preset(Control.PRESET_CENTER)
	_style_label(thinking_label, 30)
	thinking_label.text = "思考中…"
	thinking_label.visible = false
	layer.add_child(thinking_label)

	# 角色头顶情绪气泡（占位：真实游戏用图标）
	emotion_bubble = Label3D.new()
	emotion_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	emotion_bubble.pixel_size = 0.02
	emotion_bubble.modulate = Color.WHITE
	emotion_bubble.outline_size = 12
	emotion_bubble.font_size = 96
	emotion_bubble.visible = false
	add_child(emotion_bubble)

func _style_label(l: Label, size: int) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)

func _physics_process(delta: float) -> void:
	# 方向键平移 god 相机聚焦点（拖拽平移在 _unhandled_input）
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if input != Vector2.ZERO:
		focus_logical = WorldGrid.wrap_pos(focus_logical + input * PAN_SPEED * delta)

func _process(delta: float) -> void:
	_step_executors(delta)
	if _recording:
		_stream_recording(delta)
	# 视角缓动（god ↔ lock 的 pitch/dist 过渡）
	var t := minf(1.0, CAM_EASE * delta)
	_cur_pitch = lerpf(_cur_pitch, _target_pitch, t)
	_cur_dist = lerpf(_cur_dist, _target_dist, t)
	# lock 时聚焦缓动跟随选中角色（它可能在自主走动）
	if _locked != null and is_instance_valid(_locked):
		var lg: Vector2 = _find_npc_dict(_locked).get("logical", focus_logical)
		var fd := WorldGrid.shortest_delta(focus_logical, lg)
		focus_logical = WorldGrid.wrap_pos(focus_logical + fd * t)
	_update_camera()
	chunk_manager.update(focus_logical)
	_reposition_npcs()
	_update_ear()
	_update_emotion_bubble()
	_update_hud()

func _step_executors(delta: float) -> void:
	for ex in _executors:
		ex.step(delta)
	_executors = _executors.filter(func(e: BehaviorExecutor) -> bool: return not e.is_done())

func _reposition_npcs() -> void:
	# 固定小倾角：随当前相机角度调（站立感 + 面向相机的折中），绕脚底前倾
	var lean := deg_to_rad((90.0 - _cur_pitch) * SPRITE_LEAN_FACTOR)
	for n in npcs:
		var d: Vector2 = WorldGrid.shortest_delta(focus_logical, n["logical"])
		var node: Node3D = n["node"]
		_place_on_bent_ground(node, Vector3(d.x, 0.0, d.y))
		node.rotation = Vector3(-lean, 0.0, 0.0)

## 把节点放到「弯曲后」的地表位置：先算视图空间弯曲下沉量，再沿相机上方向补偿。
func _place_on_bent_ground(node: Node3D, base_world: Vector3) -> void:
	var vp := camera.global_transform.affine_inverse() * base_world
	var drop := BendMat.CURVATURE * (vp.x * vp.x + vp.z * vp.z)
	node.global_position = base_world - _cam_up * drop

func _update_ear() -> void:
	if selected != null and is_instance_valid(selected):
		ear_icon.visible = true
		ear_icon.global_position = selected.global_position + Vector3(0.0, 3.6, 0.0)
	else:
		ear_icon.visible = false

func _update_hud() -> void:
	var t := WorldGrid.to_tile(focus_logical)
	coord_label.text = "god 视角  tile (%d, %d)  /  %d×%d  环面循环" % [t.x, t.y, WorldGrid.GRID_TILES, WorldGrid.GRID_TILES]

func _unhandled_input(event: InputEvent) -> void:
	# 调试：选中角色后按 Enter/空格。小神仙→造角色；其他→本地 move_to（离线演示）。
	if event.is_action_pressed("ui_accept") and selected != null:
		var d := _find_npc_dict(selected)
		if d.get("is_fairy", false) and online:
			_request_create("一只戴帽子的小猫")
		else:
			_show_emotion("wave")
			_run_behavior(selected, { "commands": [{ "type": "move_to", "params": {} }], "loop": false })
		return
	# 缩放（滚轮）
	if event is InputEventMouseButton and event.pressed and _locked == null:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_dist = clampf(_target_dist - 3.0, ZOOM_MIN, ZOOM_MAX)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_dist = clampf(_target_dist + 3.0, ZOOM_MIN, ZOOM_MAX)
			return
	# 鼠标：按下记录，移动判定为拖拽平移，松开若未拖拽则拾取
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = false
			_press_pos = event.position
		elif not _dragging:
			_tap_pick(event.position)
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if event.position.distance_to(_press_pos) > 6.0:
			_dragging = true
		_pan_by_screen(event.relative)
		return
	# 触屏：拖动平移，点触拾取
	if event is InputEventScreenDrag:
		_dragging = true
		_pan_by_screen(event.relative)
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_dragging = false
			_press_pos = event.position
		elif not _dragging:
			_tap_pick(event.position)
		return

func _tap_pick(screen_pos: Vector2) -> void:
	var hit := _pick_npc(screen_pos)
	if hit != null:
		_enter_interaction(hit)
	else:
		_exit_interaction()

## 屏幕拖动 → 世界平移（抓住地图拖的手感；高角俯视下屏幕 x→世界x，y→世界z）
func _pan_by_screen(rel: Vector2) -> void:
	if _locked != null:
		return # lock 模式由跟随驱动，不手动平移
	var k := _cur_dist * 0.0016
	focus_logical = WorldGrid.wrap_pos(focus_logical - Vector2(rel.x, rel.y) * k)

## 屏幕空间拾取：精灵未弯曲，其屏幕位置 = unproject(实际渲染坐标)，与点击对比。
func _pick_npc(screen_pos: Vector2) -> PaperCharacter:
	var best: PaperCharacter = null
	var best_d := PICK_RADIUS_PX
	for n in npcs:
		var node: PaperCharacter = n["node"]
		var wp := node.global_position + Vector3(0.0, 1.6, 0.0)
		if camera.is_position_behind(wp):
			continue
		var sp := camera.unproject_position(wp)
		var dd := screen_pos.distance_to(sp)
		if dd < best_d:
			best_d = dd
			best = node
	return best

func _enter_interaction(npc: PaperCharacter) -> void:
	selected = npc
	# lock：相机平滑切到更低角(3/4)+拉近，聚焦跟随该角色
	_locked = npc
	_target_pitch = LOCK_PITCH_DEG
	_target_dist = LOCK_DIST
	banner.text = "%s 在听你说话呀" % npc.char_name
	banner.visible = true
	listen_btn.visible = true
	send_btn.visible = true
	send_btn.disabled = true
	thinking_label.visible = false

func _exit_interaction() -> void:
	selected = null
	# 切回 god 自由视角（平滑过渡）
	_locked = null
	_target_pitch = GOD_PITCH_DEG
	_target_dist = GOD_DIST
	banner.visible = false
	heard_label.visible = false
	listen_btn.visible = false
	send_btn.visible = false
	thinking_label.visible = false
	_recording = false

# ── M2 语音交互 ──────────────────────────────────────────────────────────

func _setup_backend() -> void:
	backend = Backend.new()
	backend.name = "Backend"
	add_child(backend)
	backend.character_response.connect(_on_character_response)
	backend.gen_progress.connect(_on_gen_progress)
	backend.gen_complete.connect(_on_gen_complete)
	backend.failed.connect(_on_failed)
	# 「思考中」兜底超时：即使 voice_failed/character_response 都没回来（响应丢失/TLS/网络），
	# 也在 THINK_TIMEOUT 秒后自动解卡——这是无论后端如何都不再永久卡死的最后一道保险。
	_think_timer = Timer.new()
	_think_timer.one_shot = true
	_think_timer.timeout.connect(_on_think_timeout)
	add_child(_think_timer)

func _on_think_timeout() -> void:
	if thinking_label.visible:
		_on_failed("响应超时（没收到回复）")

## 语音/造角色失败：清掉「思考中」，温和提示重试——否则客户端会一直卡在思考中。
func _on_failed(reason: String) -> void:
	if _think_timer != null:
		_think_timer.stop()
	thinking_label.visible = false
	push_warning("voice/gen failed: %s" % reason)
	if selected != null:
		banner.text = "我没听清呀，再说一次好不好？"
		banner.visible = true
		send_btn.disabled = true
		_recording = false

## 在线引导：POST /worlds → 连 WS → 按世界状态生成角色（含小神仙）。离线则保留占位 NPC。
func _bootstrap() -> void:
	# 加载固定的 default 世界（含预生成村民），不再每次新建
	var world: Dictionary = await api.get_world("default")
	if world.is_empty():
		return # 离线：保留 hardcoded demo NPC
	online = true
	world_id = String(world.get("id", "default"))
	backend.url = (api.base as String).replace("http", "ws") + "/ws"
	backend.connect_to_server()
	for n in npcs:
		(n["node"] as Node).queue_free() # 清掉离线占位
	npcs.clear()
	var chars: Array = world.get("characters", [])
	for c in chars:
		await _spawn_server_character(c as Dictionary, Vector2.INF)
	# 相机聚焦到世界中心（小神仙所在）
	var fairy := _find_fairy()
	if not fairy.is_empty():
		focus_logical = fairy["logical"]

func _find_fairy() -> Dictionary:
	for n in npcs:
		if n.get("is_fairy", false):
			return n
	return {}

## 从后端 Character 字典生成一个 PaperCharacter。at_logical 非 INF 时覆盖其逻辑坐标。
func _spawn_server_character(c: Dictionary, at_logical: Vector2) -> void:
	var npc := PaperCharacter.new()
	add_child(npc)
	var appearance: Dictionary = c.get("appearance", {})
	var asset := String(appearance.get("spriteAsset", ""))
	var tex: Texture2D = critter_tex
	var color := Color.WHITE
	var real := false
	if not asset.is_empty():
		var t := await api.fetch_texture(asset)
		if t != null:
			tex = t
			real = true
	if not real:
		color = Color(0.85, 0.8, 1.0) if c.get("isFairy", false) else Color(0.92, 0.92, 0.92)
	npc.setup(tex, color, String(c.get("name", "")))
	if real:
		# 生成图分辨率高，按高度归一化到约 6 单位，脚底对齐原点
		var h := float(tex.get_height())
		npc.pixel_size = 6.0 / h
		npc.offset = Vector2(0.0, h / 2.0)
	var is_fairy := bool(c.get("isFairy", false))
	var logical := at_logical
	if logical == Vector2.INF:
		# 小世界：忽略后端旧坐标(原 1000×1000 的 tile 500)，统一放到村庄中心(chunk2 = world 中心)
		var center := Vector2(WorldGrid.WORLD_SPAN, WorldGrid.WORLD_SPAN) * 0.5
		if is_fairy:
			logical = center
		else:
			# 村民按黄金角散开成环，避免初始堆叠
			var k := _villager_count
			_villager_count += 1
			var ang := float(k) * 2.399963
			logical = WorldGrid.wrap_pos(center + Vector2(cos(ang), sin(ang)) * (10.0 + float(k) * 3.0))
	npcs.append({ "node": npc, "logical": logical, "id": String(c.get("id", "")), "is_fairy": is_fairy })
	if not is_fairy:
		_start_ambient_wander(npcs[npcs.size() - 1])

func _on_gen_progress(stage: String) -> void:
	thinking_label.text = "施法中… (%s)" % stage
	thinking_label.visible = true

func _on_gen_complete(character: Dictionary) -> void:
	thinking_label.visible = false
	# 新角色在小神仙旁边降生
	var fairy := _find_fairy()
	var anchor: Vector2 = fairy["logical"] if not fairy.is_empty() else focus_logical
	var spawn_at: Vector2 = anchor + Vector2(6.0, 4.0)
	await _spawn_server_character(character, spawn_at)
	banner.text = "%s 来啦！" % String(character.get("name", "新朋友"))
	banner.visible = true

## 小神仙造角色（在线）。
func _request_create(intent: String) -> void:
	if online:
		thinking_label.text = "施法中…"
		thinking_label.visible = true
		backend.send_create_character(world_id, intent)

func _on_listen() -> void:
	# 点一下开始聆听：显示耳朵（_update_ear 已处理），开始采集麦克风并开一个边录边传会话。
	_recording = true
	send_btn.disabled = false
	banner.text = "我在听… 说完点发送"
	_pending_pcm = PackedByteArray()
	_chunk_accum = 0.0
	_streamed_any = false
	if _capture != null:
		_capture.clear_buffer()
	if _mic_player != null and not _mic_player.playing:
		_mic_player.play()
	backend.send_voice_start(world_id, _selected_id())

func _on_send() -> void:
	if selected == null:
		return
	_recording = false
	send_btn.disabled = true
	thinking_label.visible = true
	banner.visible = false
	# 收尾：把残留缓冲 + 最后一截采集都发出去，再发 voice_end 触发识别/回复。
	_pending_pcm.append_array(_capture_pcm16k())
	_flush_pending_chunk()
	if not _streamed_any:
		# 无麦/空采集时塞个占位分片，闭环仍可由后端驱动（与旧行为一致）
		backend.send_voice_chunk(Marshalls.raw_to_base64(PackedByteArray([0x52, 0x49, 0x46, 0x46])))
	if _mic_player != null:
		_mic_player.stop()
	backend.send_voice_end()
	_think_timer.start(THINK_TIMEOUT)  # 兜底：响应没回来也会自动解卡

## 录音中周期性把采集缓冲攒成分片发出（上传与说话重叠，松手时音频已基本传完）。
func _stream_recording(delta: float) -> void:
	_pending_pcm.append_array(_capture_pcm16k())
	_chunk_accum += delta
	if _chunk_accum >= 0.15:
		_flush_pending_chunk()
		_chunk_accum = 0.0

func _flush_pending_chunk() -> void:
	if _pending_pcm.size() > 0:
		backend.send_voice_chunk(Marshalls.raw_to_base64(_pending_pcm))
		_pending_pcm = PackedByteArray()
		_streamed_any = true

## 读采集缓冲 → 单声道 + 线性重采样到 16k 16bit PCM 字节。
func _capture_pcm16k() -> PackedByteArray:
	var out := PackedByteArray()
	if _capture == null:
		return out
	var avail := _capture.get_frames_available()
	if avail <= 0:
		return out
	var frames := _capture.get_buffer(avail)
	var ratio := 16000.0 / float(_rec_rate)
	var dst_n := int(frames.size() * ratio)
	out.resize(dst_n * 2)
	for i in range(dst_n):
		var src_i := int(i / ratio)
		if src_i >= frames.size():
			break
		var s: float = (frames[src_i].x + frames[src_i].y) * 0.5
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		out[i * 2] = v & 0xFF
		out[i * 2 + 1] = (v >> 8) & 0xFF
	return out

func _on_character_response(data: Dictionary) -> void:
	if _think_timer != null:
		_think_timer.stop()
	thinking_label.visible = false
	var transcript := String(data.get("transcript", ""))
	if transcript.is_empty():
		heard_label.text = "👂 没听清，再说一次试试"
	else:
		heard_label.text = "👂 听到：%s" % transcript
	heard_label.visible = true
	banner.text = String(data.get("replyText", ""))
	banner.visible = true
	_show_emotion(String(data.get("emotion", "happy")))
	var script: Variant = data.get("behaviorScript", null)
	if typeof(script) == TYPE_DICTIONARY and selected != null:
		_run_behavior(selected, script)
	var asset := String(data.get("ttsAsset", ""))
	if not asset.is_empty():
		_play_tts(asset)

## 下载 TTS（16k L16 PCM）→ AudioStreamWAV 播放。
func _play_tts(asset: String) -> void:
	var bytes := await api.fetch_bytes(asset)
	if bytes.is_empty():
		return
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 16000
	wav.stereo = false
	wav.data = bytes
	_tts_player.stream = wav
	_tts_player.play()

func _show_emotion(emotion: String) -> void:
	var glyphs := { "happy": "☺", "think": "?", "wave": "!", "sad": "…" }
	var glyph: String = glyphs.get(emotion, "♪")
	emotion_bubble.text = glyph
	emotion_bubble.visible = true

func _update_emotion_bubble() -> void:
	if emotion_bubble.visible and selected != null and is_instance_valid(selected):
		emotion_bubble.global_position = selected.global_position + Vector3(0.0, 4.6, 0.0)
	elif selected == null:
		emotion_bubble.visible = false

## 在选中角色上执行行为脚本（移动等）。
func _run_behavior(npc: PaperCharacter, script: Dictionary) -> void:
	var dict := _find_npc_dict(npc)
	if dict.is_empty():
		return
	var ex := BehaviorExecutor.new()
	ex.setup(dict, script, Callable(self, "_resolve_char_pos"), Callable(self, "_deliver_message"))
	_executors.append(ex)

## deliver_message 用：按 id 或名字找角色逻辑坐标，找不到返回 Vector2.INF。
func _resolve_char_pos(id: String) -> Vector2:
	for n in npcs:
		if String(n.get("id", "")) == id or (n["node"] as PaperCharacter).char_name == id:
			return n["logical"]
	return Vector2.INF

## deliver_message 用：角色把话带到目标处时回调，目标显示气泡 + 横幅。
func _deliver_message(target_id: String, message: String) -> void:
	for n in npcs:
		if String(n.get("id", "")) == target_id or (n["node"] as PaperCharacter).char_name == target_id:
			var name := (n["node"] as PaperCharacter).char_name
			banner.text = "%s 收到啦：%s" % [name, message]
			banner.visible = true
			return

func _find_npc_dict(npc: PaperCharacter) -> Dictionary:
	for n in npcs:
		if n["node"] == npc:
			return n
	return {}

func _selected_id() -> String:
	if selected == null:
		return ""
	var d := _find_npc_dict(selected)
	var id := String(d.get("id", ""))
	return id if not id.is_empty() else selected.char_name
