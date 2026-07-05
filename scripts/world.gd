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
const UNMUTE_GRACE := 0.3         ## 闭麦（思考/TTS）结束后的静默恢复期：残响尾音不算开口
const PLAYER_ID := "player"
const PLAYER_SPAN := 2            ## 玩家占地（半格数），与 NPC 一致
const APPROACH_ARRIVE := 2.6      ## 跑向 NPC 的到达半径：对象自身占格，走到旁边即算到（同送信）
const FAIRY_HEIGHT := 1.5         ## 小仙子立绘世界高度（头部大小的随从，时之笛式）
const FAIRY_HOVER := 2.4          ## 小仙子悬浮基准高度（米，脚底离地）
const FOG_DEPTH_BEGIN := 40.0     ## 深度雾起点（焦点在平地时；随 _cur_focus_y 整体补偿）
const FOG_DEPTH_END := 95.0       ## 小世界(span 150)：~95 外渐隐进天空，藏住远端循环，保留无限地平线感
const SKY_HORIZON_COLOR := Color(0.62, 0.82, 0.97) ## 天空地平线色 = 雾色（远地渐隐进天空的无缝衔接）
const SKY_ZENITH_COLOR := Color(0.33, 0.58, 0.93)  ## 天顶色（可见天空带上缘的深一档蓝）
const SKY_WIND := Vector2(0.006, 0.0015)           ## 云漂移速度（uv/秒），非零 = 天空是动的
# 纸片动作演出（_update_paper_motion）
const WALK_SWAY_DEG := 6.0   ## 走路左右摇摆角（度，绕脚底 roll）
const WALK_SWAY_HZ := 2.6    ## 摇摆频率（步频感）
const WALK_FLUTTER := 0.10   ## 走路下摆飘动幅度（米，paper shader 行波）
const IDLE_CURL := 0.045     ## 待机呼吸微卷幅度（米，左右边缘向 Z）
const FLIP_SPEED := 10.0     ## 翻面角速度（rad/s，~0.3s 完成一次转身翻面）
const FACE_MOVE_EPS := 0.5   ## 认定横向移动的最小速度（米/秒），防原地抖动换面

var focus_logical := Vector2.ZERO   ## 相机在环面上聚焦的逻辑坐标（跟随玩家/交互对象）
var focus_override := Vector2.INF   ## 测试脚本抢镜头用：非 INF 时聚焦固定到这里
var _cur_pitch := GOD_PITCH_DEG
var _cur_dist := GOD_DIST
var _target_pitch := GOD_PITCH_DEG
var _target_dist := GOD_DIST
var _cur_focus_y := 0.0             ## 相机焦点高度 = focus 所在 tile 的台阶高度（缓动，防上台阶时画面跳变）
var _env: Environment               ## 世界环境（深度雾起止随 _cur_focus_y 补偿，山顶视角不整体变浓雾）
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
# 暗黑式按住跟随：指针按在空地上即走，按住期间节流重下发指针下地面为移动目标
const HOLD_FOLLOW_INTERVAL := 0.12
var _hold_follow := false
var _hold_pos := Vector2.ZERO
var _hold_timer := 0.0
# 点击落点标记（黄色圆片，淡出）
const TAP_MARKER_LIFE := 0.8
var _tap_marker: MeshInstance3D = null
var _tap_marker_logical := Vector2.ZERO
var _tap_marker_t := 0.0

# M2 语音交互（近身开放麦：无按钮，VAD 自动断句，见 _step_voice）
var backend: Backend
var _vad: VoiceVad = null          ## 近身对话期间非 null：端点检测器（进交互创建，退出置空）
var _unmute_t := 0.0               ## 闭麦恢复期剩余秒数（UNMUTE_GRACE 倒计时）
var thinking_label: Label          ## 思考状态源+家长可读小字（幼儿看角色头顶的 _think_bubble 动画）
var _think_timer: Timer            ## 「思考中」兜底超时（响应没回来时自动解卡）
var _think_bubble: Label3D         ## 思考动画气泡：选中角色头顶 ·/··/··· 循环冒泡（不识字友好）
var _think_anim_t := 0.0           ## 思考气泡动画相位
var emotion_bubble: Label3D
var _npc_chat_bubble: Label3D      ## NPC 间聊天轮流气泡（同一时刻只演一场，见 _update_npc_chats）
var _emotion_pop_t := -1.0         ## 情绪弹出动画已播秒数（<0 = 不在弹出中）
var _emotion_life := 0.0           ## 情绪气泡剩余展示秒数（尾段淡出后隐藏）
var _speak_anim_t := 0.0           ## 说话呼吸弹跳相位
var _recording := false
var _executors: Array = []        ## 活跃的 BehaviorExecutor
var _fairy_drift_t := 0.0         ## 小仙子漂移/浮动相位
var fairy_voice: FairyVoice       ## 预制台词播放器（构建期 TTS，运行期零调用）
var _fairy_bubble: Label3D        ## 小仙子说话时的 ♪ 气泡
var _fairy_greeted := false       ## 每次启动只问候一次
var _fairy_chat_t := 3.0          ## 下一次闲聊倒计时（首次 ~3s 内问候）
var _fairy_poi: Dictionary = {}   ## 进行中的 POI 提醒 { point, trigger, spoke, hold }
var _poi_check_t := 6.0           ## POI 扫描倒计时（每 2s 一次，开局先安静一会）

## 默认地形的兴趣点：池塘 / 北部主峰 / 东南瞭望丘风车 / 西南沼泽小潭。
## 发现半径内且台词未冷却时，小仙子飞过去提醒（台词冷却 180s 天然防重复唠叨）。
## name/aliases：语音指令「去某地」的地点名解析（名字与小仙子台词一致，见 _resolve_location）。
const POIS := [
	{ "tile": Vector2i(24, 24), "radius": 20.0, "trigger": "poi_pond", "name": "池塘", "aliases": ["湖", "水边", "河边"] },
	{ "tile": Vector2i(31, 7), "radius": 22.0, "trigger": "poi_mountain", "name": "大山", "aliases": ["山", "高山", "山顶"] },
	{ "tile": Vector2i(59, 54), "radius": 20.0, "trigger": "poi_windmill", "name": "风车", "aliases": ["大风车", "风车山"] },
	{ "tile": Vector2i(13, 50), "radius": 18.0, "trigger": "poi_marsh", "name": "小水潭", "aliases": ["水潭", "树林", "小树林"] },
]
const POI_FLY_CAP := 9.0          ## 提醒飞行离玩家的最远距离（保持在视野内）
var _player_executor: BehaviorExecutor = null ## 玩家当前移动指令（新点击即替换）
var _approach: Dictionary = {}    ## 正在跑向的目标 NPC 字典（到旁边后进近身视图）
var _stopped: Dictionary = {}     ## 被叫停等玩家的 NPC 字典（退出交互恢复闲逛）
var world_id := ""

# M2-real 在线
var api: Api
var online := false
var _villager_count := 0          ## 村民散开序号（避免堆叠在中心）

