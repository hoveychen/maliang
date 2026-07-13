class_name VoiceCapture
extends Node
## 开放麦编排：把 MicRecorder + VoiceVad + 端侧 ASR + 自听防护 + BGM 门控 这套
## 「旁白/角色说完 → 开麦 → VAD 断句 → 端侧识别」的编排循环收敛到一处。
## 此前 world.gd 与 onboarding.gd 各手抄一份，口径漂移（BGM 静音只在 world 修对，onboarding
## 漏了开麦等待窗），本模块是单一真相。设计见 docs/voice-capture-module-design.md。
##
## 识别只有端侧一条路（服务端 ASR 于 2026-07-13 整条退役）：PCM 直喂 MaliangAsr 插件，
## 出 local_final 文本；音频永远不离开设备。
##
## 宿主用法（像 GameAudio 一样 add_child）：
##   var vc := VoiceCapture.new(); vc.game_audio = game_audio; add_child(vc)
##   vc.should_capture = func() -> bool: return <该不该喂麦（宿主门禁：思考/说话/退避/就绪…）>
##   vc.is_speaking   = func() -> bool: return <此刻有没有角色/旁白在出声（BGM 让位判据）>
##   vc.open()   # 进对话 / 旁白说完进入聆听窗
##   vc.close()  # 退对话 / 提交后
##   # 宿主 _process 每帧： vc.step(delta)
## 并接 local_final 决定转写去向（world=送对话/喊话中继，onboarding=提名字）。
##
## 分工：本模块吃「机械核」——单例接线、就绪门禁、mic drain+VAD、自听防护(unmute_grace+
## sfx_bleeding)、分片、端侧会话生命周期、VAD 事件分发、**set_music_muted 门控**。
## 宿主留「业务策略」——sink（信号）、开麦门禁（should_capture）、以及 set_ducked（音量微降，
## 各宿主口径不同且非 ASR 关键，故不并入，避免改动 world 既有行为）。

## VAD 判定开口：宿主亮录音态 UI、起耗时打点。
signal utterance_begin()
## 端侧识别出最终文本（唯一终局）。宿主判空/退避/中继/送对话。
## 本机没有可用端侧 ASR 时（editor/headless 缺模型）此信号根本不会来——不伪造空转写。
signal local_final(text: String)
## 说完（静音断句/硬顶）：残片已 flush，正在等识别结果。宿主亮思考/收尾 UI。
signal committed()
## 太短的误触 / 中途闭麦：静默丢弃本段，不产生转写。
signal cancelled()
## 确认模式专有：识别成功、录音正在回放，等宿主亮确认条并调 accept()/retry()。
## 此刻 committed/local_final 都还没发——说完不等于采纳（见 confirm_mode）。
signal confirm_ready(text: String)
## 端侧模型异步加载完成（宿主用于日志/状态图标）。名不用 ready：与 Node 内置信号撞名。
signal asr_ready

const UNMUTE_GRACE := 0.3         ## 旁白/音效结束后的静默恢复期：残响尾音不算开口（同旧两处）
const CHUNK_FLUSH_SECS := 0.15    ## 分片喂 ASR 的节奏：不每帧碎喂
const MIC_RATE := 16000           ## 麦克风/回放采样率（MicRecorder 出 16k PCM16 单声道）

## ── 宿主注入的策略 ──────────────────────────────────────────────────────────
var game_audio: GameAudio = null                       ## BGM 门控 + mic 音效；可为 null（测试）
var should_capture: Callable = func() -> bool: return false  ## 每帧门禁：该不该把麦喂 VAD
var is_speaking: Callable = func() -> bool: return false      ## 此刻有无人声在放（BGM 让位）
var os_name := OS.get_name()                           ## 平台名（headless 测试可覆盖成 "Android"）
## 确认模式（小龄玩家）：识别成功后先把刚录的话回放一遍，等孩子按「就是这样」才算数。
## 开时 committed/local_final 都推迟到 accept()——说完不等于采纳，宿主逻辑无需改动。
## 识别失败（空转写）不进确认：那本来就要重说，直接走宿主既有的「没听清」分支。
var confirm_mode := false
var debug_log := false                                 ## 录音诊断 logcat（仅 debug）：VAD 收尾原因/阈值/静音累计

