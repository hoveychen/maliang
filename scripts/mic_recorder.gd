class_name MicRecorder
extends Node
## 麦克风采集：静音录音总线 + AudioEffectCapture，drain 出 16k PCM16 分片。
## world.gd（流式对话）与 onboarding（整段自我介绍）共用同一采集实现。

var _capture: AudioEffectCapture
var _mic_player: AudioStreamPlayer
var _rec_rate := 44100

func _ready() -> void:
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "Record%d" % idx) # 每实例独立总线，菜单/世界场景互不干扰
	AudioServer.set_bus_mute(idx, true)
	_capture = AudioEffectCapture.new()
	AudioServer.add_bus_effect(idx, _capture)
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = AudioServer.get_bus_name(idx)
	add_child(_mic_player)
	_rec_rate = int(AudioServer.get_mix_rate())

func start() -> void:
	if _capture != null:
		_capture.clear_buffer()
	if _mic_player != null and not _mic_player.playing:
		_mic_player.play()

func stop() -> void:
	if _mic_player != null:
		_mic_player.stop()

## 读采集缓冲 → 单声道 + 线性重采样到 16k 16bit PCM 字节（自上次 drain 以来的增量）。
func drain_pcm16k() -> PackedByteArray:
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
