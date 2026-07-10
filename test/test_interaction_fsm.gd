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
	if fails == 0:
		print("interaction_fsm tests PASS")
	else:
		printerr("interaction_fsm tests FAILED: %d" % fails)
	quit(fails)

func _mk(in_i: bool, appr: bool, think: bool, speak: bool, rec: bool, crea: bool) -> InteractionFsm.Inputs:
	return InteractionFsm.Inputs.new({
		"in_interaction": in_i, "approaching": appr, "thinking": think,
		"speaking": speak, "recording": rec, "in_creation": crea,
	})

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

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ok %s" % name)
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