## ── 内部状态 ───────────────────────────────────────────────────────────────
var _mic: MicRecorder = null
var _asr: Object = null            ## 端侧 ASR（MaliangAsr 单例）；null=本机无可用端侧识别
var _vad: VoiceVad = null          ## 开麦期间非 null（close 置空）
var _open := false                 ## 聆听窗是否打开（open→close 之间；BGM 静音据此）
var _recording := false            ## VAD 已判定开口、正在收录一段
var _asr_session := false          ## 本段是否已开端侧识别会话（begin 定格；无 ASR 时为假）
var _pending_pcm := PackedByteArray()  ## 未 flush 的分片（攒够 150ms 再喂/发）
var _chunk_accum := 0.0            ## 分片计时
var _unmute_t := 0.0               ## 闭麦恢复期剩余秒数
var _dbg_accum := 0.0              ## 录音期 debug 打点节流（每 1s 一行）
## ── 确认模式状态 ──
var _utt_pcm := PackedByteArray()  ## 本段完整录音（仅 confirm_mode 累积，用于回放）
var _confirming := false           ## 等孩子确认中：VAD 全程屏蔽（回放声不能被自己的麦听成开口）
var _confirm_text := ""            ## 待确认的转写（accept 时才发给宿主）
var _player: AudioStreamPlayer = null ## 录音回放（模块自持：宿主不必知道回放这回事）

func _ready() -> void:
	if _mic == null:
		_mic = MicRecorder.new()
		_mic.name = "MicRecorder"
		add_child(_mic)
	if _player == null:
		_player = AudioStreamPlayer.new()
		_player.name = "ConfirmPlayback"
		_player.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
		add_child(_player)
	if _asr == null: # 测试可预注入 fake，跳过单例接线
		_setup_local_asr()

## 端侧 ASR（MaliangAsr 单例，Android 插件 / macOS GDExtension）：有则异步加载模型。
## editor/headless 从源码跑时单例在、但模型不随包（除非 MALIANG_ASR_MODEL_DIR 指路），
## initialize() 会 asr_error → _asr 置空 = 本机无识别（语音不工作但不崩，见 _on_local_error）。
func _setup_local_asr() -> void:
	if not Engine.has_singleton("MaliangAsr"):
		# Android/导出 macOS 没有单例 = 导出漏带端侧 ASR（坏包），硬报错拒进游戏。
		if AsrGuard.is_fatal(os_name, false, OS.has_feature("template")):
			AsrGuard.block(get_tree(), AsrGuard.MSG_MISSING)
		return
	_asr = Engine.get_singleton("MaliangAsr")
	_asr.connect("final_result", _on_local_final)
	_asr.connect("asr_ready", _on_local_ready)
	_asr.connect("asr_error", _on_local_error)
	_asr.initialize()

func _exit_tree() -> void:
	# 场景切走：关麦 + 断插件信号，别留开着的麦 / 未关的本地会话到节点释放为止。
	close()
	# _asr 可能是真单例（有这些信号）、null、或测试注入的 fake（无信号）——has_signal 先挡。
	if _asr != null:
		for pair in [["final_result", _on_local_final], ["asr_ready", _on_local_ready], ["asr_error", _on_local_error]]:
			var sig := String(pair[0])
			var cb := pair[1] as Callable
			if _asr.has_signal(sig) and _asr.is_connected(sig, cb):
				_asr.disconnect(sig, cb)

# ── 查询 ────────────────────────────────────────────────────────────────────

## 端侧 ASR 是否可用于本次 utterance。Android 未就绪即禁止开麦（没有服务端可回落）。
func is_ready() -> bool:
	return _asr != null and _asr.isReady()

func is_recording() -> bool:
	return _recording

