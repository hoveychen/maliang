extends SceneTree
## P4：intro 教学段端到端驱动 —— 无档案(首次)路径下走路→靠近村民→开口说话三步教学能被检测并推进到底。
## 预置 intro_seen=false → _tutorial=true。驱动方式（headless 无真人/真麦，注入等效状态）：
##   - 走路 + 靠近：把玩家逻辑坐标锚到首个 demo 村民旁并每帧摆动 → 位移达标(走路)且近身(靠近)，
##     同时玩家近身触发 world._update_npc_notice 令村民挥手 emote（不开口，守音色契约）。
##   - 开口说话：一旦 world 进入教学监听(_intro_listening)，注入合成人声 PCM → 本地 VAD 判「开口」。
## 断言：三步走完、开口被 VAD 检测到、村民被近身触发过 emote、编排器完成并标记 intro_seen、离线仍保 demo。
## 桌面/headless 非导出构建 → intro_asr_blocked()=false（端侧非硬依赖），说话步正常演。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 1200 \
##       --script res://test/test_intro_tutorial.gd

var scene: Node
var frame := 0
var fails := 0
var done := false
var base := Vector2.ZERO       ## 玩家摆动锚点（村民旁）
var target := Vector2.ZERO     ## 目标 demo 村民逻辑坐标
var have_target := false
var villager_emoted := false   ## 全程锁存：任一 demo 村民被近身触发过挥手/点头
var fairy_spoke_during_intro := false ## 全程锁存：intro 未结束时点点是否闲聊过（greet/idle）——应恒 false
var fairy_bubble_during_intro := false ## 全程锁存：intro 未结束时点点音符气泡/语音是否出现过——应恒 false（视觉上也不抢旁白）
var hint_ring_shown := false   ## 全程锁存：走路/靠近步的地面脉动光环出现过（Bug②视觉指引）
var mic_hint_shown := false    ## 全程锁存：说话步话筒+声波 HUD 被亮起过（Bug②视觉指引）
var swing_t := 0.0

