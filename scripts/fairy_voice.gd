class_name FairyVoice
extends Node
## 小仙子预制台词播放器。单一数据源 assets/voice/fairy/lines.json（与
## server/tools/gen_fairy_lines.mjs 共用），按触发器随机选一条未冷却台词播放。
## 运行期零 TTS 调用——音频全部是构建期预制 WAV，离线可用、无 API 成本。

const LINES_PATH := "res://assets/voice/fairy/lines.json"
const VOICE_DIR := "res://assets/voice/fairy"
const GLOBAL_GAP := 8.0 ## 任意两条台词的最小间隔（秒），防连珠炮

var _lines: Array = []          ## [{id, trigger, cooldown, text}]
var _next_ok: Dictionary = {}   ## id -> 可再次播放的时刻（内部时钟秒）
var _global_next_ok := 0.0
var _play_until := 0.0          ## 当前台词按时长应结束的时刻——dummy 音频驱动
                                ## （headless 回测）下 playing 永不落假，用它兜底
var _t := 0.0
var _player: AudioStreamPlayer
var _wav_cache: Dictionary = {}  ## wav 路径 -> AudioStream，避免 load_threaded_get 重复取 + 重播复用

func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)
	var f := FileAccess.open(LINES_PATH, FileAccess.READ)
	if f == null:
		push_warning("fairy lines.json 缺失，预制台词禁用")
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_DICTIONARY:
		_lines = data.get("lines", [])
	# 台词 WAV 后台预加载：触发时（飞近地标等）不再同步 load 卡帧
	for l in _lines:
		ResourceLoader.load_threaded_request("%s/%s.wav" % [VOICE_DIR, String(l["id"])])

## 退出时排空在飞的线程化加载，防 worker mid-load 时进程退出崩溃（见 GameAudio._drain_threaded_loads）。
func _exit_tree() -> void:
	var paths: Array = []
	for l in _lines:
		paths.append("%s/%s.wav" % [VOICE_DIR, String(l["id"])])
	GameAudio._drain_threaded_loads(paths)

func _process(delta: float) -> void:
	_t += delta

func is_playing() -> bool:
	return _player != null and _player.playing and _t < _play_until

## 是否存在 trigger 对应且未冷却的台词（不播，只查——供上层决定要不要飞过去等前置动作）。
func can_play(trigger: String) -> bool:
	if _t < _global_next_ok or is_playing():
		return false
	return not _pool(trigger).is_empty()

## 播一条 trigger 对应、未冷却的台词（多条则随机）。真播了返回 true。
func try_play(trigger: String) -> bool:
	if _t < _global_next_ok or is_playing():
		return false
	var pool := _pool(trigger)
	if pool.is_empty():
		return false
	var line: Dictionary = pool[randi() % pool.size()]
	var wav_path := "%s/%s.wav" % [VOICE_DIR, String(line["id"])]
	var stream: AudioStream = _wav_cache.get(wav_path)
	if stream == null:
		# 后台预加载已就绪则直接取；否则同步兜底（首次触发早于预加载完成的极少数）
		if ResourceLoader.load_threaded_get_status(wav_path) == ResourceLoader.THREAD_LOAD_LOADED:
			stream = ResourceLoader.load_threaded_get(wav_path)
		else:
			stream = load(wav_path)
		if stream != null:
			_wav_cache[wav_path] = stream
	if stream == null:
		push_warning("fairy 台词音频缺失: %s" % line["id"])
		return false
	_next_ok[String(line["id"])] = _t + float(line.get("cooldown", 60.0))
	_global_next_ok = _t + GLOBAL_GAP
	_play_until = _t + stream.get_length()
	_player.stream = stream
	_player.play()
	return true

func _pool(trigger: String) -> Array:
	var pool: Array = []
	for l in _lines:
		if String(l.get("trigger", "")) == trigger \
				and _t >= float(_next_ok.get(String(l["id"]), 0.0)):
			pool.append(l)
	return pool
