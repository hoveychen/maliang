extends Node3D
## Demo 世界控制器（P5）。
## 浮动原点 + chunk streaming + world-bending + HD-2D 纸片角色 + 点击进交互模式。
## 逻辑/数据是纯平铺环面；弯曲只在渲染。角色精灵不走 shader，改用 CPU 复算
## 弯曲量、沿相机上方向落到弯曲地表（曲面世界放置物体的通用解法）。

const PLAYER_SPEED := 8.0         ## 方向键直接驱动玩家的速度（与 BehaviorExecutor.SPEED 一致）
const GOD_PITCH_DEG := 47.0       ## 默认跟随视角：地平线落屏幕 ~4/5 高度（约 20% 天空）
const LOCK_PITCH_DEG := 30.0      ## lock 跟随：明显放平（3/4 平视，地平线 ~3/4、约 25% 天空）
const SPRITE_LEAN_FACTOR := 0.55  ## 角色固定倾角 = (90-相机角)*该系数（站立感+面向相机折中）
const GOD_DIST := 36.0
const LOCK_DIST := 20.0
const ZOOM_MIN := 16.0
const ZOOM_MAX := 64.0
const CAM_EASE := 6.0             ## 视角过渡速度（pitch/dist/focus 一起缓动）
const PICK_RADIUS_PX := 80.0
const THINK_TIMEOUT := 40.0       ## 「思考中」最长等待秒数；超时(响应丢失/网络/TLS)自动清除，杜绝永久卡死
const PLAYER_ID := "player"
const PLAYER_SPAN := 2            ## 玩家占地（半格数），与 NPC 一致

var focus_logical := Vector2.ZERO   ## 相机在环面上聚焦的逻辑坐标（跟随玩家/交互对象）
var focus_override := Vector2.INF   ## 测试脚本抢镜头用：非 INF 时聚焦固定到这里
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
var player: Dictionary = {}       ## 玩家角色 { node, logical, id, span }；不进 npcs（拾取/对话只对 NPC）
var selected: PaperCharacter = null
var ear_icon: Sprite3D
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
var _asr_local: Object = null # 端侧 ASR 插件（Android MaliangAsr），null = 服务端识别
var _local_asr_session := false # 本次录音走端侧（录音开始时定格，中途不切换）
# 流式 TTS：tts_chunk 分片先积压再按 generator 空位排空（_drain_tts_stream）
var _tts_stream_pcm := PackedByteArray()
var _tts_gen_playback: AudioStreamGeneratorPlayback = null

func _ready() -> void:
	critter_tex = load("res://assets/critter.png")
	ear_tex = load("res://assets/ear.svg")
	_setup_local_asr()
	_setup_environment()
	chunk_manager = ChunkManager.new()
	chunk_manager.name = "ChunkManager"
	add_child(chunk_manager)
	_setup_camera()
	_setup_npcs()
	_setup_player()
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
	# 弯曲已改为世界空间位移（world_bend.gdshader）：相机/shadow pass 几何一致，可开阴影。
	# 单 split 正交 + 短距离：Android 平板便宜；雾在 ~95 淡出，阴影只需覆盖近处。
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	light.directional_shadow_max_distance = 90.0
	light.shadow_blur = 1.5
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
		var lg := WorldGrid.wrap_pos(d["logical"])
		npcs.append({ "node": npc, "logical": lg, "id": "demo_%s" % d["name"] })
		OccupancyMap.char_register("demo_%s" % d["name"], lg, 2)
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

## 玩家角色：占位形象（粉色 critter），后续由 onboarding 生成的形象替换。
func _setup_player() -> void:
	var node := PaperCharacter.new()
	add_child(node)
	node.setup(critter_tex, Color(1.0, 0.74, 0.80), "我")
	var spawn := _find_free_spot(focus_logical, PLAYER_SPAN)
	player = { "node": node, "logical": spawn, "id": PLAYER_ID, "span": PLAYER_SPAN }
	OccupancyMap.char_register(PLAYER_ID, spawn, PLAYER_SPAN)

## 在 around 附近按环形扫描找可站立空位（不压物件/角色、不在水里）；找不到原样返回。
func _find_free_spot(around: Vector2, span: int) -> Vector2:
	for r in range(0, 9):
		var n_ang := 16 if r > 0 else 1
		for k in range(n_ang):
			var ang := float(k) * TAU / float(n_ang)
			var p := WorldGrid.wrap_pos(around + Vector2(cos(ang), sin(ang)) * float(r))
			if TerrainMap.tile_type(WorldGrid.to_tile(p)) == TerrainMap.T_WATER:
				continue
			var origin := OccupancyMap.footprint_origin(p, span)
			if OccupancyMap.is_free_rect(origin, span, span) \
					and OccupancyMap.char_area_free(origin, span, span, PLAYER_ID):
				return p
	return around

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
	# 方向键直接驱动玩家（桌面调试；与点击移动同一 Mover 规则）
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if input != Vector2.ZERO and not player.is_empty():
		var moved := Mover.attempt(player["logical"], input * PLAYER_SPEED * delta, PLAYER_SPAN, PLAYER_ID)
		if moved != player["logical"]:
			player["logical"] = moved
			OccupancyMap.char_register(PLAYER_ID, moved, PLAYER_SPAN)

