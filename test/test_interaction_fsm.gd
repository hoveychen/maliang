extends SceneTree
## InteractionFsm 单测：全枚举 6 个标志位的 64 种组合，断言
##   1) 闭麦门控与旧 _step_voice 表达式逐条等价（这是重构不改行为的护栏）
##   2) 状态派生遵循 SPEAKING > THINKING > RECORDING > CREATION > LISTENING 优先级
## 运行: godot --headless --path . --script res://test/test_interaction_fsm.gd

func _init() -> void:
	var fails := 0
	fails += _test_gating_equivalence()
	fails += _test_out_of_interaction()
	fails += _test_precedence()
	fails += _test_fairy_speaking()
	fails += _test_predicates()
	fails += _test_cooldown()
	fails += _test_empty_backoff()
	fails += _test_music_muted()
	fails += _test_leave_ready()
	fails += _test_speaker_leaves()
	if fails == 0:
		print("interaction_fsm tests PASS")
	else:
		printerr("interaction_fsm tests FAILED: %d" % fails)
	quit(fails)

func _mk(in_i: bool, appr: bool, think: bool, speak: bool, rec: bool, crea: bool) -> InteractionFsm.Inputs:
	return InteractionFsm.Inputs.new({
		"in_interaction": in_i, "approaching": appr, "thinking": think,
		"tts_busy": speak, "recording": rec, "in_creation": crea,
	})

func _mk_fairy(in_i: bool, fairy: bool) -> InteractionFsm.Inputs:
	return InteractionFsm.Inputs.new({ "in_interaction": in_i, "fairy_speaking": fairy })

## 护栏：进对话时 mic_open ⟺ not(thinking or speaking)（旧 _step_voice 的闭麦条件）；
## 未进对话时恒闭麦。全枚举 64 组合，一条不漏。
func _test_gating_equivalence() -> int:
	var fails := 0
	var bad := 0
	for mask in range(64):
		var in_i := (mask & 1) != 0
		var appr := (mask & 2) != 0
		var think := (mask & 4) != 0
		var speak := (mask & 8) != 0
		var rec := (mask & 16) != 0
		var crea := (mask & 32) != 0
		var x := _mk(in_i, appr, think, speak, rec, crea)
		var got := InteractionFsm.mic_open(InteractionFsm.derive(x))
		var want := in_i and not (think or speak) # 旧代码语义
		if got != want:
			if bad < 4:
				printerr("  mask=%d in_i=%s think=%s speak=%s rec=%s crea=%s → mic=%s want=%s (state=%s)" % [
					mask, in_i, think, speak, rec, crea, got, want,
					InteractionFsm.name_of(InteractionFsm.derive(x))])
			bad += 1
	fails += _check("闭麦门控 64 组合全等价(不等价数)", bad, 0)
	return fails

## 未进对话：approaching 决定 EXPLORE / APPROACH，且都不开麦。
func _test_out_of_interaction() -> int:
	var fails := 0
	fails += _check("未进对话+未接近 → EXPLORE",
		InteractionFsm.derive(_mk(false, false, false, false, false, false)), InteractionFsm.State.EXPLORE)
	fails += _check("未进对话+接近中 → APPROACH",
		InteractionFsm.derive(_mk(false, true, false, false, false, false)), InteractionFsm.State.APPROACH)
	fails += _check("EXPLORE 不开麦", InteractionFsm.mic_open(InteractionFsm.State.EXPLORE), false)
	fails += _check("APPROACH 不开麦", InteractionFsm.mic_open(InteractionFsm.State.APPROACH), false)
	return fails