# 音频 I/O（真机：麦克风采集 + TTS 播放）
var _mic: MicRecorder
var _tts_player: AudioStreamPlayer
# 边录边传：录音时持续把采集到的 PCM 攒成小块发给后端（上传与说话重叠）
var _pending_pcm := PackedByteArray()
var _chunk_accum := 0.0   ## 距上次发分片的累计秒数
var _asr_local: Object = null # 端侧 ASR 插件（Android MaliangAsr），null = 服务端识别
var _local_asr_session := false # 本次录音走端侧（录音开始时定格，中途不切换）
# 流式 TTS：tts_chunk 分片先积压再按 generator 空位排空（_drain_tts_stream）
var _tts_stream_pcm := PackedByteArray()
var _tts_gen_playback: AudioStreamGeneratorPlayback = null
var _tts_ending := false  ## 已收到 tts_end：积压排空+缓冲播完后主动 stop（generator 不会自己停）
var _tts_gen_capacity := 0 ## generator 空缓冲容量（开播时实测，播完判定的基准）

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
	_setup_fairy_offline()
	_setup_ear()
	_setup_hud()
	_setup_backend()
	api = Api.new()
	api.name = "Api"
	add_child(api)
	_setup_audio()
	_bootstrap() # 在线引导（best-effort，离线则保留占位 NPC）

func _setup_audio() -> void:
	# 麦克风采集抽到 MicRecorder（与 onboarding 共用）；TTS 播放器保留在本场景
	_mic = MicRecorder.new()
	_mic.name = "MicRecorder"
	add_child(_mic)
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
	env.background_mode = Environment.BG_SKY
	env.sky = _make_day_sky()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.78, 0.85)
	env.ambient_light_energy = 0.6
	# 深度雾：远处地面渐隐到天空地平线色 → chunk 边界雾化进天空、自然无限地平线
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = SKY_HORIZON_COLOR
	env.fog_light_energy = 1.0
	env.fog_depth_begin = FOG_DEPTH_BEGIN
	env.fog_depth_end = FOG_DEPTH_END
	env.fog_depth_curve = 1.0
	# 深度雾默认对天空满强度（sky 在无穷远 = 雾最浓），会把整个渐变/云抹平回雾色；
	# 关掉它，天空自己在 shader 里用 horizon_color 与雾带衔接。
	env.fog_sky_affect = 0.0
	we.environment = env
	add_child(we)
	_env = env

## 白天动态天空：渐变 + 卡通云漂移 + 太阳光晕（shaders/sky_day.gdshader）。
## ambient 走纯色源不依赖天空 radiance，radiance 取最小档 + 仅材质变更时重烘
## （REALTIME 档强制 256 且逐帧重烘，安卓平板不划算；本世界高粗糙度+关高光，反射用不上）。
func _make_day_sky() -> Sky:
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = 0.008
	var cloud_tex := NoiseTexture2D.new()
	cloud_tex.seamless = true
	cloud_tex.width = 256
	cloud_tex.height = 256
	cloud_tex.noise = noise
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/sky_day.gdshader")
	mat.set_shader_parameter("cloud_tex", cloud_tex)
	mat.set_shader_parameter("horizon_color", SKY_HORIZON_COLOR)
	mat.set_shader_parameter("zenith_color", SKY_ZENITH_COLOR)
	mat.set_shader_parameter("wind", SKY_WIND)
	var sky := Sky.new()
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	return sky

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 50.0
	camera.far = 900.0
	add_child(camera)
	_update_camera()

## 相机固定在渲染原点上方、看向原点；平移靠改 focus_logical（世界相对滚动），
## 角度(pitch)/距离(dist) 由 god/lock 目标缓动得到。
## 焦点随 focus 所在 tile 的台阶高度整体抬升（_cur_focus_y），否则上高阶地形后角色出画。
func _update_camera() -> void:
	var pitch := deg_to_rad(_cur_pitch)
	var focus := Vector3(0.0, _cur_focus_y, 0.0)
	camera.global_position = focus + Vector3(0.0, sin(pitch) * _cur_dist, cos(pitch) * _cur_dist)
	camera.look_at(focus, Vector3.UP)

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

## 玩家角色：称呼来自 onboarding 档案；先占位形象（粉色 critter），
## 在线后由 _apply_player_sprite 换成档案里生成的形象。
func _setup_player() -> void:
	var node := PaperCharacter.new()
	add_child(node)
	var prof := PlayerProfile.load_profile()
	var pname := String(prof.get("nickname", ""))
	if pname.is_empty():
		pname = String(prof.get("name", ""))
	if pname.is_empty():
		pname = "我"
	node.setup(critter_tex, Color(1.0, 0.74, 0.80), pname)
	var spawn := _find_free_spot(focus_logical, PLAYER_SPAN)
	player = { "node": node, "logical": spawn, "id": PLAYER_ID, "span": PLAYER_SPAN }
	OccupancyMap.char_register(PLAYER_ID, spawn, PLAYER_SPAN)

## 档案里有生成形象时，从服务端拉取替换占位（离线/失败静默保留占位）。
func _apply_player_sprite() -> void:
	var asset := String(PlayerProfile.load_profile().get("sprite_asset", ""))
	if asset.is_empty() or player.is_empty():
		return
	var tex := await api.fetch_texture(asset)
	if tex == null or player.is_empty():
		return
	var node := player["node"] as PaperCharacter
	node.texture = tex
	# 生成图按高度归一化到 5 单位（小朋友比 6 单位的村民略矮），脚底对齐
	node.pixel_size = 5.0 / float(tex.get_height())
	node.offset = Vector2(0.0, float(tex.get_height()) / 2.0)
	node.modulate = Color.WHITE

## 离线模式的小仙子随从（在线时 _bootstrap 会清掉、换成服务端小神仙）。
## 悬浮飞行：不登记占用图、不走寻路，由 _update_fairy 驱动跟随玩家。
func _setup_fairy_offline() -> void:
	var tex: Texture2D = load("res://assets/fairy.png")
	var node := PaperCharacter.new()
	add_child(node)
	node.setup(tex, Color.WHITE, "小神仙")
	node.pixel_size = FAIRY_HEIGHT / float(tex.get_height())
	var spawn := WorldGrid.wrap_pos(player["logical"] + Vector2(3.0, 2.0))
	npcs.append({ "node": node, "logical": spawn, "id": "fairy_local", "is_fairy": true, "hover": FAIRY_HOVER })
	fairy_voice = FairyVoice.new()
	fairy_voice.name = "FairyVoice"
	add_child(fairy_voice)
	_fairy_bubble = Label3D.new()
	_fairy_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_fairy_bubble.pixel_size = 0.02
	_fairy_bubble.outline_size = 12
	_fairy_bubble.font_size = 72
	_fairy_bubble.text = "♪"
	_fairy_bubble.visible = false
	add_child(_fairy_bubble)

