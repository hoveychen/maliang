extends Node
class_name GameAudio
# 背景音乐 + 音效管理器。惯例同 MicRecorder：class_name + 各场景 _ready 里实例化。
# 运行时确保 Music/SFX 两条 bus（幂等，场景切换重进不重复建）。
# BGM 现用单条长 loop（bgm_main.wav ~68s 连续曲，导入开 loop 无缝循环）；录音/思考/TTS 时 duck 压低音乐。
# 双播放器交叉淡化机制保留：传入多条 step 会按 SECTION_SECS 轮换串接，但生产只喂单条 → 不轮换、纯 loop。
# 注意 headless dummy 音频 playing 永真，逻辑状态一律自己记账，不依赖 playing 翻转。

const SFX := {
	"click": "res://assets/audio/kenney_interface/click_002.ogg",       # 通用按钮
	"select": "res://assets/audio/kenney_interface/select_001.ogg",     # 选项选择
	"confirm": "res://assets/audio/kenney_interface/confirmation_001.ogg", # 确认成功
	"oops": "res://assets/audio/kenney_interface/question_001.ogg",     # 没听清/温和出错
	"pluck": "res://assets/audio/kenney_interface/pluck_001.ogg",       # 点地移动标记
	"pop": "res://assets/audio/kenney_interface/drop_002.ogg",          # 情绪气泡弹出
	"bell": "res://assets/audio/kenney_interface/bong_001.ogg",         # 听到了提示
	"enter": "res://assets/audio/kenney_interface/maximize_003.ogg",    # 进入对话
	"exit": "res://assets/audio/kenney_interface/minimize_003.ogg",     # 退出对话
	"mic_on": "res://assets/audio/kenney_interface/toggle_001.ogg",     # 开始说话
	"mic_off": "res://assets/audio/kenney_interface/switch_002.ogg",    # 说完/提交
	"page": "res://assets/audio/kenney_interface/scratch_001.ogg",      # 翻页(纸感)
	"whoosh": "res://assets/audio/kenney_interface/scroll_001.ogg",     # 过场滑动
	"fanfare": "res://assets/audio/kenney_jingles/jingles_PIZZI07.ogg", # 角色出场欢呼
	"reveal": "res://assets/audio/kenney_jingles/jingles_PIZZI03.ogg",  # 形象揭晓
}
const BGM_STEPS := [
	"res://assets/audio/bgm/bgm_main.wav", # 单条 ~68s 连续曲，原地无缝 loop（不再三段轮换）
]

const SFX_POOL := 4
const SFX_GAP := 0.08          # 同名音效最小间隔，防连点刷屏
const MUSIC_DB := -14.0        # 音乐常态音量：垫在语音下面
const SFX_DB := -6.0
const DUCK_DB := -12.0         # duck 时在常态上再压这么多
const DUCK_LERP := 6.0         # duck 渐变速率(每秒 dB 权重)
const SECTION_SECS := 19.2     # 多段模式下每段播这么久后轮换（单条模式不生效）
const CROSSFADE_SECS := 1.2

var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_streams := {}         # path -> AudioStream 缓存
var _sfx_last := {}            # name -> 距上次播放累计秒
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _steps: Array = []         # 当前 BGM 段列表(AudioStream)
var step_index := -1           # 当前段序号(-1=未播)
var _active_is_a := true       # 正在出声的是 a 还是 b
var _section_left := 0.0       # 距下次换段剩余秒
var _fade_left := 0.0          # 交叉淡化剩余秒
var ducked := false

static func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) == -1:
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)

func _ready() -> void:
	_ensure_bus("Music")
	_ensure_bus("SFX")
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		p.volume_db = SFX_DB
		add_child(p)
		_sfx_players.append(p)
	_music_a = AudioStreamPlayer.new()
	_music_b = AudioStreamPlayer.new()
	for p in [_music_a, _music_b]:
		p.bus = "Music"
		p.volume_db = -60.0
		add_child(p)

func play_sfx(sfx_name: String) -> bool:
	if not SFX.has(sfx_name):
		push_warning("GameAudio: 未知音效 %s" % sfx_name)
		return false
	if _sfx_last.has(sfx_name) and _sfx_last[sfx_name] < SFX_GAP:
		return false
	var path: String = SFX[sfx_name]
	if not _sfx_streams.has(path):
		_sfx_streams[path] = load(path)
	var player := _pick_sfx_player()
	player.stream = _sfx_streams[path]
	player.pitch_scale = randf_range(0.96, 1.04)
	player.play()
	_sfx_last[sfx_name] = 0.0
	return true

func _pick_sfx_player() -> AudioStreamPlayer:
	for p in _sfx_players:
		if not p.playing:
			return p
	return _sfx_players[0]

# steps 传 BGM_STEPS 切片；单段就一直 loop，多段按 SECTION_SECS 轮换交叉淡化
func start_bgm(step_paths: Array = BGM_STEPS) -> void:
	_steps.clear()
	for path in step_paths:
		_steps.append(load(path))
	if _steps.is_empty():
		return
	step_index = 0
	_active_is_a = true
	_section_left = SECTION_SECS
	_fade_left = 0.0
	_music_a.stream = _steps[0]
	_music_a.volume_db = MUSIC_DB + (DUCK_DB if ducked else 0.0)
	_music_a.play()

func stop_bgm() -> void:
	step_index = -1
	_steps.clear()
	_music_a.stop()
	_music_b.stop()

func set_ducked(on: bool) -> void:
	ducked = on

func _process(delta: float) -> void:
	_advance(delta)

# 拆出来供 headless 测试直接推进虚拟时间
func _advance(delta: float) -> void:
	for key in _sfx_last:
		_sfx_last[key] += delta
	if step_index < 0:
		return
	if _steps.size() > 1:
		_section_left -= delta
		if _section_left <= 0.0:
			_begin_crossfade()
	var target := MUSIC_DB + (DUCK_DB if ducked else 0.0)
	var active := _music_a if _active_is_a else _music_b
	var fading := _music_b if _active_is_a else _music_a
	if _fade_left > 0.0:
		_fade_left = maxf(_fade_left - delta, 0.0)
		var t := 1.0 - _fade_left / CROSSFADE_SECS
		active.volume_db = lerpf(-40.0, target, t)
		fading.volume_db = lerpf(target, -40.0, t)
		if _fade_left == 0.0:
			fading.stop()
	else:
		active.volume_db = lerpf(active.volume_db, target, minf(delta * DUCK_LERP, 1.0))

func _begin_crossfade() -> void:
	step_index = (step_index + 1) % _steps.size()
	_section_left += SECTION_SECS
	_fade_left = CROSSFADE_SECS
	_active_is_a = not _active_is_a
	var incoming := _music_a if _active_is_a else _music_b
	incoming.stream = _steps[step_index]
	incoming.volume_db = -40.0
	incoming.play()
