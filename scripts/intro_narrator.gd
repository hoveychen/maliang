class_name IntroNarrator
extends Node
## intro 建造演出的顺序旁白播放器（P4）。与 FairyVoice 的区别：FairyVoice 是「触发器随机池 +
## 冷却」用于运行期环境语音；本类是「按 id 顺序播、可 await 时长」用于一段被编排好的开场演出。
## 数据源 assets/voice/intro/lines.json（同 gen_voice_lines.mjs 管线，仙子音色 zh-CN-XiaoyiNeural）。
## 运行期零 TTS 调用——音频全是构建期预制 WAV，离线可用、无 API 成本。
##
## 用法：IntroDirector 建一个挂到自己身上，play(id) 返回时长秒，调用方 await 该时长推进下一段。

const LINES_PATH := "res://assets/voice/intro/lines.json"
const VOICE_DIR := "res://assets/voice/intro"

var _lines: Dictionary = {}     ## id -> text（供调试/字幕；播放只需 id → WAV 路径）
var _play_until := 0.0          ## 当前旁白按时长应结束的时刻——dummy 音频（headless）下 playing 永真，用它兜底
var _t := 0.0
var _player: AudioStreamPlayer
var _wav_cache: Dictionary = {} ## wav 路径 -> AudioStream，避免重复 load + 重播复用

func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)
	var f := FileAccess.open(LINES_PATH, FileAccess.READ)
	if f == null:
		push_warning("intro lines.json 缺失，建造演出旁白禁用")
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_DICTIONARY:
		for l in (data.get("lines", []) as Array):
			_lines[String(l["id"])] = String(l.get("text", ""))
			# 后台预加载：演出推进时不再同步 load 卡帧
			ResourceLoader.load_threaded_request("%s/%s.wav" % [VOICE_DIR, String(l["id"])])

func _process(delta: float) -> void:
	_t += delta

func has_line(id: String) -> bool:
	return _lines.has(id)

func text(id: String) -> String:
	return String(_lines.get(id, ""))

func is_playing() -> bool:
	return _player != null and _player.playing and _t < _play_until

## 播一条旁白（按 id），返回其时长秒；id 缺失/音频缺失返回 0（调用方 await 0 即立即推进）。
func play(id: String) -> float:
	if _player == null:
		return 0.0
	var wav_path := "%s/%s.wav" % [VOICE_DIR, id]
	var stream: AudioStream = _wav_cache.get(wav_path)
	if stream == null:
		if ResourceLoader.load_threaded_get_status(wav_path) == ResourceLoader.THREAD_LOAD_LOADED:
			stream = ResourceLoader.load_threaded_get(wav_path)
		elif ResourceLoader.exists(wav_path):
			stream = load(wav_path)
		if stream != null:
			_wav_cache[wav_path] = stream
	if stream == null:
		push_warning("intro 旁白音频缺失: %s" % id)
		return 0.0
	var dur := stream.get_length()
	_play_until = _t + dur
	_player.stream = stream
	_player.play()
	return dur

func stop() -> void:
	if _player != null:
		_player.stop()
	_play_until = _t
