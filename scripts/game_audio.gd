extends Node
class_name GameAudio
# 背景音乐 + 音效管理器。惯例同 MicRecorder：class_name + 各场景 _ready 里实例化。
# 运行时确保 Music/SFX 两条 bus（幂等，场景切换重进不重复建）。
# BGM 现用 3 首暖色原声曲轮播（happy_boy/carefree/cheery_monday，CC-BY Kevin MacLeod）；录音/思考/TTS 时 duck 压低音乐。
# 双播放器交叉淡化机制：多段时**按各曲实际时长播完整首再交叉淡化**到下一首（非旧的固定 19.2s 切段——
# 那会把完整曲砍成碎片，choppy 且永远播不完）。单段则一直 loop，不轮换。
# 多段起播段号随机（start_bgm 缺省 start_step=-1）：否则永远从最长的第一首(carefree ~204s)打头，
# 孩子一次会话待不满整首就切不到后两首，感知上「总是一首」。随机起播让每次进世界大概率听到不同曲。
# 注意 headless dummy 音频 playing 永真，逻辑状态一律自己记账，不依赖 playing 翻转。

const SFX := {
	# ── 界面音全套「轻柔纸感暖色」（老板反馈原 kenney_interface 手机外放偏硬/刺耳，
	# scroll_001 过场音被听成电流声）。暖调铃音(confirm/oops/bell/task)来自 VCSL/VSCO2 公有领域
	# 乐器采样(CC0)；点击/啵声/滑音来自 Little Robot Sound Factory UI 音库(CC-BY 3.0)。
	# 署名与来源见 assets/audio/soft_ui/CREDITS.txt。──
	"click": "res://assets/audio/soft_ui/click.wav",       # 通用按钮（软点击）
	"select": "res://assets/audio/soft_ui/select.wav",     # 选项选择
	"confirm": "res://assets/audio/soft_ui/confirm.wav",   # 确认成功（暖调 chime）
	"oops": "res://assets/audio/soft_ui/oops.wav",         # 没听清/温和出错（柔和负向）
	"pluck": "res://assets/audio/soft_ui/pluck.wav",       # 点地移动标记
	"pop": "res://assets/audio/soft_ui/pop.wav",           # 情绪气泡弹出（嘴巴“啵”）
	"bell": "res://assets/audio/soft_ui/bell.wav",         # 听到了提示（软铃 ding）
	# 新委托 chip 亮起。不复用 bell：character_response 刚播过 bell，
	# SFX_GAP(80ms) 会把紧随其后的同名音效吞掉。
	"task": "res://assets/audio/soft_ui/task.wav",         # 收到新委托（深铃）
	"enter": "res://assets/audio/soft_ui/enter.wav",       # 进入对话
	"exit": "res://assets/audio/soft_ui/exit.wav",         # 退出对话
	"mic_on": "res://assets/audio/soft_ui/mic_on.wav",     # 开始说话
	"mic_off": "res://assets/audio/soft_ui/mic_off.wav",   # 说完/提交
	"page": "res://assets/audio/soft_ui/page.wav",         # 翻页(纸感)
	"whoosh": "res://assets/audio/soft_ui/whoosh.wav",     # 过场滑动（软滑音，替换刺耳 scroll_001）
	"fanfare": "res://assets/audio/kenney_jingles/jingles_PIZZI07.ogg", # 角色出场欢呼
	"reveal": "res://assets/audio/kenney_jingles/jingles_PIZZI03.ogg",  # 形象揭晓
	# 集邮册盖章那一记木槌闷响（CC0 Kenney Impact Sounds）。全套音效里原本一记撞击声都没有——
	# 「狠狠打上一个章」全靠它，别拿 click/confirm 那种脆响凑合。
	"thunk": "res://assets/audio/kenney_impact/impactWood_medium_000.ogg",
	"bloom": "res://assets/audio/kenney_jingles/jingles_PIZZI01.ogg", # 三章种出一朵小红花
}
const BGM_STEPS := [
	"res://assets/audio/bgm/bgm_carefree.wav",       # 尤克里里+口哨，阳光轻快（~204s，菜单也垫这首）
	"res://assets/audio/bgm/bgm_cheery_monday.wav",  # 明快俏皮（~78s）
	"res://assets/audio/bgm/bgm_happy_boy.wav",      # 暖调收尾主题（~52s）
]