func _process(delta: float) -> void:
	_drain_tts_stream()
	_step_executors(delta)
	if _recording:
		_stream_recording(delta)
	# 视角缓动（跟随 ↔ lock 的 pitch/dist 过渡）
	var t := minf(1.0, CAM_EASE * delta)
	_cur_pitch = lerpf(_cur_pitch, _target_pitch, t)
	_cur_dist = lerpf(_cur_dist, _target_dist, t)
	# 聚焦缓动：测试 override > 交互对象 > 玩家（饥荒式相机永远跟着「我」）
	var want := focus_logical
	if focus_override != Vector2.INF:
		want = focus_override
	elif _locked != null and is_instance_valid(_locked):
		want = _find_npc_dict(_locked).get("logical", focus_logical)
	elif not player.is_empty():
		want = player["logical"]
	var fd := WorldGrid.shortest_delta(focus_logical, want)
	focus_logical = WorldGrid.wrap_pos(focus_logical + fd * t)
	_update_camera()
	chunk_manager.update(focus_logical)
	_reposition_npcs(delta)
	_update_ear()
	_update_emotion_bubble()
	_update_hud()

func _step_executors(delta: float) -> void:
	for ex in _executors:
		ex.step(delta)
	_executors = _executors.filter(func(e: BehaviorExecutor) -> bool: return not e.is_done())

func _reposition_npcs(delta: float) -> void:
	# 固定小倾角：随当前相机角度调（站立感 + 面向相机的折中），绕脚底前倾
	var lean := deg_to_rad((90.0 - _cur_pitch) * SPRITE_LEAN_FACTOR)
	for n in npcs:
		_place_char(n, lean, delta)
	if not player.is_empty():
		_place_char(player, lean, delta)

## 按角色字典的逻辑坐标摆到弯曲地表（含台阶高度跟随，短 lerp 平滑 2m 跳变）。
func _place_char(n: Dictionary, lean: float, delta: float) -> void:
	var d: Vector2 = WorldGrid.shortest_delta(focus_logical, n["logical"])
	var node: Node3D = n["node"]
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(n["logical"]))) * TerrainMap.STEP_HEIGHT
	var ry := lerpf(float(n.get("ry", ty)), ty, minf(1.0, 12.0 * delta))
	n["ry"] = ry
	_place_on_bent_ground(node, Vector3(d.x, ry, d.y))
	node.rotation = Vector3(-lean, 0.0, 0.0)

## 把节点放到「弯曲后」的地表位置。与 world_bend.gdshader 同一公式：
## 世界空间、以原点（玩家）为中心的水平距离平方下沉（shadow pass 一致，见着色器注释）。
func _place_on_bent_ground(node: Node3D, base_world: Vector3) -> void:
	var drop := BendMat.CURVATURE * (base_world.x * base_world.x + base_world.z * base_world.z)
	node.global_position = base_world - Vector3(0.0, drop, 0.0)

func _update_ear() -> void:
	if selected != null and is_instance_valid(selected):
		ear_icon.visible = true
		ear_icon.global_position = selected.global_position + Vector3(0.0, 3.6, 0.0)
	else:
		ear_icon.visible = false

func _update_hud() -> void:
	var t := WorldGrid.to_tile(player["logical"] if not player.is_empty() else focus_logical)
	coord_label.text = "tile (%d, %d)  /  %d×%d  环面循环" % [t.x, t.y, WorldGrid.GRID_TILES, WorldGrid.GRID_TILES]

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
			_dragging = true # 相机跟随玩家，拖拽不再平移；仅防误触发拾取
		return
	# 触屏：拖动不平移（跟随相机），点触拾取
	if event is InputEventScreenDrag:
		_dragging = true
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
	backend.tts_chunk.connect(_on_tts_chunk)
	backend.tts_end.connect(func() -> void: pass) # 残余积压由 _drain_tts_stream 排空，无需专门收尾
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
		OccupancyMap.char_unregister(String(n.get("id", "")))
		(n["node"] as Node).queue_free() # 清掉离线占位
	npcs.clear()
	var chars: Array = world.get("characters", [])
	for c in chars:
		await _spawn_server_character(c as Dictionary, Vector2.INF)
	# 玩家搬到小神仙旁边降生，相机跟着玩家过去
	var fairy := _find_fairy()
	if not fairy.is_empty():
		focus_logical = fairy["logical"]
		if not player.is_empty():
			var spot := _find_free_spot(WorldGrid.wrap_pos(fairy["logical"] + Vector2(5.0, 3.0)), PLAYER_SPAN)
			player["logical"] = spot
			OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)

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
	var cid := String(c.get("id", ""))
	if cid.is_empty():
		cid = String(c.get("name", "")) # 后端无 id 时用名字兜底，保证角色层有主
	npcs.append({ "node": npc, "logical": logical, "id": cid, "is_fairy": is_fairy })
	OccupancyMap.char_register(cid, logical, 2)
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