## 小仙子随从每帧驱动：悬浮漂移跟在玩家旁（玩家跑动时拖尾追赶，静止时缓慢环绕），
## 轻微上下浮动。永远由这里驱动，不吃行为脚本（见 _run_behavior）。
func _update_fairy(delta: float) -> void:
	var fairy := _find_fairy()
	if fairy.is_empty() or player.is_empty():
		return
	_fairy_drift_t += delta
	var target: Vector2
	var speed_min := 1.2
	if not _fairy_poi.is_empty():
		target = _fairy_poi["point"]
		speed_min = 14.0 # 提醒飞行：果断飞过去
		_step_fairy_poi(delta, fairy, target)
	elif selected == fairy.get("node"):
		target = fairy["logical"] # 对话中：停在原地听小朋友说话（仍轻微浮动）
	else:
		var drift := Vector2(cos(_fairy_drift_t * 0.6), sin(_fairy_drift_t * 0.45)) * 1.8
		target = WorldGrid.wrap_pos(player["logical"] + Vector2(2.6, 1.8) + drift)
	var d := WorldGrid.shortest_delta(fairy["logical"], target)
	var speed := clampf(d.length() * 2.0, speed_min, 26.0) # 越远追得越快
	var step := d.normalized() * minf(speed * delta, d.length())
	fairy["logical"] = WorldGrid.wrap_pos(fairy["logical"] + step)
	fairy["hover"] = FAIRY_HOVER + sin(_fairy_drift_t * 2.2) * 0.3
	if _fairy_poi.is_empty():
		_fairy_ambient(delta, fairy)
	else:
		_update_fairy_bubble(fairy) # 飞行提醒中也要挂 ♪
	_check_poi(delta)

## POI 提醒推进：到位后说台词，说完稍作停留再回到玩家身边。
func _step_fairy_poi(delta: float, fairy: Dictionary, target: Vector2) -> void:
	if WorldGrid.shortest_delta(fairy["logical"], target).length() > 1.0:
		return
	if not _fairy_poi.get("spoke", false):
		fairy_voice.try_play(_fairy_poi["trigger"])
		_fairy_poi["spoke"] = true
		_fairy_poi["hold"] = 2.0
		return
	if not fairy_voice.is_playing():
		_fairy_poi["hold"] = float(_fairy_poi["hold"]) - delta
		if float(_fairy_poi["hold"]) <= 0.0:
			_fairy_poi = {}

## 周期扫描 POI：玩家进入发现半径且对应台词未冷却 → 小仙子朝 POI 方向飞（距玩家封顶，
## 保持在视野内）。交互/录音/思考/TTS 中不打扰。
func _check_poi(delta: float) -> void:
	if not _fairy_poi.is_empty() or fairy_voice == null:
		return
	_poi_check_t -= delta
	if _poi_check_t > 0.0:
		return
	_poi_check_t = 2.0
	if selected != null or _recording or thinking_label.visible or _tts_player.playing:
		return
	for poi in POIS:
		var pp := TerrainMap.tile_center(poi["tile"])
		var dp := WorldGrid.shortest_delta(player["logical"], pp)
		if dp.length() <= float(poi["radius"]) and fairy_voice.can_play(String(poi["trigger"])):
			var fly := dp.normalized() * minf(dp.length(), POI_FLY_CAP)
			_fairy_poi = { "point": WorldGrid.wrap_pos(player["logical"] + fly),
				"trigger": String(poi["trigger"]), "spoke": false, "hold": 2.0 }
			return

## 氛围台词引擎：先问候，之后每 15~25s 按周围环境挑话题（水/山/村庄），没有就闲聊。
## 交互/录音/思考/正式 TTS 播放中一律闭嘴，避免叠声。
func _fairy_ambient(delta: float, fairy: Dictionary) -> void:
	if fairy_voice == null:
		return
	_update_fairy_bubble(fairy)
	if selected != null or _recording or thinking_label.visible or _tts_player.playing:
		return
	_fairy_chat_t -= delta
	if _fairy_chat_t > 0.0:
		return
	_fairy_chat_t = randf_range(15.0, 25.0)
	if not _fairy_greeted:
		_fairy_greeted = fairy_voice.try_play("greet")
		return
	fairy_voice.try_play(_ambient_trigger())

## ♪ 气泡：小仙子出声时挂在头顶（氛围闲聊与 POI 提醒共用）。
func _update_fairy_bubble(fairy: Dictionary) -> void:
	var node: Node3D = fairy["node"]
	_fairy_bubble.visible = fairy_voice.is_playing()
	if _fairy_bubble.visible:
		_fairy_bubble.global_position = node.global_position \
			+ Vector3(0.0, _char_top(node as PaperCharacter) + 0.9, 0.0)

## 按玩家周围地形挑话题：水/高山/村庄优先（各有冷却），否则闲聊。
func _ambient_trigger() -> String:
	var pt := WorldGrid.to_tile(player["logical"])
	var near_water := false
	var near_mountain := false
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			var t := Vector2i((pt.x + dx + WorldGrid.GRID_TILES) % WorldGrid.GRID_TILES,
				(pt.y + dz + WorldGrid.GRID_TILES) % WorldGrid.GRID_TILES)
			if TerrainMap.tile_type(t) == TerrainMap.T_WATER:
				near_water = true
			if TerrainMap.tile_height(t) >= 3:
				near_mountain = true
	if near_water and fairy_voice.can_play("near_water"):
		return "near_water"
	if near_mountain and fairy_voice.can_play("near_mountain"):
		return "near_mountain"
	var center := Vector2(WorldGrid.WORLD_SPAN, WorldGrid.WORLD_SPAN) * 0.5
	if WorldGrid.shortest_delta(player["logical"], center).length() <= 14.0 \
			and fairy_voice.can_play("near_village"):
		return "near_village"
	return "idle"

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

	# 思考状态：小字弱化到顶部（给家长看），幼儿看角色头顶的 _think_bubble 动画
	thinking_label = Label.new()
	thinking_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	thinking_label.offset_top = 108.0
	thinking_label.offset_bottom = 140.0
	_style_label(thinking_label, 20)
	thinking_label.text = "思考中…"
	thinking_label.visible = false
	layer.add_child(thinking_label)

	# 思考动画气泡：·/··/··· 循环冒泡（挂选中角色头顶，_update_think_bubble 驱动）
	_think_bubble = Label3D.new()
	_think_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_think_bubble.pixel_size = 0.02
	_think_bubble.outline_size = 14
	_think_bubble.font_size = 110
	_think_bubble.visible = false
	add_child(_think_bubble)

	# 角色头顶情绪气泡：大 emoji + 弹出动画（_show_emotion / _update_emotion_bubble）
	emotion_bubble = Label3D.new()
	emotion_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	emotion_bubble.pixel_size = 0.02
	emotion_bubble.modulate = Color.WHITE
	emotion_bubble.outline_size = 12
	emotion_bubble.font_size = 96
	emotion_bubble.visible = false
	add_child(emotion_bubble)

	# NPC 间聊天的轮流气泡（chat_with 演出，见 _update_npc_chats）
	_npc_chat_bubble = Label3D.new()
	_npc_chat_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_npc_chat_bubble.pixel_size = 0.02
	_npc_chat_bubble.outline_size = 12
	_npc_chat_bubble.font_size = 84
	_npc_chat_bubble.visible = false
	add_child(_npc_chat_bubble)

func _style_label(l: Label, size: int) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)

func _physics_process(delta: float) -> void:
	# 方向键直接驱动玩家（桌面调试；与点击移动同一 Mover 规则）
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if input != Vector2.ZERO and not player.is_empty():
		_hold_follow = false # 手动操控优先，退出按住跟随
		_cancel_player_move() # 手动操控优先，替换点击移动指令
		var moved := Mover.attempt(player["logical"], input * PLAYER_SPEED * delta, PLAYER_SPAN, PLAYER_ID)
		if moved != player["logical"]:
			player["logical"] = moved
			OccupancyMap.char_register(PLAYER_ID, moved, PLAYER_SPAN)