const SFX_POOL := 4
const SFX_GAP := 0.08          # 同名音效最小间隔，防连点刷屏
const MUSIC_DB := -14.0        # 音乐常态音量：垫在语音下面
const SFX_DB := -6.0
const DUCK_DB := -12.0         # duck 时在常态上再压这么多
const MUTE_DB := -80.0         # 静音(录音时)：等效关掉，防外放 BGM 回灌麦克风把 VAD 顶到 12s
const DUCK_LERP := 6.0         # duck 渐变速率(每秒 dB 权重)
const SECTION_SECS := 19.2     # 多段轮换的最短段时长下限（曲子比这短才用它兜底；正常按整首时长播完再切）
const CROSSFADE_SECS := 1.2

var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_streams := {}         # path -> AudioStream 缓存
var _sfx_last := {}            # name -> 距上次播放累计秒
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _steps: Array = []         # 当前 BGM 段列表(AudioStream)
var _bgm_want: Array = []       # 待线程加载的 BGM 段路径(全部就绪才起播)；空=无待加载
var _bgm_start := -1           # 起播段号：-1=随机(见文件头)；>=0=指定(测试用，确定性)
var step_index := -1           # 当前段序号(-1=未播)
var _active_is_a := true       # 正在出声的是 a 还是 b
var _section_left := 0.0       # 距下次换段剩余秒
var _fade_left := 0.0          # 交叉淡化剩余秒
var ducked := false
var muted := false             # 录音期静音 BGM（盖过 duck），录完恢复
var _sfx_bleed_left := 0.0     # 自播音效还会响多久(秒)；开麦逻辑据此屏蔽 VAD，见 sfx_bleeding()

## 自播音效是否仍在出声。开麦期间必须据此屏蔽 VAD——平板无 AEC，外放音效会被自己的
## 麦克风收回去，被听成「孩子开口」（enter=212ms、bell=123ms，都长过 VAD 的 START_MS=90ms）。
## SFX 常态 -6dB，比已被真机 logcat 实证能顶开 VAD 的 BGM(-14dB) 还响 8dB。
## 自己记账而非查 _sfx_players[].playing：headless dummy 音频 playing 永真（见文件头）。
func sfx_bleeding() -> bool:
	return _sfx_bleed_left > 0.0

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
	# SFX 后台预加载：启动即在 worker 线程请求所有音效，首次交互前基本已就绪，
	# 避免首播时同步 load + Ogg 解码卡帧（play_sfx 未就绪时同步兜底，极少见）。
	for path in SFX.values():
		ResourceLoader.load_threaded_request(path)

## 退出时排空所有在飞的线程化加载。worker 线程 mid-load 时进程退出，引擎 teardown 释放
## ResourceLoader 内部状态会 use-after-free 崩溃（headless 短测 quit() 抢在预热完成前，
## 实测 ~4% SIGSEGV，栈在 ResourceLoader::_run_load_task）。load_threaded_get 阻塞到该项加载
## 完成、把请求消费掉；排空后 worker 池无在飞任务，teardown 不再竞态。幂等：已消费的 status 非
## IN_PROGRESS/LOADED，跳过。
func _exit_tree() -> void:
	var paths: Array = SFX.values()
	paths.append_array(_bgm_want)
	_drain_threaded_loads(paths)

## 排空一批线程化加载请求（供退出兜底用）。只 get 仍在飞/已就绪未取的，避免对已消费项重复 get。
static func _drain_threaded_loads(paths: Array) -> void:
	for path in paths:
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS or st == ResourceLoader.THREAD_LOAD_LOADED:
			ResourceLoader.load_threaded_get(path)

func play_sfx(sfx_name: String) -> bool:
	if not SFX.has(sfx_name):
		push_warning("GameAudio: 未知音效 %s" % sfx_name)
		return false
	if _sfx_last.has(sfx_name) and _sfx_last[sfx_name] < SFX_GAP:
		return false
	var path: String = SFX[sfx_name]
	if not _sfx_streams.has(path):
		# 后台预加载已就绪则直接取（无阻塞）；否则同步兜底（首帧内抢播的极少数）
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
			_sfx_streams[path] = ResourceLoader.load_threaded_get(path)
		else:
			_sfx_streams[path] = load(path)
	var player := _pick_sfx_player()
	var stream: AudioStream = _sfx_streams[path]
	player.stream = stream
	player.pitch_scale = randf_range(0.96, 1.04)
	player.play()
	_sfx_last[sfx_name] = 0.0
	# 记账这条音效还会外放多久：开麦逻辑靠它屏蔽 VAD（sfx_bleeding）。
	# pitch_scale 最低 0.96 会把音效拉长，按最坏情况折算，宁可多屏蔽几毫秒。
	_sfx_bleed_left = maxf(_sfx_bleed_left, stream.get_length() / 0.96)
	return true