## 是否处于聆听窗（open→close 之间）——宿主构图/门禁可用。
func is_open() -> bool:
	return _open

## 最近一帧归一化响度（供声波条 UI）。
func level() -> float:
	return _vad.level if _vad != null else 0.0

## 端侧模型未就绪、Android 上必须等（不开麦；没有服务端识别可回落）。宿主 should_capture 可复用。
func must_wait_for_ready() -> bool:
	return AsrGuard.must_wait_for_ready(os_name, is_ready(), OS.has_feature("template"))

# ── 开麦 / 关麦 ─────────────────────────────────────────────────────────────

## 进对话 / 旁白说完进入聆听窗：起麦 + 新建 VAD。幂等。
func open() -> void:
	if _open:
		return
	_open = true
	if _mic != null:
		_mic.start()
	_vad = VoiceVad.new()
	_unmute_t = 0.0

## 退对话 / 提交后：录音中先静默取消，停麦 + 弃 VAD。幂等。
func close() -> void:
	if not _open:
		return
	if _recording:
		_cancel_utterance()
	if _confirming:
		_end_confirm() # 退对话时还挂着确认条：本段作废（宿主收不到 committed/local_final）
	if _mic != null:
		_mic.stop()
	_vad = null
	_open = false

# ── 每帧驱动 ────────────────────────────────────────────────────────────────

## 宿主每帧调用。BGM 门控无条件先跑（即便闭麦也要保证静音口径），随后按门禁喂 VAD。
func step(delta: float) -> void:
	_update_bgm()
	if _vad == null:
		return
	var pcm := _mic.drain_pcm16k() if _mic != null else PackedByteArray()
	# 等确认期间（含回放）：麦照排空但一律不喂 VAD。回放的是孩子自己的声音，
	# 无 AEC 的麦会原样收回去被听成「又开口了」——那会在确认条还亮着时套娃出新一段。
	if _confirming:
		_vad.reset()
		_unmute_t = UNMUTE_GRACE # 回放尾音不算开口
		return
	# 闭麦期间也持续排空采集缓冲，恢复聆听时不会吃到角色/旁白的声音。
	if not should_capture.call():
		if _recording:
			_cancel_utterance() # 时序兜底：闭麦瞬间还在录 → 静默丢弃
		_vad.reset()
		_unmute_t = UNMUTE_GRACE # 闭麦刚结束的残响尾音不算开口
		return
	# 自播音效正在外放：无 AEC 的麦会把它收回去被 VAD 听成「开口」（enter=212ms 长过 START_MS）。
	# 只在「还没开口」时挡：录音中屏蔽会吃掉孩子正在说的话（已知取舍）。
	if not _recording and game_audio != null and game_audio.sfx_bleeding():
		_vad.reset()
		_unmute_t = UNMUTE_GRACE
		return
	if _unmute_t > 0.0:
		_unmute_t -= delta
		return
	_feed(pcm)
	if _recording:
		if debug_log:
			_dbg_accum += delta
			if _dbg_accum >= 1.0:
				_dbg_accum = 0.0
				var st: Dictionary = _vad.debug_stats()
				# silence_ms 若始终涨不上去（背景声灌满麦克风）→ 说完也断不了句，是卡顿指纹
				print("[vad] rec level=%.3f thr=%.4f silence=%dms speech=%dms" % [
					st["level"], st["threshold"], st["silence_ms"], st["speech_ms"]])
		_chunk_accum += delta
		if _chunk_accum >= CHUNK_FLUSH_SECS:
			_flush() # 上传/直喂与说话重叠，断句时音频已基本传完
			_chunk_accum = 0.0