func _process(delta: float) -> void:
	_drain_tts_stream()
	_step_hold_follow(delta)
	_step_executors(delta)
	_check_approach()
	_update_fairy(delta)
	_step_voice(delta)
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
	var fy := float(TerrainMap.tile_height(WorldGrid.to_tile(focus_logical))) * TerrainMap.STEP_HEIGHT
	_cur_focus_y = lerpf(_cur_focus_y, fy, t)
	# 相机随焦点抬升后离地更远，雾距同步外推，山顶视角与平地一样通透
	# （RENDER_RADIUS 110 > 最高补偿后的可见地面半径 ~103，不会露出 chunk 边缘）
	_env.fog_depth_begin = FOG_DEPTH_BEGIN + _cur_focus_y
	_env.fog_depth_end = FOG_DEPTH_END + _cur_focus_y
	_update_camera()
	chunk_manager.update(focus_logical)
	_reposition_npcs(delta)
	_update_tap_marker(delta)
	_update_ear()
	_update_think_bubble(delta)
	_update_emotion_bubble(delta)
	_update_npc_chats(delta)
	_update_speak_anim(delta)
	_update_hud()

func _step_executors(delta: float) -> void:
	for ex in _executors:
		ex.step(delta)
	var done := _executors.filter(func(e: BehaviorExecutor) -> bool: return e.is_done())
	_executors = _executors.filter(func(e: BehaviorExecutor) -> bool: return not e.is_done())
	# 指令跑完的村民恢复自主闲逛，否则永远呆立。被替换（已有新执行器）、
	# 正被交互叫停（_stopped/selected）、玩家、小仙子都不恢复。
	for e in done:
		for n in npcs:
			if not (e as BehaviorExecutor).drives(n):
				continue
			if n.get("is_fairy", false) or n == _stopped or n.get("in_chat", false) \
					or (selected != null and n.get("node") == selected) \
					or _has_executor_for(n):
				break
			_start_ambient_wander(n)
			break

func _has_executor_for(dict: Dictionary) -> bool:
	for ex in _executors:
		if (ex as BehaviorExecutor).drives(dict):
			return true
	return false

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
	_place_on_bent_ground(node, Vector3(d.x, ry + float(n.get("hover", 0.0)), d.y))
	_update_paper_motion(n, node as PaperCharacter, lean, delta)

## 纸片动作演出（每帧）：走路左右摇摆+下摆飘动 / 横向变向绕竖轴翻面 / 待机呼吸微卷。
## 朝向约定：立绘统一朝右（sprite_style.ts），ry=0 朝右、ry=PI 背面即水平镜像=朝左；
## 翻面中途侧对相机变成一条纸边——纸片马里奥的标志性转身。
## 动画状态记在角色字典（paper_* 键），节点只吃结果，无需自带脚本。
func _update_paper_motion(n: Dictionary, node: PaperCharacter, lean: float, delta: float) -> void:
	var cur: Vector2 = n["logical"]
	var vel := WorldGrid.shortest_delta(n.get("paper_prev", cur), cur) / maxf(delta, 0.0001)
	n["paper_prev"] = cur
	# 朝向目标：横向速度超过阈值才换面（防原地抖动）；纵向移动保持上次朝向
	var face := float(n.get("paper_face", 0.0))
	if absf(vel.x) > FACE_MOVE_EPS:
		face = 0.0 if vel.x > 0.0 else PI
		n["paper_face"] = face
	var fry := move_toward(float(n.get("paper_fry", face)), face, FLIP_SPEED * delta)
	n["paper_fry"] = fry
	# 走路强度 0..1（缓动）：驱动摇摆/飘动，停步平滑归零
	var w := lerpf(float(n.get("paper_walk", 0.0)), clampf(vel.length() / PLAYER_SPEED, 0.0, 1.0), minf(1.0, 10.0 * delta))
	n["paper_walk"] = w
	var phase := float(n.get("paper_phase", randf() * TAU)) + delta * TAU * WALK_SWAY_HZ
	n["paper_phase"] = phase
	var sway := deg_to_rad(WALK_SWAY_DEG) * w * sin(phase)
	# 翻面后节点本地 X 轴反向，倾角随 cos(fry) 连续反号才始终「顶朝远离相机」
	node.rotation = Vector3(-lean * cos(fry), fry, sway)
	# 待机呼吸微卷用慢相位（走动时让位给飘动）；飘动幅度随走路强度
	node.set_paper_motion(WALK_FLUTTER * w, IDLE_CURL * (1.0 - w) * sin(phase * 0.22))
	_update_action_anim(n, node, delta)

## 指令动作演出（do_action 契约键 paper_action，见 BehaviorExecutor.ACTION_DUR）：
## 挥手=左右摇纸 / 跳=双跳 / 转圈=绕竖轴一整圈（中途侧身纸边）/ 点头=前后倾。
## 叠加在正常姿态之上，sin(k*PI) 包络起收平滑，结束自动清键。
func _update_action_anim(n: Dictionary, node: PaperCharacter, delta: float) -> void:
	var action := String(n.get("paper_action", ""))
	if action.is_empty():
		return
	var t := float(n.get("paper_action_t", 0.0)) + delta
	var dur := float(BehaviorExecutor.ACTION_DUR.get(action, 1.2))
	if t >= dur:
		n.erase("paper_action")
		n.erase("paper_action_t")
		return
	n["paper_action_t"] = t
	var k := t / dur
	match action:
		"wave":
			node.rotation.z += deg_to_rad(16.0) * sin(t * TAU * 2.2) * sin(k * PI)
		"jump":
			node.position.y += absf(sin(k * PI * 2.0)) * 1.4 # 两小跳
		"spin":
			node.rotation.y += TAU * smoothstep(0.0, 1.0, k) # 一整圈，中途露纸边
		"nod":
			node.rotation.x += deg_to_rad(12.0) * sin(t * TAU * 1.6) * sin(k * PI)

## 把节点放到「弯曲后」的地表位置。与 world_bend.gdshader 同一公式：
## 世界空间、以原点（玩家）为中心的水平距离平方下沉（shadow pass 一致，见着色器注释）。
func _place_on_bent_ground(node: Node3D, base_world: Vector3) -> void:
	var drop := BendMat.CURVATURE * (base_world.x * base_world.x + base_world.z * base_world.z)
	node.global_position = base_world - Vector3(0.0, drop, 0.0)

func _update_ear() -> void:
	if selected != null and is_instance_valid(selected):
		ear_icon.visible = true
		# 听到声音时耳朵放大脉动：告诉孩子「它听到我说话了」（开放麦唯一的聆听反馈）
		var pulse := 1.0 + (_vad.level if _vad != null else 0.0) * 0.6
		ear_icon.scale = ear_icon.scale.lerp(Vector3.ONE * pulse, 0.5)
		ear_icon.global_position = selected.global_position + Vector3(0.0, _char_top(selected) + 0.5, 0.0)
	else:
		ear_icon.visible = false
		ear_icon.scale = Vector3.ONE