## 端侧 ASR（Android 插件 MaliangAsr）：有则异步加载模型，识别结果直送 voice_transcript。
## 桌面/编辑器没有该单例 → _asr_local 保持 null，一切走服务端识别（原路径）。
func _setup_local_asr() -> void:
	if not Engine.has_singleton("MaliangAsr"):
		return
	_asr_local = Engine.get_singleton("MaliangAsr")
	_asr_local.connect("final_result", _on_local_asr_final)
	_asr_local.connect("asr_error", _on_local_asr_error)
	_asr_local.initialize()

func _on_local_asr_final(text: String) -> void:
	_local_asr_session = false
	var t := text.strip_edges()
	if t.is_empty():
		# 端侧就知道没听清，不必打扰服务端
		_think_timer.stop()
		thinking_label.visible = false
		heard_label.text = "👂 没听清，再说一次试试"
		heard_label.visible = true
		return
	backend.send_voice_transcript(world_id, _selected_id(), t)

func _on_local_asr_error(msg: String) -> void:
	push_warning("端侧 ASR 出错，本次运行回落服务端识别: %s" % msg)
	_local_asr_session = false
	_asr_local = null

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
	# 路由定格：端侧模型就绪 → 本地识别（分片不上传，只送最终文本）；否则服务端流式。
	_local_asr_session = _asr_local != null and _asr_local.isReady()
	if _local_asr_session:
		_asr_local.startSession()
	else:
		backend.send_voice_start(world_id, _selected_id())

func _on_send() -> void:
	if selected == null:
		return
	_recording = false
	send_btn.disabled = true
	thinking_label.visible = true
	banner.visible = false
	# 收尾：把残留缓冲 + 最后一截采集都发出去，再触发识别/回复。
	_pending_pcm.append_array(_capture_pcm16k())
	_flush_pending_chunk()
	if _mic_player != null:
		_mic_player.stop()
	if _local_asr_session:
		_asr_local.stopSession() # final_result 信号回来后走 voice_transcript
	else:
		if not _streamed_any:
			# 无麦/空采集时塞个占位分片，闭环仍可由后端驱动（与旧行为一致）
			backend.send_voice_chunk(Marshalls.raw_to_base64(PackedByteArray([0x52, 0x49, 0x46, 0x46])))
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
		if _local_asr_session:
			_asr_local.feedPcm(_pending_pcm) # 端侧：原始 PCM 直喂插件，不上传
		else:
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
	if bool(data.get("ttsStreaming", false)):
		_start_tts_stream(_parse_rate(String(data.get("ttsMime", "")), 24000))
	else:
		var asset := String(data.get("ttsAsset", ""))
		if not asset.is_empty():
			_play_tts(asset)

## 流式 TTS：character_response 先到，PCM 分片随 tts_chunk 推来，边收边播（首包即出声）。
func _start_tts_stream(rate: int) -> void:
	_tts_stream_pcm = PackedByteArray()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(rate)
	gen.buffer_length = 2.0
	_tts_player.stop()
	_tts_player.stream = gen
	_tts_player.play()
	_tts_gen_playback = _tts_player.get_stream_playback()

func _on_tts_chunk(pcm: PackedByteArray) -> void:
	if _tts_gen_playback != null:
		_tts_stream_pcm.append_array(pcm)
		_drain_tts_stream()

## 把积压 PCM16 按 generator 剩余空位转成帧推入（每帧 Vector2 双声道同值）。
func _drain_tts_stream() -> void:
	if _tts_gen_playback == null or _tts_stream_pcm.size() < 2:
		return
	var n: int = mini(_tts_gen_playback.get_frames_available(), _tts_stream_pcm.size() / 2)
	if n <= 0:
		return
	var buf := PackedVector2Array()
	buf.resize(n)
	for i in range(n):
		var v: int = (_tts_stream_pcm[i * 2 + 1] << 8) | _tts_stream_pcm[i * 2]
		if v >= 32768:
			v -= 65536
		var sample := float(v) / 32768.0
		buf[i] = Vector2(sample, sample)
	_tts_gen_playback.push_buffer(buf)
	_tts_stream_pcm = _tts_stream_pcm.slice(n * 2)

## 从 audio/L16;rate=N 解析采样率。
func _parse_rate(mime: String, fallback: int) -> int:
	var idx := mime.find("rate=")
	if idx >= 0:
		var parsed := int(mime.substr(idx + 5))
		if parsed > 0:
			return parsed
	return fallback

## 下载 TTS（L16 PCM，采样率随 provider：local Kokoro 24k / 讯飞 16k）→ AudioStreamWAV 播放。
func _play_tts(asset: String) -> void:
	_tts_gen_playback = null # 切回整段路径时停掉流式排空
	var audio := await api.fetch_audio(asset)
	var bytes := audio["bytes"] as PackedByteArray
	if bytes.is_empty():
		return
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(audio["rate"])
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