## 优先级：SPEAKING > THINKING > RECORDING > CREATION > LISTENING。
func _test_precedence() -> int:
	var fails := 0
	# 出声压过一切（造角色念问句时也闭麦）
	fails += _check("speaking 压过 thinking",
		InteractionFsm.derive(_mk(true, false, true, true, false, false)), InteractionFsm.State.SPEAKING)
	fails += _check("speaking 压过 recording+creation",
		InteractionFsm.derive(_mk(true, false, false, true, true, true)), InteractionFsm.State.SPEAKING)
	# 思考压过录音/造角色（施法中闭麦）
	fails += _check("thinking 压过 recording",
		InteractionFsm.derive(_mk(true, false, true, false, true, false)), InteractionFsm.State.THINKING)
	fails += _check("thinking 压过 creation",
		InteractionFsm.derive(_mk(true, false, true, false, false, true)), InteractionFsm.State.THINKING)
	# 录音压过造角色等待（造角色期间孩子开口说答案）
	fails += _check("recording 压过 creation",
		InteractionFsm.derive(_mk(true, false, false, false, true, true)), InteractionFsm.State.RECORDING)
	# 造角色等待 vs 纯聆听
	fails += _check("creation 等待",
		InteractionFsm.derive(_mk(true, false, false, false, false, true)), InteractionFsm.State.CREATION)
	fails += _check("纯聆听",
		InteractionFsm.derive(_mk(true, false, false, false, false, false)), InteractionFsm.State.LISTENING)
	# 三个开麦态
	fails += _check("LISTENING 开麦", InteractionFsm.mic_open(InteractionFsm.State.LISTENING), true)
	fails += _check("RECORDING 开麦", InteractionFsm.mic_open(InteractionFsm.State.RECORDING), true)
	fails += _check("CREATION 开麦", InteractionFsm.mic_open(InteractionFsm.State.CREATION), true)
	fails += _check("THINKING 闭麦", InteractionFsm.mic_open(InteractionFsm.State.THINKING), false)
	fails += _check("SPEAKING 闭麦", InteractionFsm.mic_open(InteractionFsm.State.SPEAKING), false)
	return fails

## 仙子预制语音也算「出声」→ 闭麦（与旧 _step_voice 的 fairy_voice.is_playing() 一致）。
func _test_fairy_speaking() -> int:
	var fails := 0
	fails += _check("仙子说话 → SPEAKING",
		InteractionFsm.derive(_mk_fairy(true, true)), InteractionFsm.State.SPEAKING)
	fails += _check("仙子说话 → 闭麦",
		InteractionFsm.mic_open(InteractionFsm.derive(_mk_fairy(true, true))), false)
	fails += _check("仙子不说话 → LISTENING",
		InteractionFsm.derive(_mk_fairy(true, false)), InteractionFsm.State.LISTENING)
	return fails

## 三个谓词各自的口径（含既存的「不含仙子」差异——固化为断言，防被无意统一）。
func _test_predicates() -> int:
	var fails := 0
	var only_fairy := _mk_fairy(true, true)
	fails += _check("voice_busy 含仙子语音", InteractionFsm.voice_busy(only_fairy), true)
	fails += _check("tts_speaking 不含仙子语音", InteractionFsm.tts_speaking(only_fairy), false)
	fails += _check("player_engaged 不含仙子语音(但 in_interaction 已为真)",
		InteractionFsm.player_engaged(_mk_fairy(false, true)), false)

	var rec := _mk(true, false, false, false, true, false)
	fails += _check("voice_busy 含录音", InteractionFsm.voice_busy(rec), true)
	fails += _check("tts_speaking 不含录音", InteractionFsm.tts_speaking(rec), false)
	fails += _check("player_engaged 含录音", InteractionFsm.player_engaged(rec), true)

	var idle := _mk(false, false, false, false, false, false)
	fails += _check("全空 → voice_busy 假", InteractionFsm.voice_busy(idle), false)
	fails += _check("全空 → player_engaged 假", InteractionFsm.player_engaged(idle), false)
	fails += _check("只是进了对话 → player_engaged 真",
		InteractionFsm.player_engaged(_mk(true, false, false, false, false, false)), true)
	return fails