## 角色立绘顶端相对节点原点（脚底）的高度——头顶挂饰（耳朵/气泡）按此定位，小仙子等小体型不悬空。
func _char_top(npc: PaperCharacter) -> float:
	if npc.texture == null:
		return 3.2
	return float(npc.texture.get_height()) * npc.pixel_size

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
	# 鼠标：按在空地即走（暗黑式），按住拖动持续跟随；按在角色上仍走松开拾取
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = false
			_press_pos = event.position
			_try_begin_hold_follow(event.position)
		elif _hold_follow:
			_end_hold_follow(event.position)
		elif not _dragging:
			_tap_pick(event.position)
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if _hold_follow:
			_hold_pos = event.position
		if event.position.distance_to(_press_pos) > 6.0:
			_dragging = true # 防误触发拾取；按住空地的移动由 hold_follow 承担
		return
	# 触屏：与鼠标同一套按住跟随/拾取判定
	if event is InputEventScreenDrag:
		_dragging = true
		if _hold_follow:
			_hold_pos = event.position
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_dragging = false
			_press_pos = event.position
			_try_begin_hold_follow(event.position)
		elif _hold_follow:
			_end_hold_follow(event.position)
		elif not _dragging:
			_tap_pick(event.position)
		return

func _tap_pick(screen_pos: Vector2) -> void:
	var hit := _pick_npc(screen_pos)
	if hit != null:
		_approach_npc(hit)
		return
	# 点自己 = 跟身边的小仙子说话（她是「我」的引导精灵，语音路由到精灵角色）
	if _pick_player(screen_pos):
		var fairy := _find_fairy()
		if not fairy.is_empty():
			_approach_npc(fairy["node"])
		return
	# 点空地：退出交互（恢复被叫停的 NPC），玩家走过去
	if selected != null:
		_exit_interaction()
	_clear_approach()
	var ground := _pick_ground(screen_pos)
	if ground != Vector2.INF and not player.is_empty():
		_show_tap_marker(ground)
		_move_player_to(ground)

## 玩家移动指令：新点击替换旧指令（寻路 waypoint 队列 + Mover 规则由执行器统一处理）。
func _move_player_to(target: Vector2, arrive := 0.0) -> void:
	_cancel_player_move()
	var ex := BehaviorExecutor.new()
	ex.setup(player, {
		"commands": [{ "type": "move_to", "params": { "target": [target.x, target.y], "arrive": arrive } }],
		"loop": false,
	})
	_player_executor = ex
	_executors.append(ex)

func _cancel_player_move() -> void:
	if _player_executor != null:
		_player_executor.cancel()
		_player_executor = null

## 暗黑式按住跟随：仅当按点落在空地（非 NPC/非玩家）时进入，立即下发首个目标。
func _try_begin_hold_follow(screen_pos: Vector2) -> void:
	if _hold_follow or player.is_empty():
		return
	if _pick_npc(screen_pos) != null or _pick_player(screen_pos):
		return
	if _pick_ground(screen_pos) == Vector2.INF:
		return
	if selected != null:
		_exit_interaction()
	_clear_approach()
	_hold_follow = true
	_hold_pos = screen_pos
	_hold_timer = 0.0
	_steer_hold_follow()

func _end_hold_follow(screen_pos: Vector2) -> void:
	_hold_pos = screen_pos
	_steer_hold_follow() # 停在松开处
	_hold_follow = false

## 按住期间每 HOLD_FOLLOW_INTERVAL 秒把指针下地面重下发为移动目标（新指令替换旧指令）。
func _step_hold_follow(delta: float) -> void:
	if not _hold_follow:
		return
	_hold_timer += delta
	if _hold_timer < HOLD_FOLLOW_INTERVAL:
		return
	_hold_timer = 0.0
	_steer_hold_follow()

func _steer_hold_follow() -> void:
	if player.is_empty():
		return
	var ground := _pick_ground(_hold_pos)
	if ground == Vector2.INF:
		return
	_show_tap_marker(ground)
	_move_player_to(ground)

## 屏幕点 → 弯曲地表交点的逻辑坐标；无交点返回 Vector2.INF。
## 地表 y = tile 台阶高度 - 弯曲下沉（与 _place_on_bent_ground 同公式）；
## 台阶/曲面无解析解，射线步进找穿越区间再二分细化（0.5m 步进对 2m tile 足够）。
func _pick_ground(screen_pos: Vector2) -> Vector2:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var prev_t := 0.0
	var t := 0.0
	while t < 220.0:
		t += 0.5
		var p := from + dir * t
		if p.y <= _surface_y(p):
			var lo := prev_t
			var hi := t
			for i in range(10):
				var mid := (lo + hi) * 0.5
				if (from + dir * mid).y <= _surface_y(from + dir * mid):
					hi = mid
				else:
					lo = mid
			var hit := from + dir * hi
			return WorldGrid.wrap_pos(focus_logical + Vector2(hit.x, hit.z))
		prev_t = t
	return Vector2.INF

## 渲染空间点位下方的弯曲地表高度（渲染原点 = focus_logical）。
func _surface_y(p: Vector3) -> float:
	var logical := WorldGrid.wrap_pos(focus_logical + Vector2(p.x, p.z))
	var h := float(TerrainMap.tile_height(WorldGrid.to_tile(logical))) * TerrainMap.STEP_HEIGHT
	return h - BendMat.CURVATURE * (p.x * p.x + p.z * p.z)

## 点击落点标记：黄色小圆片淡出（每帧随世界滚动重摆）。
func _show_tap_marker(logical: Vector2) -> void:
	if _tap_marker == null:
		_tap_marker = MeshInstance3D.new()
		var m := CylinderMesh.new()
		m.top_radius = 0.7
		m.bottom_radius = 0.7
		m.height = 0.06
		_tap_marker.mesh = m
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.95, 0.4, 0.85)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tap_marker.material_override = mat
		add_child(_tap_marker)
	_tap_marker_logical = logical
	_tap_marker_t = TAP_MARKER_LIFE
	_tap_marker.visible = true

func _update_tap_marker(delta: float) -> void:
	if _tap_marker == null or not _tap_marker.visible:
		return
	_tap_marker_t -= delta
	if _tap_marker_t <= 0.0:
		_tap_marker.visible = false
		return
	var d := WorldGrid.shortest_delta(focus_logical, _tap_marker_logical)
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(_tap_marker_logical))) * TerrainMap.STEP_HEIGHT
	_place_on_bent_ground(_tap_marker, Vector3(d.x, ty + 0.05, d.y))
	var mat := _tap_marker.material_override as StandardMaterial3D
	mat.albedo_color.a = 0.85 * clampf(_tap_marker_t / TAP_MARKER_LIFE, 0.0, 1.0)

## 玩家角色的屏幕空间拾取（与 _pick_npc 同一套 unproject 判定）。
func _pick_player(screen_pos: Vector2) -> bool:
	if player.is_empty():
		return false
	var node: Node3D = player["node"]
	var wp := node.global_position + Vector3(0.0, 1.6, 0.0)
	if camera.is_position_behind(wp):
		return false
	return screen_pos.distance_to(camera.unproject_position(wp)) < PICK_RADIUS_PX

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

