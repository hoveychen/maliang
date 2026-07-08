extends SceneTree
## GameAudio 单测：资产齐全 + bus 幂等 + 音效冷却 + BGM 换段/交叉淡化 + duck 目标音量。
## headless dummy 音频 playing 永真：断言只看自记账状态与 volume_db，不看 playing 翻转。

var _fails := 0

## 按 0.05s 步长推进虚拟时间（贴近真实帧节奏）
func _sim(ga: GameAudio, secs: float) -> void:
	var t := 0.0
	while t < secs:
		ga._advance(0.05)
		t += 0.05

## 等 BGM 段线程加载就绪起播（step_index>=0）。BGM 改线程加载后 start_bgm 不再同步
## 起播——用 OS.delay_msec 给 worker 真实时间，不靠循环次数猜时序。
func _wait_bgm(ga: GameAudio) -> void:
	for i in range(2000):
		ga._advance(0.0)  # delta=0：只跑加载轮询、不推进时间
		if ga.step_index >= 0:
			return
		OS.delay_msec(1)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("PASS %s" % name)
		return 0
	printerr("FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _initialize() -> void:
	var ga := GameAudio.new()
	root.add_child(ga)
	process_frame.connect(func() -> void: _run(ga), CONNECT_ONE_SHOT)

func _run(ga: GameAudio) -> void:
	# 资产齐全：SFX 表与 BGM 段引用的文件都必须存在
	for key in GameAudio.SFX:
		_fails += _check("sfx 文件存在 %s" % key, ResourceLoader.exists(GameAudio.SFX[key]), true)
	for path in GameAudio.BGM_STEPS:
		_fails += _check("bgm 文件存在 %s" % path, ResourceLoader.exists(path), true)
		# BGM 必须真开 Forward loop，否则播完一遍就静音（导入 edit/loop_mode 须为 2=Forward，
		# 不是 1=Disabled——早先三段就栽在这个错值上，播 9.6s 即停）
		var s := load(path) as AudioStreamWAV
		_fails += _check("bgm loop=Forward %s" % path, s.loop_mode, AudioStreamWAV.LOOP_FORWARD)

	# bus 幂等：_ready 已建 Music/SFX，重复 ensure 不再加
	_fails += _check("Music bus 存在", AudioServer.get_bus_index("Music") != -1, true)
	_fails += _check("SFX bus 存在", AudioServer.get_bus_index("SFX") != -1, true)
	var n := AudioServer.bus_count
	GameAudio._ensure_bus("Music")
	GameAudio._ensure_bus("SFX")
	_fails += _check("ensure_bus 幂等", AudioServer.bus_count, n)

	# 音效：未知名拒绝；连点冷却；冷却过后可再播
	_fails += _check("未知音效返回 false", ga.play_sfx("nope"), false)
	_fails += _check("首次播放成功", ga.play_sfx("click"), true)
	_fails += _check("冷却期内拒绝", ga.play_sfx("click"), false)
	ga._advance(GameAudio.SFX_GAP + 0.01)
	_fails += _check("冷却过后可再播", ga.play_sfx("click"), true)

	# 保留能力：喂多条 step 时按 section 轮换并交叉淡化（生产只用单条，这里用同一文件×2 覆盖机制）
	# 用 0.05s 小步长模拟真实帧推进；一次塞大 delta 会在同帧内完成整个淡化
	var two: Array = [GameAudio.BGM_STEPS[0], GameAudio.BGM_STEPS[0]]
	ga.start_bgm(two)
	_fails += _check("start_bgm 不同步起播(线程加载中)", ga.step_index, -1)
	_wait_bgm(ga)
	_fails += _check("线程加载完起播在第 0 段", ga.step_index, 0)
	_sim(ga, GameAudio.SECTION_SECS + 0.1)
	_fails += _check("section 到点换段", ga.step_index, 1)
	_fails += _check("交叉淡化进行中", ga._fade_left > 0.0, true)
	_sim(ga, GameAudio.CROSSFADE_SECS + 0.1)
	_fails += _check("淡化结束", ga._fade_left, 0.0)
	_sim(ga, GameAudio.SECTION_SECS)
	_fails += _check("轮换回第 0 段", ga.step_index, 0)

	# duck：目标音量应收敛到 MUSIC_DB + DUCK_DB
	ga.set_ducked(true)
	for i in 60:
		ga._advance(1.0 / 30.0)
	var active: AudioStreamPlayer = ga._music_a if ga._active_is_a else ga._music_b
	var want_db := GameAudio.MUSIC_DB + GameAudio.DUCK_DB
	_fails += _check("duck 后音量收敛", absf(active.volume_db - want_db) < 1.0, true)
	ga.set_ducked(false)
	for i in 60:
		ga._advance(1.0 / 30.0)
	_fails += _check("解除 duck 回常态", absf(active.volume_db - GameAudio.MUSIC_DB) < 1.0, true)

	# 单段模式：永不换段
	ga.start_bgm([GameAudio.BGM_STEPS[0]])
	_wait_bgm(ga)
	_sim(ga, GameAudio.SECTION_SECS * 3.0)
	_fails += _check("单段不轮换", ga.step_index, 0)
	ga.stop_bgm()
	_fails += _check("stop 后归 -1", ga.step_index, -1)

	print("test_game_audio fails=%d" % _fails)
	quit(_fails)