func _pick_sfx_player() -> AudioStreamPlayer:
	for p in _sfx_players:
		if not p.playing:
			return p
	return _sfx_players[0]

# steps 传 BGM_STEPS 切片；单段就一直 loop，多段按 SECTION_SECS 轮换交叉淡化。
# start_step<0 时随机选起播段（见文件头）；>=0 时从指定段起播（测试用，确定性）。
# 线程加载：请求所有段在 worker 线程加载，全部就绪后由 _poll_bgm_load 起播——
# 菜单 _ready 起播 68s BGM WAV 不再同步卡帧（此前 ~68s WAV 同步 load 是入场一跳）。
func start_bgm(step_paths: Array = BGM_STEPS, start_step: int = -1) -> void:
	stop_bgm()
	_bgm_want = step_paths.duplicate()
	_bgm_start = start_step
	for path in _bgm_want:
		ResourceLoader.load_threaded_request(path)

## BGM 段线程加载轮询：全部就绪才组装 _steps 并起播（生产单段=等这一条 WAV）。
func _poll_bgm_load() -> void:
	if _bgm_want.is_empty():
		return
	for path in _bgm_want:
		match ResourceLoader.load_threaded_get_status(path):
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				return  # 还有段在加载，整体等齐
			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				push_warning("GameAudio: BGM 线程加载失败 %s" % path)
				_bgm_want.clear()
				return
	# 全部 LOADED
	_steps.clear()
	for path in _bgm_want:
		_steps.append(ResourceLoader.load_threaded_get(path))
	_bgm_want.clear()
	if _steps.is_empty():
		return
	# 起播段：指定则用指定(取模防越界)，否则随机——避免永远从第一首打头（见文件头）
	step_index = (_bgm_start % _steps.size()) if _bgm_start >= 0 else (randi() % _steps.size())
	_active_is_a = true
	_section_left = _step_secs(step_index)
	_fade_left = 0.0
	_music_a.stream = _steps[step_index]
	_music_a.volume_db = MUSIC_DB + (DUCK_DB if ducked else 0.0)
	_music_a.play()

func stop_bgm() -> void:
	step_index = -1
	_steps.clear()
	_bgm_want.clear()
	_music_a.stop()
	_music_b.stop()

func set_ducked(on: bool) -> void:
	ducked = on

## 录音期静音 BGM（盖过 duck）：断掉外放回灌，让 VAD 能听到「说完后的真静音」。
func set_music_muted(on: bool) -> void:
	muted = on

func _process(delta: float) -> void:
	_advance(delta)

# 拆出来供 headless 测试直接推进虚拟时间
func _advance(delta: float) -> void:
	_poll_bgm_load()  # BGM 段线程加载就绪则起播（不阻塞）
	_sfx_bleed_left = maxf(_sfx_bleed_left - delta, 0.0)
	for key in _sfx_last:
		_sfx_last[key] += delta
	if step_index < 0:
		return
	if _steps.size() > 1:
		_section_left -= delta
		if _section_left <= 0.0:
			_begin_crossfade()
	var target := MUTE_DB if muted else MUSIC_DB + (DUCK_DB if ducked else 0.0)
	var active := _music_a if _active_is_a else _music_b
	var fading := _music_b if _active_is_a else _music_a
	if _fade_left > 0.0:
		_fade_left = maxf(_fade_left - delta, 0.0)
		var t := 1.0 - _fade_left / CROSSFADE_SECS
		active.volume_db = lerpf(-40.0, target, t)
		fading.volume_db = lerpf(target, -40.0, t)
		if _fade_left == 0.0:
			fading.stop()
	elif not is_equal_approx(active.volume_db, target):
		# 已在目标音量就不再逐帧写 volume_db（每次赋值都触达 AudioServer）
		active.volume_db = target if absf(active.volume_db - target) < 0.05 \
				else lerpf(active.volume_db, target, minf(delta * DUCK_LERP, 1.0))

# 当前段应播多久后轮换：整首时长，短于下限则用 SECTION_SECS 兜底（避免过短曲频繁切换）。
func _step_secs(i: int) -> float:
	return maxf(_steps[i].get_length(), SECTION_SECS)

func _begin_crossfade() -> void:
	step_index = (step_index + 1) % _steps.size()
	_section_left += _step_secs(step_index)
	_fade_left = CROSSFADE_SECS
	_active_is_a = not _active_is_a
	var incoming := _music_a if _active_is_a else _music_b
	incoming.stream = _steps[step_index]
	incoming.volume_db = -40.0
	incoming.play()