## 点 NPC：对象停下等待，玩家跑到旁边后再进近身视图（饥荒式）。
func _approach_npc(npc: PaperCharacter) -> void:
	if npc == selected:
		return # 已在与它交互
	var d := _find_npc_dict(npc)
	if d.is_empty():
		return
	if selected != null:
		_exit_interaction()
	_clear_approach()
	_halt_npc(d)
	_approach = d
	_move_player_to(d["logical"], APPROACH_ARRIVE)

## 叫停一个 NPC 的所有行为（闲逛/服务端指令），退出交互时恢复。
## 正在跟随的记下目标（resume_follow），恢复时继续跟而不是回去闲逛。
func _halt_npc(d: Dictionary) -> void:
	for ex in _executors:
		if (ex as BehaviorExecutor).drives(d):
			var fid := (ex as BehaviorExecutor).following_id()
			if not fid.is_empty():
				d["resume_follow"] = fid
			(ex as BehaviorExecutor).cancel()
	_stopped = d

func _resume_stopped_npc() -> void:
	if not _stopped.is_empty() and not _stopped.get("is_fairy", false) \
			and is_instance_valid(_stopped.get("node")):
		var fid := String(_stopped.get("resume_follow", ""))
		if not fid.is_empty():
			_stopped.erase("resume_follow")
			_run_behavior(_stopped["node"], {
				"commands": [{ "type": "follow", "params": { "target_name": fid } }],
				"loop": false,
			})
		else:
			_start_ambient_wander(_stopped)
	_stopped = {}

## 放弃当前「跑向 NPC」目标（点了别处/换目标），恢复被叫停的对象。
func _clear_approach() -> void:
	if _approach.is_empty():
		return
	_approach = {}
	if selected == null:
		_resume_stopped_npc()

## 每帧检查：玩家跑到目标 NPC 旁了就进近身视图；走不到（路被围死）则恢复对象。
func _check_approach() -> void:
	if _approach.is_empty() or _player_executor == null or not _player_executor.is_done():
		return
	var d := _approach
	_approach = {}
	_player_executor = null
	if not is_instance_valid(d.get("node")):
		_resume_stopped_npc()
		return
	var dist: float = WorldGrid.shortest_delta(player["logical"], d["logical"]).length()
	if dist <= APPROACH_ARRIVE + 0.6:
		_enter_interaction(d["node"])
	else:
		_resume_stopped_npc()

func _enter_interaction(npc: PaperCharacter) -> void:
	selected = npc
	# 面对面：进近身时双方朝向对方（paper_face 由动作层每帧收敛）
	var d := _find_npc_dict(npc)
	if not d.is_empty() and not player.is_empty():
		var dx := WorldGrid.shortest_delta(d["logical"], player["logical"]).x
		d["paper_face"] = 0.0 if dx > 0.0 else PI
		player["paper_face"] = 0.0 if dx <= 0.0 else PI
	# lock：相机平滑切到更低角(3/4)+拉近，聚焦跟随该角色
	_locked = npc
	_target_pitch = LOCK_PITCH_DEG
	_target_dist = LOCK_DIST
	banner.text = "想说什么就直接跟%s说吧" % npc.char_name
	banner.visible = true
	thinking_label.visible = false
	# 开放麦：进近身即聆听——开口就说、说完自动发送，全程无按钮无模式（见 _step_voice）
	_mic.start()
	_vad = VoiceVad.new()
	_unmute_t = 0.0

func _exit_interaction() -> void:
	if _recording:
		_utterance_cancel() # 说到一半退出：静默丢弃，不留半开会话
	_mic.stop()
	_vad = null
	selected = null
	_resume_stopped_npc() # 被叫停等玩家的对象恢复闲逛
	# 切回跟随玩家视角（平滑过渡）
	_locked = null
	_target_pitch = GOD_PITCH_DEG
	_target_dist = GOD_DIST
	banner.visible = false
	heard_label.visible = false
	thinking_label.visible = false

# ── M2 语音交互 ──────────────────────────────────────────────────────────

func _setup_backend() -> void:
	backend = Backend.new()
	backend.name = "Backend"
	add_child(backend)
	backend.connected.connect(_send_world_info) # 每次连上（含重连）上报地点名，喂意图 LLM
	backend.character_response.connect(_on_character_response)
	backend.tts_chunk.connect(_on_tts_chunk)
	# 残余积压由 _drain_tts_stream 排空；generator 不会自己停，标记后播完主动 stop
	# （否则 _tts_player.playing 永真 → 开放麦永久闭麦、小仙子永久闭嘴）
	backend.tts_end.connect(func() -> void: _tts_ending = true)
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
		if _recording:
			_utterance_cancel()

## 在线引导：POST /worlds → 连 WS → 按世界状态生成角色（含小神仙）。离线则保留占位 NPC。
func _bootstrap() -> void:
	_apply_player_sprite() # 档案形象替换占位（并行拉取，不阻塞世界引导）
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
	var is_fairy := bool(c.get("isFairy", false))
	if is_fairy:
		# 小仙子随从：头部大小（时之笛式），无论真图/占位都按 FAIRY_HEIGHT 归一
		npc.pixel_size = FAIRY_HEIGHT / float(tex.get_height())
	elif real:
		# 生成图分辨率高，按高度归一化到约 6 单位，脚底对齐原点
		var h := float(tex.get_height())
		npc.pixel_size = 6.0 / h
		npc.offset = Vector2(0.0, h / 2.0)
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
	var dict := { "node": npc, "logical": logical, "id": cid, "is_fairy": is_fairy }
	if is_fairy:
		dict["hover"] = FAIRY_HOVER # 悬浮随从：不登记占用（飞行不挡路），由 _update_fairy 驱动
	else:
		OccupancyMap.char_register(cid, logical, 2)
	npcs.append(dict)
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

# ── 近身对话开放麦（VAD 自动断句：开口即录、说完即发，零按钮零模式）─────────

## 每帧驱动：角色思考/说话时闭麦（半双工防自听），其余时间把麦克风增量喂 VAD。
func _step_voice(delta: float) -> void:
	if _vad == null:
		return
	var pcm := _mic.drain_pcm16k() # 闭麦期间也持续排空采集缓冲，恢复聆听时不会吃到角色的声音
	if thinking_label.visible or _tts_player.playing \
			or (fairy_voice != null and fairy_voice.is_playing()):
		if _recording:
			_utterance_cancel() # 时序兜底：闭麦瞬间还在录 → 静默丢弃
		_vad.reset()
		_unmute_t = UNMUTE_GRACE # 闭麦刚结束的残响尾音不算开口
		return
	if _unmute_t > 0.0:
		_unmute_t -= delta
		return
	_feed_voice_pcm(pcm)
	if _recording:
		_chunk_accum += delta
		if _chunk_accum >= 0.15:
			_flush_pending_chunk() # 上传与说话重叠，断句时音频已基本传完
			_chunk_accum = 0.0