func _initialize() -> void:
	IntroDirector.pending = true
	var p := PlayerProfile.load_profile()
	p["intro_seen"] = false # 首次：演教学段
	PlayerProfile.save_profile(p)
	# 预置画质档 → 跳过内嵌 benchmark 段：本测只驱动教学段（走路/靠近/开口），benchmark 由 test_intro_benchmark 覆盖
	GraphicsSettings.save_all(GraphicsSettings.all_max(), "user")
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null or done:
		return
	frame += 1
	# 锁定驱动目标：首个 demo 村民；玩家锚到其旁 4 格
	if not have_target:
		for n in (scene.get("npcs") as Array):
			var d: Dictionary = n
			if not d.get("is_fairy", false) and String(d.get("id", "")).begins_with("demo_"):
				target = d.get("logical", Vector2.ZERO)
				have_target = true
				break
		if have_target:
			base = WorldGrid.wrap_pos(target + Vector2(3.5, 0.0))
	if have_target and not (scene.get("player") as Dictionary).is_empty():
		# 摆动玩家：位移持续变化(峰峰值 5>WALK_DIST=3，满足走路)，且全程距村民 [1,6]<NOTICE_RADIUS=6.5
		# （满足靠近，且始终在范围内）
		swing_t += 0.3
		var pl: Dictionary = scene.get("player")
		pl["logical"] = WorldGrid.wrap_pos(base + Vector2(sin(swing_t) * 2.5, 0.0))
		# 去 RNG 抖动，钉死 notice_ready 前置：目标村民冷却清零 + 站定（否则随机 notice_cd 与
		# 村民 ambient 走动会让「近身挥手」在导演转正窗口内偶发不触发——真机是概率错峰、这里要确定性）。
		for n in (scene.get("npcs") as Array):
			var d0: Dictionary = n
			if not d0.get("is_fairy", false) and String(d0.get("id", "")).begins_with("demo_") \
					and String(d0.get("paper_action", "")).is_empty():
				d0["notice_cd"] = 0.0
				d0["paper_walk"] = 0.0
	# 锁存村民 emote：近身后 world._update_npc_notice 会给 demo 村民设 paper_action
	for n in (scene.get("npcs") as Array):
		var d: Dictionary = n
		if not d.get("is_fairy", false) and String(d.get("id", "")).begins_with("demo_") \
				and not String(d.get("paper_action", "")).is_empty():
			villager_emoted = true
	# 教学监听开启 → 注入合成人声，驱动本地 VAD 判「开口」
	if bool(scene.get("_intro_listening")):
		scene.call("intro_feed_pcm", _voice(200))
	var intro: Node = scene.get("_intro")
	# 编排旁白由 IntroNarrator 独占音轨；点点的环境闲聊(greet/guide_hint/idle)在 intro 期间
	# 必须闭嘴，否则两个音源叠着孩子一句听不清（Bug①）。锁存：intro 未 done 时 _fairy_greeted 一旦为真即失败。
	if intro != null and not bool(intro.call("is_done")):
		if bool(scene.get("_fairy_greeted")):
			fairy_spoke_during_intro = true
		var fb: Variant = scene.get("_fairy_bubble")
		var fv: Variant = scene.get("fairy_voice")
		if (fb is Node3D and (fb as Node3D).visible) or (fv != null and bool(fv.call("is_playing"))):
			fairy_bubble_during_intro = true
	# Bug②视觉指引锁存：教学步会亮地面脉动光环(走路/靠近)与话筒 HUD(说话)
	var hint_node: Variant = scene.get("_intro_hint")
	if hint_node is Node3D and (hint_node as Node3D).visible:
		hint_ring_shown = true
	if scene.get("_intro_mic_hint") == true:
		mic_hint_shown = true
	if intro != null and bool(intro.call("is_done")):
		done = true
		_finish()

func _finish() -> void:
	_check("桌面/headless 说话步门禁未挡", bool(scene.call("intro_asr_blocked")), false)
	_check("教学:开口被本地 VAD 检测到", bool(scene.call("intro_heard_speech")), true)
	_check("教学:村民被近身触发挥手 emote", villager_emoted, true)
	_check("Bug①:intro 期间点点不抢旁白(环境闲聊被 gate)", fairy_spoke_during_intro, false)
	_check("Bug①:intro 期间点点无音符气泡/语音(视觉不抢拍)", fairy_bubble_during_intro, false)
	_check("Bug②:走路/靠近步亮过地面脉动光环", hint_ring_shown, true)
	_check("Bug②:说话步亮过话筒+声波 HUD", mic_hint_shown, true)
	_check("编排器完成转正", done, true)
	_check("首次演完标记 intro_seen（false→true）", PlayerProfile.intro_seen(), true)
	var demos := 0
	for d in (scene.get("npcs") as Array):
		if String(d.get("id", "")).begins_with("demo_"):
			demos += 1
	_check("离线转正保留 demo 占位村民", demos >= 3, true)
	if fails == 0:
		print("intro_tutorial tests PASS")
	else:
		printerr("intro_tutorial tests FAILED: %d" % fails)
	quit(fails)

## 440Hz 正弦、幅度 0.5（RMS≈0.35，远超 VAD 触发阈值）模拟人声，ms 毫秒。
func _voice(ms: int) -> PackedByteArray:
	var n := ms * VoiceVad.BYTES_PER_MS / 2
	var out := PackedByteArray()
	out.resize(n * 2)
	for i in range(n):
		var s := sin(TAU * 440.0 * float(i) / 16000.0) * 0.5
		var v := int(s * 32767.0)
		if v < 0:
			v += 65536
		out[i * 2] = v & 0xFF
		out[i * 2 + 1] = (v >> 8) & 0xFF
	return out

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
		fails += 1
