class_name InteractionFsm
extends RefCounted
## 对话交互显式状态机（P1：只做「派生 + 门控」，不夺取状态所有权）。
##
## 背景：交互状态此前由 selected / _recording / thinking_label.visible / _tts_pending /
## _in_creation 等标志位隐式组合而成，散落在 world.gd 各处，是「空结果连环录」「仙子被拽飞」
## 这类缺陷反复出现的结构性原因（见 docs 状态机图）。这一步先把「这些标志位组合起来到底是
## 哪个状态、该不该开麦」收敛成一处纯逻辑，行为与旧代码逐条等价、可 headless 断言。
##
## 纯逻辑、不碰节点/时钟：world.gd 每帧把标志位喂进来，拿回状态与闭麦决定。
##
## 等价契约（必须永远成立，见 test_interaction_fsm）：
##   mic_open(derive(x)) == not (x.thinking or x.speaking or x.cooldown)  —— 当 x.in_interaction 为真
##   否则 mic_open 恒为 false（未进对话时 _vad 为 null，本就不喂麦）
## cooldown 是本状态机第一个「拥有态」（由 world.gd 的退避计时器驱动），其余仍是标志位派生。

enum State {
	EXPLORE,    ## 自由巡游：未进对话
	APPROACH,   ## 正跑向某个角色（对方已被 _halt_npc 叫停）
	LISTENING,  ## 近身对话·开放麦，等 VAD 触发
	RECORDING,  ## VAD 已触发，正在录音喂 ASR
	THINKING,   ## 等服务端回应（含造角色「施法中」）：闭麦
	SPEAKING,   ## 角色出声（招呼/回应 TTS/仙子预制语音）：闭麦
	CREATION,   ## 引导造角色·等孩子点卡或开口（麦开着）
	COOLDOWN,   ## 刚吃到一次空识别：闭麦退避，别被噪声立刻再触发（缺陷 ① 的解药）
}

## 连续空识别的退避：第 n 次空结果闭麦多久（秒）。指数退避、封顶。
## 一次空结果多半是误触发；连着空说明环境在持续骗 VAD，退得越久越好。
const EMPTY_COOLDOWN_BASE := 0.8
const EMPTY_COOLDOWN_MAX := 4.0

static func empty_cooldown(streak: int) -> float:
	if streak <= 0:
		return 0.0
	return minf(EMPTY_COOLDOWN_BASE * pow(2.0, float(streak - 1)), EMPTY_COOLDOWN_MAX)

## world.gd 每帧喂入的原始标志位快照。字段名与 world.gd 的成员一一对应，便于核对。
class Inputs extends RefCounted:
	var in_interaction := false ## selected != null
	var approaching := false    ## not _approach.is_empty()
	var thinking := false       ## thinking_label.visible
	var tts_busy := false       ## _tts_player.playing or _tts_pending（角色 TTS）
	var fairy_speaking := false ## fairy_voice.is_playing()（仙子预制语音）
	var recording := false      ## _recording
	var in_creation := false    ## _in_creation
	var cooldown := false       ## _cooldown_t > 0.0（空识别退避中）

	func _init(p := {}) -> void:
		in_interaction = bool(p.get("in_interaction", false))
		approaching = bool(p.get("approaching", false))
		thinking = bool(p.get("thinking", false))
		tts_busy = bool(p.get("tts_busy", false))
		fairy_speaking = bool(p.get("fairy_speaking", false))
		recording = bool(p.get("recording", false))
		in_creation = bool(p.get("in_creation", false))
		cooldown = bool(p.get("cooldown", false))

	## 任何角色在出声（含仙子预制语音）。
	func speaking() -> bool:
		return tts_busy or fairy_speaking

## 由标志位派生当前状态。优先级顺序即闭麦语义的来源：
## 出声 > 思考 > 录音 > 造角色等待 > 聆听。前两者闭麦，后三者开麦——与旧 _step_voice 等价。
static func derive(x: Inputs) -> State:
	if not x.in_interaction:
		return State.APPROACH if x.approaching else State.EXPLORE
	if x.speaking():
		return State.SPEAKING # 角色在出声：半双工闭麦，防自听
	if x.thinking:
		return State.THINKING # 等回应/施法中：闭麦
	if x.cooldown:
		return State.COOLDOWN # 刚吃到空识别：闭麦退避，别被噪声立刻再触发
	if x.recording:
		return State.RECORDING
	if x.in_creation:
		return State.CREATION # 念完问句、等孩子点卡或开口
	return State.LISTENING

## 该状态下是否应该开麦（把麦克风增量喂 VAD）。
static func mic_open(s: State) -> bool:
	return s == State.LISTENING or s == State.RECORDING or s == State.CREATION