## VAD 事件驱动。独立函数：headless 测试注入合成 PCM 走同一链路（test_visual_click_move）。
func _feed_voice_pcm(pcm: PackedByteArray) -> void:
	if _vad == null:
		return
	for ev in _vad.feed(pcm):
		match String(ev["type"]):
			"start":
				_utterance_begin(ev["pcm"] as PackedByteArray)
			"speech":
				_pending_pcm.append_array(ev["pcm"] as PackedByteArray)
			"end":
				_utterance_commit()
			"cancel":
				_utterance_cancel()

## 开口：开一个识别会话（路由定格），VAD 给的预录头块先送（首音节不丢）。
func _utterance_begin(head: PackedByteArray) -> void:
	if selected == null or _recording:
		return
	_recording = true
	_pending_pcm = head.duplicate()
	_chunk_accum = 0.0
	# 路由定格：端侧模型就绪 → 本地识别（分片不上传，只送最终文本）；否则服务端流式。
	_local_asr_session = _asr_local != null and _asr_local.isReady()
	if _local_asr_session:
		_asr_local.startSession()
	else:
		backend.send_voice_start(world_id, _selected_id())
	_flush_pending_chunk()

## 说完（静音断句）：残留分片发出，触发识别/回复。
func _utterance_commit() -> void:
	if not _recording:
		return
	_recording = false
	thinking_label.visible = true
	banner.visible = false
	_flush_pending_chunk()
	if _local_asr_session:
		_asr_local.stopSession() # final_result 信号回来后走 voice_transcript
	else:
		backend.send_voice_end()
	_think_timer.start(THINK_TIMEOUT)  # 兜底：响应没回来也会自动解卡

## 太短的误触/中途退出：静默丢弃本段，双 ASR 路径都不产生任何回复。麦克风保持聆听。
func _utterance_cancel() -> void:
	if not _recording:
		return
	_recording = false
	_pending_pcm = PackedByteArray()
	if _local_asr_session:
		_local_asr_session = false # 弃会话即可：插件下次 startSession 会自动释放旧流
	else:
		backend.send_voice_cancel()

func _flush_pending_chunk() -> void:
	if _pending_pcm.size() > 0:
		if _local_asr_session:
			_asr_local.feedPcm(_pending_pcm) # 端侧：原始 PCM 直喂插件，不上传
		else:
			backend.send_voice_chunk(Marshalls.raw_to_base64(_pending_pcm))
		_pending_pcm = PackedByteArray()

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
	if typeof(script) == TYPE_DICTIONARY:
		# 点名指派（performerId）：不隔空遥控——正在对话的角色跑腿到执行者旁把指令带到，
		# 对方点头应答才开始做（见 _relay_command）；没有说话者在场才直接下发。
		var performer := _find_npc_by_id(String(data.get("performerId", "")))
		if performer != null and selected != null and performer != selected:
			_run_behavior(selected, { "commands": [{ "type": "relay_command",
				"params": { "to": String(data.get("performerId", "")), "script": script } }], "loop": false })
		elif performer != null:
			_run_behavior(performer, script)
		elif selected != null:
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
	_tts_ending = false
	_tts_gen_capacity = _tts_gen_playback.get_frames_available() # 刚开播缓冲全空 = 实际容量

func _on_tts_chunk(pcm: PackedByteArray) -> void:
	if _tts_gen_playback != null:
		_tts_stream_pcm.append_array(pcm)
		_drain_tts_stream()

## 把积压 PCM16 按 generator 剩余空位转成帧推入（每帧 Vector2 双声道同值）。
func _drain_tts_stream() -> void:
	if _tts_gen_playback == null:
		return
	if _tts_stream_pcm.size() < 2:
		# tts_end 已到且积压排空：等 generator 缓冲基本播完（剩余 <0.05s）就主动停，
		# playing 才会变 false——开放麦闭麦判定与小仙子闭嘴判定都依赖它。
		if _tts_ending and _tts_gen_playback.get_frames_available() \
				>= _tts_gen_capacity - int((_tts_player.stream as AudioStreamGenerator).mix_rate * 0.05):
			_tts_player.stop()
			_tts_gen_playback = null
			_tts_ending = false
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
	_tts_ending = false
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

## 情绪气泡：大 emoji（3 岁不识字友好）+ 弹出过冲动画，数秒后淡出。
func _show_emotion(emotion: String) -> void:
	var glyphs := { "happy": "😊", "think": "🤔", "wave": "👋", "sad": "🥺" }
	emotion_bubble.text = glyphs.get(emotion, "🎵")
	emotion_bubble.visible = true
	emotion_bubble.modulate = Color.WHITE
	emotion_bubble.scale = Vector3.ONE * 0.4
	_emotion_pop_t = 0.0
	_emotion_life = 4.0

func _update_emotion_bubble(delta: float) -> void:
	if not emotion_bubble.visible:
		return
	if selected == null or not is_instance_valid(selected):
		emotion_bubble.visible = false
		return
	emotion_bubble.global_position = selected.global_position + Vector3(0.0, _char_top(selected) + 1.4, 0.0)
	# 弹出：0.2s 冲到 1.2 过冲，再 0.15s 回落到 1.0
	if _emotion_pop_t >= 0.0:
		_emotion_pop_t += delta
		if _emotion_pop_t < 0.2:
			emotion_bubble.scale = Vector3.ONE * lerpf(0.4, 1.2, _emotion_pop_t / 0.2)
		elif _emotion_pop_t < 0.35:
			emotion_bubble.scale = Vector3.ONE * lerpf(1.2, 1.0, (_emotion_pop_t - 0.2) / 0.15)
		else:
			emotion_bubble.scale = Vector3.ONE
			_emotion_pop_t = -1.0
	# 展示计时：最后 0.5s 淡出后隐藏
	_emotion_life -= delta
	if _emotion_life <= 0.0:
		emotion_bubble.visible = false
	elif _emotion_life < 0.5:
		emotion_bubble.modulate.a = _emotion_life / 0.5

## 思考动画气泡：thinking_label（状态源）可见且有选中角色时，头顶 ·/··/··· 循环冒泡。
func _update_think_bubble(delta: float) -> void:
	var show := thinking_label.visible and selected != null and is_instance_valid(selected)
	_think_bubble.visible = show
	if not show:
		return
	_think_anim_t += delta
	_think_bubble.text = "···".substr(0, 1 + int(_think_anim_t / 0.4) % 3)
	# 轻微上浮呼吸，比静态文本更「活」
	_think_bubble.global_position = selected.global_position \
		+ Vector3(0.0, _char_top(selected) + 1.4 + sin(_think_anim_t * 2.0) * 0.12, 0.0)

## 说话演出：正在出声的角色呼吸弹跳（脚底锚点的纸片挤压拉伸），停止后回正。
## 选中角色吃正式 TTS（_tts_player），小仙子吃预制台词（fairy_voice），其余角色回正。
func _update_speak_anim(delta: float) -> void:
	_speak_anim_t += delta
	var s := 1.0 + sin(_speak_anim_t * 9.0) * 0.05
	var speaking: Array = []
	if selected != null and is_instance_valid(selected) and _tts_player.playing:
		speaking.append(selected)
	var fairy := _find_fairy()
	if not fairy.is_empty() and fairy_voice != null and fairy_voice.is_playing():
		if not speaking.has(fairy["node"]):
			speaking.append(fairy["node"])
	for n in npcs:
		_apply_speak_scale(n["node"], speaking.has(n["node"]), s, delta)

