extends SceneTree
## 开麦态自播音效的回灌防护。
##
## 缺陷：`_enter_interaction` 播 `enter` 音效（maximize_003.ogg，实测 212ms）的同时
## 开放麦（FSM = LISTENING，mic_open 为真），且显式把 `_unmute_t` 清零。平板无 AEC，
## 外放音效被麦克风收回去 → VoiceVad `_step_idle` 连续有声累计 ≥ START_MS(90ms) →
## 误判「孩子开口了」→ 空录音一轮 → ASR 返回空 → COOLDOWN 退避。
##
## 同源证据：interaction_fsm.gd 的 `music_muted` 注释记录了真机 logcat 实证——外放 BGM
## （-14dB）峰值就能顶开 VAD。而 SFX 是 -6dB，比 BGM 还响 8dB。当初为 BGM 加的防回灌
## 静音只压 Music bus，SFX bus 从未受保护。
##
## 本测试断言：开麦态（LISTENING）播音效期间，`_step_voice` 必须屏蔽 VAD。
## 注意 headless 麦克风是 dummy、采不到真实音频，无法重现「音效真被收回去」，
## 因此断言的是防护机制本身（屏蔽窗口已武装），而非 VAD 的最终输出。
##
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --path . \
##       --fixed-fps 10 --quit-after 60 --script res://test/test_sfx_mic_guard.gd

## world.gd 的 UNMUTE_GRACE。开麦态最长音效是 enter(212ms)，窗口须盖得住。
const UNMUTE_GRACE := 0.3

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
	match frame:
		20:
			_test_sfx_longer_than_vad_trigger()
			_enter_interaction_with_npc()
		22:
			# 隔一帧再断言：_enter_interaction 里 _unmute_t 归零，屏蔽由随后的 _step_voice 武装。
			_assert_vad_guarded_while_sfx_plays()
		24:
			if fails == 0:
				print("sfx_mic_guard PASS")
			else:
				printerr("sfx_mic_guard FAILED: %d" % fails)
			quit(fails)

## 前提证据：开麦态会播的音效，时长超过 VAD 判定开口所需的连续有声时长。
## 若这条不成立，整个缺陷就不存在（音效太短，凑不满 START_MS）。
func _test_sfx_longer_than_vad_trigger() -> void:
	var start_sec := float(VoiceVad.START_MS) / 1000.0
	var enter_len: float = (load(GameAudio.SFX["enter"]) as AudioStream).get_length()
	var bell_len: float = (load(GameAudio.SFX["bell"]) as AudioStream).get_length()
	_check("enter 音效(%.3fs) 长于 VAD 开口阈值(%.3fs)" % [enter_len, start_sec],
		enter_len > start_sec, true)
	_check("bell 音效(%.3fs) 长于 VAD 开口阈值(%.3fs)" % [bell_len, start_sec],
		bell_len > start_sec, true)
	# 屏蔽窗口必须盖得住最长的开麦态音效，否则音效尾巴仍会被听成开口。
	_check("UNMUTE_GRACE(%.2fs) 盖得住 enter 音效(%.3fs)" % [UNMUTE_GRACE, enter_len],
		UNMUTE_GRACE > enter_len, true)

## 进对话必须挑「非仙子」角色：仙子会播预制招呼语音 → FSM 进 SPEAKING → 闭麦分支
## 也会设 _unmute_t，那样断言就分不清屏蔽到底来自音效还是来自角色说话（假绿）。
## 离线（MALIANG_API_BASE 指向死地址）下非仙子 NPC 不会有招呼 TTS，稳定停在 LISTENING。
func _enter_interaction_with_npc() -> void:
	var npcs: Array = scene.get("npcs")
	var target: Dictionary = {}
	for n in npcs:
		if not n.get("is_fairy", false):
			target = n
			break
	if target.is_empty():
		fails += 1
		printerr("  FAIL 场景里没有非仙子 NPC，无法在 LISTENING 态验证")
		return
	scene.call("_enter_interaction", target["node"])
	_check("进对话后开放麦已就绪", scene.get("_vad") != null, true)

## 核心断言：音效仍在外放时，开麦态的 VAD 必须处于屏蔽窗口内。
func _assert_vad_guarded_while_sfx_plays() -> void:
	if scene.get("_vad") == null:
		return
	# 屏蔽须发生在开麦态。若这里是 SPEAKING/THINKING，闭麦分支也会设 _unmute_t，断言失去意义。
	var state: int = scene.call("_fsm_state")
	_check("非仙子离线进对话停在 LISTENING（开麦态）",
		InteractionFsm.name_of(state), "LISTENING")
	_check("音效外放期间不得误开录音", scene.get("_recording"), false)
	var guard: float = scene.get("_unmute_t")
	_check("开麦态播音效必须屏蔽 VAD (_unmute_t=%.3f > 0)" % guard, guard > 0.0, true)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