# ── 散落各处的门控谓词，原样收敛于此 ────────────────────────────────────────
# 注意：这三个谓词的口径**本来就不一致**（下面两个不含仙子预制语音）。这是既存行为，
# 本次重构只做「收敛到一处、可见」，不擅自统一——统一即改行为，得单独评估。
# 差异本身可疑：_check_poi / _fairy_ambient 在仙子说话时不闭嘴，可能是漏判。

## 语音链路占用（录音/思考/任何角色出声）→ 压低 BGM。含仙子语音。
## 调用点：_process 的 game_audio.set_ducked。
static func voice_busy(x: Inputs) -> bool:
	return x.recording or x.thinking or x.speaking()

## 角色 TTS 正在出声（**不含**仙子预制语音）。
## 调用点：_dialog_speaker（构图判「谁在说话」）、_on_praise_tts（正在出声就不插播表扬）。
static func tts_speaking(x: Inputs) -> bool:
	return x.tts_busy

## 玩家正被交互占用（在对话/录音/思考/角色 TTS 出声）→ 不打扰他（不发 POI 提醒、不起闲聊）。
## **不含**仙子预制语音。调用点：_check_poi、_fairy_ambient。
static func player_engaged(x: Inputs) -> bool:
	return x.in_interaction or x.recording or x.thinking or x.tts_busy

## 对话期间是否静音 BGM。
## 无 AEC 的麦克风只要开着，就会把外放 BGM 收进去——真机 logcat 实证：音乐峰值
## （rms≈0.046–0.085，与真人说话同量级）直接顶开 VAD，自己开录、ASR 转出空。
##
## 判据取「在对话里且角色没在说话」，而非严格的 mic_open：THINKING/COOLDOWN 虽然闭麦，
## 但麦随时会重开，若此时音乐已回到满音量，麦一开正赶上音乐淡出，峰值又会触发一次。
## 于是音乐只在角色说话（SPEAKING）时响，垫在人声下面；其余对话时间一律静音。
static func music_muted(x: Inputs) -> bool:
	return x.in_interaction and not x.speaking()

# ── 「说完再走」的时序判定（缺陷 ④）───────────────────────────────────────
# leave 指令（move_to/follow/chat_with/deliver_message）到达时，此前是立刻 _exit_interaction()：
# 横幅与相机锁定在角色开口之前就没了，孩子刚说完「我们去风车吧」对话框就消失、他边走边说话。
# 改为先把回应说完，再动身 + 关对话。
#
# 三个坑：TTS 起播有延迟（edge 异步 / _play_tts 要先拉音频），不能一上来就以「没在说话」判定说完了；
# 可能压根没有 TTS（合成失败/空文本），不能傻等；必须有兜底超时，否则角色永远钉在原地。
const LEAVE_ARM_SEC := 0.4      ## 等 TTS 起播的宽限：这段时间内没出声就认为这轮无 TTS
const LEAVE_DEADLINE_SEC := 8.0 ## 兜底超时：TTS 石沉大海也别把角色钉死（与 _tts_pending_deadline 同量级）

## seen：这轮是否曾经真的出声过。arm_left / deadline_left：两个倒计时的剩余秒数。
static func leave_ready(seen: bool, speaking: bool, arm_left: float, deadline_left: float) -> bool:
	if deadline_left <= 0.0:
		return true          # 兜底：不管发生了什么，都得让角色动身
	if seen:
		return not speaking  # 出过声、现在不出声了 = 说完了
	return arm_left <= 0.0   # 宽限内始终没出声（无 TTS/合成失败）→ 直接动身

## 立去系指令：会让角色离开当前位置去别处（去某地/跟随/找人聊天/带话）。
## 就地动作(do_action)、停跟(stop_follow)不算——角色留在孩子面前，对话不必关。
const LEAVE_COMMANDS := ["move_to", "follow", "chat_with", "deliver_message"]

## 这次派发会不会让「正在跟孩子说话的那个角色」离开他面前？是则先说完再动身、随后关对话；
## 否则原地执行、对话继续。三个入参对应 world.gd 的三条派发路径：
##   command_types      待派发脚本里的指令类型
##   relaying           脚本靠对话对象跑腿转交给别的角色（relay_command）
##   _speaker_is_fairy  对话对象是小仙子（随从，_run_behavior 对她早退）
static func speaker_leaves(command_types: Array, relaying: bool, _speaker_is_fairy: bool) -> bool:
	if relaying:
		return false # 现行语义：跑腿分支从不判 leave（P2 修）
	for t in command_types:
		if String(t) in LEAVE_COMMANDS:
			return true
	return false

## 调试/日志用的状态名。
static func name_of(s: State) -> String:
	match s:
		State.EXPLORE: return "EXPLORE"
		State.APPROACH: return "APPROACH"
		State.LISTENING: return "LISTENING"
		State.RECORDING: return "RECORDING"
		State.THINKING: return "THINKING"
		State.SPEAKING: return "SPEAKING"
		State.CREATION: return "CREATION"
		State.COOLDOWN: return "COOLDOWN"
	return "?"