func _apply_speak_scale(node: PaperCharacter, is_speaking: bool, s: float, delta: float) -> void:
	if is_speaking:
		node.scale = Vector3(1.0 / s, s, 1.0) # 变高略变窄：保「体积感」的纸片呼吸
	elif node.scale != Vector3.ONE:
		node.scale = node.scale.lerp(Vector3.ONE, minf(1.0, 12.0 * delta))
		if node.scale.is_equal_approx(Vector3.ONE):
			node.scale = Vector3.ONE

const CHAT_GLYPHS := ["♪", "😊", "✨", "🎵", "😄"]  ## NPC 聊天轮流冒的符号（去文字化）
const CHAT_ROUND := 1.5  ## 一人一轮的秒数

## NPC 间聊天演出：executor 到达聊天对象旁写 chat_with/chat_t 契约键后，这里接管——
## 叫停对方、双方相互面对、轮流头顶冒符号气泡；CHAT_DUR 走完清键、对方恢复闲逛。
func _update_npc_chats(delta: float) -> void:
	var showing := false
	for n in npcs:
		if not n.has("chat_with"):
			continue
		var partner := _find_chat_partner(String(n["chat_with"]), n)
		if partner.is_empty() or not is_instance_valid(n.get("node")):
			_end_npc_chat(n, partner)
			continue
		partner["in_chat"] = true # 拦住 _step_executors 的「跑完恢复闲逛」，聊完才放
		var t := float(n.get("chat_t", 0.0))
		if t == 0.0:
			# 聊天开局：叫停对方，别聊一半人走了
			for ex in _executors:
				if (ex as BehaviorExecutor).drives(partner):
					(ex as BehaviorExecutor).cancel()
		t += delta
		n["chat_t"] = t
		if t >= BehaviorExecutor.CHAT_DUR:
			_end_npc_chat(n, partner)
			continue
		# 相互面对（paper_face 由动作层每帧收敛到位）
		var dx := WorldGrid.shortest_delta(n["logical"], partner["logical"]).x
		n["paper_face"] = 0.0 if dx > 0.0 else PI
		partner["paper_face"] = 0.0 if dx <= 0.0 else PI
		if showing:
			continue # 气泡只演最先找到的一场（多场并发罕见，其余只做面对）
		showing = true
		var round_i := int(t / CHAT_ROUND)
		var speaker: Dictionary = n if round_i % 2 == 0 else partner
		var node := speaker["node"] as PaperCharacter
		_npc_chat_bubble.text = CHAT_GLYPHS[round_i % CHAT_GLYPHS.size()]
		_npc_chat_bubble.visible = true
		_npc_chat_bubble.global_position = node.global_position \
			+ Vector3(0.0, _char_top(node) + 1.4 + sin(t * 3.0) * 0.1, 0.0)
	if not showing:
		_npc_chat_bubble.visible = false

func _find_chat_partner(id: String, exclude: Dictionary) -> Dictionary:
	for n in npcs:
		if n == exclude:
			continue
		if String(n.get("id", "")) == id or (n["node"] as PaperCharacter).char_name == id:
			return n
	return {}

## 聊天收尾：清契约键；被叫停的对方若闲着（无执行器、不在交互中）恢复闲逛。
func _end_npc_chat(n: Dictionary, partner: Dictionary) -> void:
	n.erase("chat_with")
	n.erase("chat_t")
	if partner.is_empty():
		return
	partner.erase("in_chat")
	if not partner.get("is_fairy", false) \
			and not _has_executor_for(partner) and partner != _stopped \
			and (selected == null or partner.get("node") != selected):
		_start_ambient_wander(partner)

## 在角色上执行行为脚本（移动等）。新脚本替换该角色进行中的行为（防双执行器同驱）。
func _run_behavior(npc: PaperCharacter, script: Dictionary) -> void:
	var dict := _find_npc_dict(npc)
	if dict.is_empty():
		return
	if dict.get("is_fairy", false):
		return # 小仙子是随从：永远跟着玩家（_update_fairy），不吃移动类行为脚本
	for old in _executors:
		if (old as BehaviorExecutor).drives(dict):
			(old as BehaviorExecutor).cancel()
	var ex := BehaviorExecutor.new()
	ex.setup(dict, script, Callable(self, "_resolve_char_pos"), Callable(self, "_deliver_message"),
		Callable(self, "_resolve_location"), Callable(self, "_relay_command"))
	_executors.append(ex)

## relay_command 到达回调：跑腿的把指令带到了——执行者先点头应答（收到！），再执行脚本。
func _relay_command(target_id: String, script: Dictionary) -> void:
	var node := _find_npc_by_id(target_id)
	if node == null:
		for n in npcs:
			if (n["node"] as PaperCharacter).char_name == target_id:
				node = n["node"]
				break
	if node == null:
		return
	var cmds: Array = [{ "type": "do_action", "params": { "action": "nod" } }]
	cmds.append_array(script.get("commands", []))
	_run_behavior(node, { "commands": cmds, "loop": bool(script.get("loop", false)) })

## 按 id 或名字找角色逻辑坐标（deliver_message/move_to 角色名/follow 用）；
## 「玩家」/player 解析到玩家角色；找不到返回 Vector2.INF。
func _resolve_char_pos(id: String) -> Vector2:
	if not player.is_empty() \
			and (id == PLAYER_ID or id == "玩家" or id == (player["node"] as PaperCharacter).char_name):
		return player["logical"]
	for n in npcs:
		if String(n.get("id", "")) == id or (n["node"] as PaperCharacter).char_name == id:
			return n["logical"]
	return Vector2.INF

## 地点名 → 世界坐标：先精确匹配 POI 名/别名，再互相包含（「大池塘」↔「池塘」）。找不到 INF。
func _resolve_location(loc: String) -> Vector2:
	var q := loc.strip_edges()
	if q.is_empty():
		return Vector2.INF
	for poi in POIS:
		for n in _poi_names(poi):
			if n == q:
				return Vector2(poi["tile"]) * float(WorldGrid.TILE_SIZE)
	for poi in POIS:
		for n in _poi_names(poi):
			if q.contains(n) or n.contains(q):
				return Vector2(poi["tile"]) * float(WorldGrid.TILE_SIZE)
	return Vector2.INF

func _poi_names(poi: Dictionary) -> Array:
	var names: Array = [String(poi.get("name", ""))]
	names.append_array(poi.get("aliases", []))
	return names.filter(func(n: Variant) -> bool: return not String(n).is_empty())

## 连上 WS 后上报世界地点名清单（POI 规范名），让意图 LLM 把「去某地」归一到真实地名。
func _send_world_info() -> void:
	var names: Array = []
	for poi in POIS:
		names.append(String(poi.get("name", "")))
	backend.send_world_info(world_id, names)

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

func _find_npc_by_id(id: String) -> PaperCharacter:
	if id.is_empty():
		return null
	for n in npcs:
		if String(n.get("id", "")) == id:
			return n["node"]
	return null

func _selected_id() -> String:
	if selected == null:
		return ""
	var d := _find_npc_dict(selected)
	var id := String(d.get("id", ""))
	return id if not id.is_empty() else selected.char_name