## BGM 静音门控（本模块的单一真相，此前漂移点）：麦一开（聆听窗内）就静音，只在有人声时放行。
## 无 AEC 的麦只要开着就会把外放 BGM 收进去——真机 logcat 实证：满音量 BGM 峰值
## （rms≈0.05–0.085，与真人同量级）直接顶开 VAD、自己开录、ASR 转出空。
## 口径取「聆听窗内且没人在说话」而非严格 recording：等待孩子开口的这段麦也开着，同样要静音。
## set_ducked（音量微降）留宿主：各宿主口径不同（world 含 thinking）、非 ASR 关键，不并入。
func _update_bgm() -> void:
	if game_audio == null:
		return
	# 回放自己的录音时必须静音 BGM（否则盖住孩子自己的声音，确认就无从谈起）；
	# 回放完、光等孩子点确认的这段，BGM 放行（可能等挺久，没必要一直哑着）。
	var listening: bool = _open and not is_speaking.call() and not _confirming
	game_audio.set_music_muted(listening or _is_replaying())

# ── VAD 事件分发（独立函数：headless 测试注入合成 PCM 走同一链路）──────────────

func _feed(pcm: PackedByteArray) -> void:
	if _vad == null:
		return
	for ev in _vad.feed(pcm):
		match String(ev["type"]):
			"start":
				if debug_log:
					var st: Dictionary = _vad.debug_stats()
					print("[vad] START noise=%.4f thr=%.4f" % [st["noise"], st["threshold"]])
				_utterance_begin(ev["pcm"] as PackedByteArray)
			"speech":
				_pending_pcm.append_array(ev["pcm"] as PackedByteArray)
			"end":
				if debug_log:
					# reason=cap 说明 900ms 静音判定始终没触发、撞 12s 硬顶 = 卡顿实锤
					print("[vad] END reason=%s speech=%dms silence=%dms noise=%.4f thr=%.4f" % [
						ev.get("reason", "?"), ev.get("speech_ms", 0), ev.get("silence_ms", 0),
						ev.get("noise", 0.0), ev.get("threshold", 0.0)])
				_utterance_commit()
			"cancel":
				if debug_log:
					print("[vad] CANCEL reason=%s speech=%dms silence=%dms" % [
						ev.get("reason", "?"), ev.get("speech_ms", 0), ev.get("silence_ms", 0)])
				_cancel_utterance()

## 开口：端侧就绪则开识别会话，预录头块先送（首音节不丢）。
## 无可用 ASR 时照常录（VAD 事件不依赖 ASR），只是 PCM 无处可送——见 _flush。
func _utterance_begin(head: PackedByteArray) -> void:
	if _recording:
		return
	_recording = true
	if game_audio != null:
		game_audio.play_sfx("mic_on")
	_pending_pcm = head.duplicate()
	_utt_pcm = PackedByteArray()
	_chunk_accum = 0.0
	_asr_session = is_ready()
	if _asr_session:
		_asr.startSession()
	utterance_begin.emit()
	_flush()

## 说完（静音断句/硬顶）：残片发出，触发识别。
func _utterance_commit() -> void:
	if not _recording:
		return
	_recording = false
	if game_audio != null:
		game_audio.play_sfx("mic_off")
	_flush()
	if _asr_session:
		_asr.stopSession() # final_result 信号回来后走 local_final
		if confirm_mode:
			return # 确认模式：committed 推迟到 accept()——说完不等于采纳
	committed.emit()
	# 注意：本机没有可用端侧 ASR 时（editor/headless 缺模型）不会有 local_final 回来——
	# 没有识别能力就是没有结果，不伪造空转写。宿主自己的思考超时会兜底解卡（world 的
	# THINK_TIMEOUT）。生产真机上端侧 ASR 是硬依赖（AsrGuard 拦住坏包），不会走到这一步。

## 中途丢弃当前这段但保持聆听（宿主主动取消，如识别失败让孩子重说）。不关麦。
func cancel() -> void:
	_cancel_utterance()

# ── 确认模式（小龄玩家：说完先听一遍自己的话）────────────────────────────────

## 是否正等孩子确认（宿主据此亮/收确认条；此间麦不采集）。
func is_confirming() -> bool:
	return _confirming

## 正在回放刚录的那句话（宿主可据此把「听一遍」按钮点亮）。
func _is_replaying() -> bool:
	return _player != null and _player.playing