## 空识别退避态：闭麦，且不被噪声立刻再触发（缺陷 ① 的解药）。
## 但不得压过「角色在出声/正在思考」——那两态本就闭麦，语义更强。
func _test_cooldown() -> int:
	var fails := 0
	var cd := InteractionFsm.Inputs.new({ "in_interaction": true, "cooldown": true })
	fails += _check("冷却中 → COOLDOWN", InteractionFsm.derive(cd), InteractionFsm.State.COOLDOWN)
	fails += _check("COOLDOWN 闭麦", InteractionFsm.mic_open(InteractionFsm.State.COOLDOWN), false)

	var cd_speak := InteractionFsm.Inputs.new({
		"in_interaction": true, "cooldown": true, "tts_busy": true })
	fails += _check("speaking 压过 cooldown", InteractionFsm.derive(cd_speak), InteractionFsm.State.SPEAKING)

	var cd_think := InteractionFsm.Inputs.new({
		"in_interaction": true, "cooldown": true, "thinking": true })
	fails += _check("thinking 压过 cooldown", InteractionFsm.derive(cd_think), InteractionFsm.State.THINKING)

	var cd_crea := InteractionFsm.Inputs.new({
		"in_interaction": true, "cooldown": true, "in_creation": true })
	fails += _check("cooldown 压过 creation(造角色期也退避)",
		InteractionFsm.derive(cd_crea), InteractionFsm.State.COOLDOWN)

	fails += _check("冷却结束 → 回 LISTENING",
		InteractionFsm.derive(InteractionFsm.Inputs.new({ "in_interaction": true })),
		InteractionFsm.State.LISTENING)
	return fails

## 指数退避 + 封顶。
func _test_empty_backoff() -> int:
	var fails := 0
	fails += _check("streak 0 → 不退避", InteractionFsm.empty_cooldown(0), 0.0)
	fails += _check("streak 1 → BASE", InteractionFsm.empty_cooldown(1), InteractionFsm.EMPTY_COOLDOWN_BASE)
	fails += _check("streak 2 → 2×BASE", InteractionFsm.empty_cooldown(2), 1.6)
	fails += _check("streak 3 → 4×BASE", InteractionFsm.empty_cooldown(3), 3.2)
	fails += _check("streak 4 → 封顶", InteractionFsm.empty_cooldown(4), InteractionFsm.EMPTY_COOLDOWN_MAX)
	fails += _check("streak 9 → 仍封顶", InteractionFsm.empty_cooldown(9), InteractionFsm.EMPTY_COOLDOWN_MAX)
	return fails

## BGM 静音口径：对话里、角色没说话时一律静音（含 THINKING/COOLDOWN 这些闭麦但麦随时重开的态），
## 只有角色说话时音乐才回来垫在人声下。世界里（未进对话）音乐照常。
func _test_music_muted() -> int:
	var fails := 0
	fails += _check("EXPLORE 不静音",
		InteractionFsm.music_muted(_mk(false, false, false, false, false, false)), false)
	fails += _check("APPROACH 不静音",
		InteractionFsm.music_muted(_mk(false, true, false, false, false, false)), false)
	fails += _check("LISTENING 静音",
		InteractionFsm.music_muted(_mk(true, false, false, false, false, false)), true)
	fails += _check("RECORDING 静音",
		InteractionFsm.music_muted(_mk(true, false, false, false, true, false)), true)
	fails += _check("CREATION 静音",
		InteractionFsm.music_muted(_mk(true, false, false, false, false, true)), true)
	fails += _check("THINKING 静音(麦随时重开,防淡出期被顶开)",
		InteractionFsm.music_muted(_mk(true, false, true, false, false, false)), true)
	fails += _check("COOLDOWN 静音(同上)",
		InteractionFsm.music_muted(InteractionFsm.Inputs.new({
			"in_interaction": true, "cooldown": true })), true)
	fails += _check("SPEAKING 不静音(音乐垫在人声下)",
		InteractionFsm.music_muted(_mk(true, false, false, true, false, false)), false)
	fails += _check("仙子说话也算 SPEAKING,不静音",
		InteractionFsm.music_muted(_mk_fairy(true, true)), false)
	return fails

