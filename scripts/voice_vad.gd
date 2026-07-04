class_name VoiceVad
extends RefCounted
## 语音端点检测（能量 VAD）：16k PCM16 分片流入，按 30ms 帧统计 RMS，输出
## 「开口 / 语音分片 / 说完 / 太短取消」事件流。近身对话免按钮的核心：
## 小朋友开口就说、说完自动发送，无需任何按钮/模式操作。
##
## 纯逻辑、按样本数计时（不碰节点/时钟）——headless 可确定性测试（test_voice_vad.gd）。
##
## 用法：每帧 feed(麦克风增量 PCM)，按序处理返回的事件：
##   { "type": "start", "pcm": … }  开口——pcm 含预录缓冲+触发帧（首音节不丢），先送这段
##   { "type": "speech", "pcm": … } 说话中——继续送增量
##   { "type": "end" }              说完（静音够久且语音够长）——收尾触发识别
##   { "type": "cancel" }           语音太短（噪声/误触）——静默丢弃本段
##
## 阈值参数是桌面初值，真机（幼儿园环境噪声）需实测调参。

const FRAME_MS := 30              ## 能量统计帧长
const BYTES_PER_MS := 32          ## 16k 采样 × 2 字节 / 1000ms
const PREROLL_MS := 300           ## 预录缓冲：判定开口前的这段音频一并上送
const START_MS := 90              ## 连续有声达此时长判定「开口」（3 帧防瞬时咔哒声）
const END_SILENCE_MS := 900       ## 持续静音达此时长判定「说完」
const MIN_SPEECH_MS := 400        ## 有声段短于此视为误触：cancel 而非 end
const MAX_UTTERANCE_MS := 12000   ## 单段封顶（持续背景声兜底）：强制按说完收尾
const MARGIN := 2.5               ## 触发阈值 = 噪声底 × MARGIN
const ABS_MIN := 0.015            ## 触发阈值下限（归一化 RMS），安静环境防呼吸声误触
const END_HYSTERESIS := 0.7       ## 结束判定阈值 = 触发阈值 × 此系数（气口不误断）

var level := 0.0                  ## 最近一帧归一化响度（0..1），供 UI 脉动

var _noise := 0.0                 ## 自适应噪声底（RMS EMA）
var _buf := PackedByteArray()     ## 不足一帧的余量
var _preroll := PackedByteArray() ## 静默期滚动预录
var _pending := PackedByteArray() ## 疑似开口的候审帧（达标随 start 一起发，否则退回预录）
var _speaking := false
var _voiced_ms := 0               ## 静默期：连续有声累计
var _silence_ms := 0              ## 说话期：连续静音累计
var _speech_ms := 0               ## 说话期：本段总时长

## 喂增量 PCM（16k 单声道 PCM16LE，任意长度），返回事件数组（可能为空）。
func feed(pcm: PackedByteArray) -> Array:
	var events: Array = []
	_buf.append_array(pcm)
	var frame_bytes := FRAME_MS * BYTES_PER_MS
	while _buf.size() >= frame_bytes:
		var frame := _buf.slice(0, frame_bytes)
		_buf = _buf.slice(frame_bytes)
		_step_frame(frame, events)
	return events

## 丢弃一切进行中状态（闭麦期间调用；恢复聆听时从干净状态开始）。噪声底保留。
func reset() -> void:
	_buf = PackedByteArray()
	_preroll = PackedByteArray()
	_pending = PackedByteArray()
	_speaking = false
	_voiced_ms = 0
	_silence_ms = 0
	_speech_ms = 0
	level = 0.0

func _step_frame(frame: PackedByteArray, events: Array) -> void:
	var rms := _rms(frame)
	level = clampf(rms * 8.0, 0.0, 1.0)
	# 噪声底自适应：向下快收敛、向上慢爬（说话期几乎冻结，防把人声学成噪声）
	var alpha := 0.1 if rms < _noise else (0.002 if _speaking else 0.02)
	_noise = _noise * (1.0 - alpha) + rms * alpha
	var threshold := clampf(_noise * MARGIN, ABS_MIN, 0.5)
	if _speaking:
		_step_speaking(frame, rms, threshold, events)
	else:
		_step_idle(frame, rms, threshold, events)

func _step_idle(frame: PackedByteArray, rms: float, threshold: float, events: Array) -> void:
	if rms >= threshold:
		_voiced_ms += FRAME_MS
		_pending.append_array(frame)
		if _voiced_ms >= START_MS:
			_speaking = true
			_speech_ms = _voiced_ms
			_silence_ms = 0
			var head := _preroll.duplicate()
			head.append_array(_pending)
			events.append({ "type": "start", "pcm": head })
			_preroll = PackedByteArray()
			_pending = PackedByteArray()
		return
	# 没到开口门槛就归于静默：候审帧退回预录，滚动保留最近 PREROLL_MS
	_voiced_ms = 0
	if _pending.size() > 0:
		_preroll.append_array(_pending)
		_pending = PackedByteArray()
	_preroll.append_array(frame)
	var cap := PREROLL_MS * BYTES_PER_MS
	if _preroll.size() > cap:
		_preroll = _preroll.slice(_preroll.size() - cap)

func _step_speaking(frame: PackedByteArray, rms: float, threshold: float, events: Array) -> void:
	events.append({ "type": "speech", "pcm": frame })
	_speech_ms += FRAME_MS
	if rms >= threshold * END_HYSTERESIS:
		_silence_ms = 0
	else:
		_silence_ms += FRAME_MS
	if _silence_ms >= END_SILENCE_MS or _speech_ms >= MAX_UTTERANCE_MS:
		var voiced := _speech_ms - _silence_ms
		events.append({ "type": "end" if voiced >= MIN_SPEECH_MS else "cancel" })
		_speaking = false
		_voiced_ms = 0
		_silence_ms = 0
		_speech_ms = 0

## 帧 RMS（PCM16LE → 归一化 0..1）。
func _rms(frame: PackedByteArray) -> float:
	var n := frame.size() / 2
	if n == 0:
		return 0.0
	var sum := 0.0
	for i in range(n):
		var v: int = (frame[i * 2 + 1] << 8) | frame[i * 2]
		if v >= 32768:
			v -= 65536
		var s := float(v) / 32768.0
		sum += s * s
	return sqrt(sum / float(n))
