class_name ScriptedAsr
extends RefCounted
## debug-gated 端侧 ASR 替身（docs/voice-e2e-harness-design.md）：不识别音频，
## stopSession() 时吐出预排的队首文本走 final_result——等于「孩子说了预写好的那句」。
## 仅供真机 e2e 注入（VoiceCapture 在 debug 构建 + user://asr_harness 标志时改注它），绝不进 release。
##
## 鸭子类型对齐 MaliangAsr 单例被 VoiceCapture 用到的那几个方法/信号（isReady/startSession/
## stopSession/feedPcm/initialize + final_result/asr_ready/asr_error）——VoiceCapture 一行不用改判类型。

signal final_result(text: String)
signal asr_ready()
signal asr_error(msg: String)

var _queue: Array[String] = []  ## 排队的「孩子会说的话」，每次 stopSession 吐一句
var _ready := false

## 真 MaliangAsr 的 initialize 是异步加载模型；替身即刻就绪，同步发 asr_ready。
func initialize() -> void:
	_ready = true
	asr_ready.emit()

func isReady() -> bool:
	return _ready

func startSession() -> void:
	pass

## 说完（VAD 断句 → VoiceCapture 调 stopSession）：吐队首预排文本。
## 没排任何句 → 空转写，等同真 ASR「没听清」，宿主走既有空结果分支。
func stopSession() -> void:
	var text: String = "" if _queue.is_empty() else String(_queue.pop_front())
	final_result.emit(text)

func feedPcm(_pcm: PackedByteArray) -> void:
	pass

## 排一句「孩子会说的话」，下一次 stopSession 吐出（e2e 脚本的 say 命令用）。
func enqueue(text: String) -> void:
	_queue.append(text)

## 还有几句没吐（供 harness 查询/断言）。
func pending() -> int:
	return _queue.size()
