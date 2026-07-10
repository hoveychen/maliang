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
##   mic_open(derive(x)) == not (x.thinking or x.speaking)   —— 当 x.in_interaction 为真
##   否则 mic_open 恒为 false（未进对话时 _vad 为 null，本就不喂麦）

enum State {
	EXPLORE,    ## 自由巡游：未进对话
	APPROACH,   ## 正跑向某个角色（对方已被 _halt_npc 叫停）
	LISTENING,  ## 近身对话·开放麦，等 VAD 触发
	RECORDING,  ## VAD 已触发，正在录音喂 ASR
	THINKING,   ## 等服务端回应（含造角色「施法中」）：闭麦
	SPEAKING,   ## 角色出声（招呼/回应 TTS/仙子预制语音）：闭麦
	CREATION,   ## 引导造角色·等孩子点卡或开口（麦开着）
}

## world.gd 每帧喂入的原始标志位快照。字段名与 world.gd 的成员一一对应，便于核对。
class Inputs extends RefCounted:
	var in_interaction := false ## selected != null
	var approaching := false    ## not _approach.is_empty()
	var thinking := false       ## thinking_label.visible
	var speaking := false       ## _tts_player.playing or _tts_pending or fairy_voice.is_playing()
	var recording := false      ## _recording
	var in_creation := false    ## _in_creation

	func _init(p := {}) -> void:
		in_interaction = bool(p.get("in_interaction", false))
		approaching = bool(p.get("approaching", false))
		thinking = bool(p.get("thinking", false))
		speaking = bool(p.get("speaking", false))
		recording = bool(p.get("recording", false))
		in_creation = bool(p.get("in_creation", false))

## 由标志位派生当前状态。优先级顺序即闭麦语义的来源：
## 出声 > 思考 > 录音 > 造角色等待 > 聆听。前两者闭麦，后三者开麦——与旧 _step_voice 等价。
static func derive(x: Inputs) -> State:
	if not x.in_interaction:
		return State.APPROACH if x.approaching else State.EXPLORE
	if x.speaking:
		return State.SPEAKING # 角色在出声：半双工闭麦，防自听
	if x.thinking:
		return State.THINKING # 等回应/施法中：闭麦
	if x.recording:
		return State.RECORDING
	if x.in_creation:
		return State.CREATION # 念完问句、等孩子点卡或开口
	return State.LISTENING

## 该状态下是否应该开麦（把麦克风增量喂 VAD）。
static func mic_open(s: State) -> bool:
	return s == State.LISTENING or s == State.RECORDING or s == State.CREATION

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
	return "?"