## 「就是这样」：采纳本段 —— 补发 committed + local_final，宿主照原路把话送出去。
func accept() -> void:
	if not _confirming:
		return
	var text := _confirm_text
	_end_confirm()
	if game_audio != null:
		game_audio.play_sfx("confirm")
	_emit_final(text)

## 「再说一次」：丢弃本段，麦继续开着等孩子重说（不发 committed/local_final，宿主什么都收不到）。
func retry() -> void:
	if not _confirming:
		return
	_end_confirm()
	if game_audio != null:
		game_audio.play_sfx("oops")

## 「再听一遍」：把刚录的那段再放一次（确认条上的重听按钮）。
func replay() -> void:
	if _utt_pcm.is_empty() or _player == null:
		return
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIC_RATE
	wav.stereo = false
	wav.data = _utt_pcm
	_player.stream = wav
	_player.play()

## 收拾确认态：停回放、清缓冲。VAD 在下一帧恢复（_confirming 一落，step 就重新喂麦）。
func _end_confirm() -> void:
	_confirming = false
	_confirm_text = ""
	_utt_pcm = PackedByteArray()
	if _player != null:
		_player.stop()
	_unmute_t = UNMUTE_GRACE # 回放尾音/确认音效不算下一句的开口

## 太短的误触 / 中途闭麦：静默丢弃本段，不产生转写。
func _cancel_utterance() -> void:
	if not _recording:
		return
	_recording = false
	_pending_pcm = PackedByteArray()
	_asr_session = false # 弃会话即可：插件下次 startSession 自动释放旧流
	cancelled.emit()

## 分片去向：端侧会话开着就直喂插件；没有会话（本机无 ASR）就丢弃——音频不上传、不外流。
func _flush() -> void:
	if _pending_pcm.is_empty():
		return
	if confirm_mode:
		_utt_pcm.append_array(_pending_pcm) # 留一份整段用于回放（只在确认模式下攒）
	if _asr_session:
		_asr.feedPcm(_pending_pcm) # 原始 PCM 直喂插件，永不离开设备
	_pending_pcm = PackedByteArray()

# ── 端侧 ASR 信号 ───────────────────────────────────────────────────────────

## 端侧识别出文本。确认模式下先不给宿主：回放刚录的话 + 发 confirm_ready，等 accept()。
## 识别失败（空转写）不进确认——那本来就得重说，直接放行让宿主走「没听清」分支。
func _on_local_final(text: String) -> void:
	_asr_session = false
	if not confirm_mode:
		local_final.emit(text) # committed 已在断句时发过，这里只补终局文本
		return
	if text.strip_edges().is_empty() or _utt_pcm.is_empty():
		_emit_final(text) # 没什么可确认的（识别失败/没留下录音）：照常放行，宿主走「没听清」
		return
	_confirm_text = text
	_confirming = true
	replay()
	confirm_ready.emit(text)

## 确认模式专用的放行口：断句时 committed 被扣下了，这里按原顺序补齐
## （committed 在前、local_final 在后，与非确认模式同序，宿主逻辑不变）。
func _emit_final(text: String) -> void:
	committed.emit()
	local_final.emit(text)

func _on_local_ready() -> void:
	if debug_log:
		print("[asr] 端侧模型就绪，开放麦")
	asr_ready.emit()

func _on_local_error(msg: String) -> void:
	_asr_session = false
	# Android/导出 macOS 上端侧 ASR 是硬依赖：失败即模型问题，硬报错拒进游戏。
	if AsrGuard.is_fatal(os_name, false, OS.has_feature("template")):
		AsrGuard.block(get_tree(), AsrGuard.MSG_INIT_FAILED % msg)
		return
	# editor/headless：多半是模型没随包（没设 MALIANG_ASR_MODEL_DIR）。没有服务端可回落了——
	# 本次运行就是没有识别能力：麦照开、VAD 照跑，但转写恒为空（见 _utterance_commit）。
	push_warning("端侧 ASR 不可用，本次运行没有语音识别: %s" % msg)
	_asr = null