## 「说完再走」的时序判定（缺陷 ④）：TTS 起播有延迟、可能压根没有 TTS、必须有兜底超时。
func _test_leave_ready() -> int:
	var fails := 0
	# 还没出过声，宽限未尽 → 等（这就是「不能一上来就以没在说话判定说完了」）
	fails += _check("宽限内未出声 → 等", InteractionFsm.leave_ready(false, false, 0.3, 8.0), false)
	# 宽限耗尽仍没出声（无 TTS/合成失败）→ 直接动身，别傻等
	fails += _check("宽限耗尽仍无声 → 动身", InteractionFsm.leave_ready(false, false, 0.0, 8.0), true)
	# 正在出声 → 等它说完
	fails += _check("正在说话 → 等", InteractionFsm.leave_ready(true, true, 0.0, 8.0), false)
	fails += _check("宽限内就开口了 → 等", InteractionFsm.leave_ready(true, true, 0.2, 8.0), false)
	# 出过声、现在不出声了 = 说完了 → 动身
	fails += _check("说完了 → 动身", InteractionFsm.leave_ready(true, false, 0.0, 8.0), true)
	# 兜底：TTS 石沉大海（一直"在说"）也不能把角色钉死
	fails += _check("兜底超时 → 强制动身", InteractionFsm.leave_ready(true, true, 0.0, 0.0), true)
	fails += _check("兜底优先于一切", InteractionFsm.leave_ready(false, true, 5.0, -0.1), true)
	return fails

## 「正在跟孩子说话的角色会不会走开」——决定说完这句要不要关对话。
## 判据是「他会不会离开孩子面前」，不是「这条指令有没有副作用」：
## stop_follow 改了状态却留在原地，do_action 演个动作也留在原地，都不关对话。
func _test_speaker_leaves() -> int:
	var fails := 0
	# 立去系：角色要走开办事 → 说完再动身 + 关对话
	for cmd in InteractionFsm.LEAVE_COMMANDS:
		fails += _check("%s → 走开" % cmd, InteractionFsm.speaker_leaves([cmd], false, false), true)
	# 留在原地：改了跟随状态也好、演个动作也好，孩子还看着他，对话继续
	fails += _check("stop_follow → 不走开", InteractionFsm.speaker_leaves(["stop_follow"], false, false), false)
	fails += _check("do_action → 不走开", InteractionFsm.speaker_leaves(["do_action"], false, false), false)
	fails += _check("空脚本 → 不走开", InteractionFsm.speaker_leaves([], false, false), false)
	# 多条指令里只要有一条立去系，人就走了
	fails += _check("do_action+move_to → 走开", InteractionFsm.speaker_leaves(["do_action", "move_to"], false, false), true)

	# ① 点名指派：对话对象要跑腿把指令带给别人（relay_command），无论带的是什么指令他都得走开。
	#    「小蓝跳一下」——跳的是小蓝，但走开的是正在跟你说话的这个角色。
	fails += _check("跑腿带 do_action → 走开", InteractionFsm.speaker_leaves(["do_action"], true, false), true)
	fails += _check("跑腿带 move_to → 走开", InteractionFsm.speaker_leaves(["move_to"], true, false), true)

	# ② 小仙子是随从（_run_behavior 对她早退，移动脚本一律丢弃）：她永远不会走开，
	#    对话就不该被白白关掉。跑腿也一样——她压根不会去跑腿。
	fails += _check("仙子吃 move_to → 不走开", InteractionFsm.speaker_leaves(["move_to"], false, true), false)
	fails += _check("仙子吃 follow → 不走开", InteractionFsm.speaker_leaves(["follow"], false, true), false)
	fails += _check("仙子被叫去跑腿 → 不走开", InteractionFsm.speaker_leaves(["do_action"], true, true), false)
	return fails

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ok %s" % name)
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
