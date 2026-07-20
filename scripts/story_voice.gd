class_name StoryVoice
extends Node
## M2 故事音包（docs/m2-story-director-design.md §4.3）：章回剧本台词的预烧 WAV 播放器。
## stage_say/narrate 的文本【精确命中】lines.json 即播对应 WAV（零 TTS、脱网可演、音质稳定，
## 各角色音色在烧制时已定）；miss 由调用方回落 clientTts 现场合成——风险面收敛为这一条路径。
## 骨架照 FairyVoice：线程化预载 + 退出排空（防 mid-load 退出崩溃）+ headless 时长兜底。

## 预烧音包根目录：其下每一册占一个 `story_<册 id>` 子目录（约定同服务端 storyVoiceDir）。
const VOICE_ROOT := "res://assets/voice"

var _by_text: Dictionary = {}   ## 台词文本 -> wav 路径（跨册合并到同一索引）
var _play_until := 0.0          ## headless dummy 音频 playing 永真，按时长兜底判说完
var _t := 0.0
var _player: AudioStreamPlayer
var _cache: Dictionary = {}     ## wav 路径 -> AudioStream（重播复用）

func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)
	# 遍历所有册目录，各自 lines.json 合并进同一 _by_text——加一册零改此文件。
	for voice_dir in _story_voice_dirs():
		_index_pack(voice_dir)

## 扫 res://assets/voice/ 下所有 `story_*` 册目录（DirAccess 列子目录；导出包里目录树在 PCK 中保留，
## 参照 menu.gd album_paths 的 DirAccess-over-PCK 先例）。
func _story_voice_dirs() -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(VOICE_ROOT)
	if d == null:
		return out
	for sub in d.get_directories():
		if sub.begins_with("story_"):
			out.append("%s/%s" % [VOICE_ROOT, sub])
	out.sort()
	return out

## 把一册的 lines.json 索引进 _by_text 并发起线程化预载（跨册合并；miss 由调用方回落 clientTts）。
func _index_pack(voice_dir: String) -> void:
	var f := FileAccess.open("%s/lines.json" % voice_dir, FileAccess.READ)
	if f == null:
		return # 该册音包缺失＝其台词全 miss 回落，不拦演出
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		return
	for l in data.get("lines", []):
		var path := "%s/%s.wav" % [voice_dir, String(l["id"])]
		_by_text[String(l["text"])] = path
		ResourceLoader.load_threaded_request(path)

## 退出时排空在飞的线程化加载，防 worker mid-load 时进程退出崩溃（见 GameAudio._drain_threaded_loads）。
func _exit_tree() -> void:
	GameAudio._drain_threaded_loads(_by_text.values())

func _process(delta: float) -> void:
	_t += delta

func has_line(text: String) -> bool:
	return _by_text.has(text)

func is_playing() -> bool:
	return _player != null and _player.playing and _t < _play_until

## 命中则播（舞台台词串行，新条自然顶掉上一条）。返回是否命中。
func play_line(text: String) -> bool:
	var path := String(_by_text.get(text, ""))
	if path.is_empty():
		return false
	var stream: AudioStream = _cache.get(path)
	if stream == null:
		if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			stream = ResourceLoader.load_threaded_get(path)
		else:
			stream = load(path)
		if stream == null:
			return false
		_cache[path] = stream
	_player.stream = stream
	_player.play()
	_play_until = _t + maxf(stream.get_length(), 0.5)
	return true
