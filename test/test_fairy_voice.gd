extends SceneTree
## FairyVoice 预制台词选择逻辑：触发器匹配 / 全局间隔 / 单条冷却 / 未知触发器。
## 注意：_ready 依赖节点入树，须在首帧（process_frame）里跑断言，不能在 _init。
## 运行: godot --headless --path . --script res://test/test_fairy_voice.gd

var fv: FairyVoice
var _ran := false

func _initialize() -> void:
	fv = FairyVoice.new()
	root.add_child(fv)
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	# 未知触发器：无台词可播
	fails += _check("unknown trigger", fv.try_play("no_such_trigger"), false)

	# 单条台词触发器（near_mountain，冷却 90s）：播放成功
	fv._t = 100.0
	fails += _check("mountain plays", fv.try_play("near_mountain"), true)
	fv._player.stop() # headless 无真实音频推进，手动停避免 is_playing 干扰

	# 全局间隔：GLOBAL_GAP 内一律闭嘴
	fv._t = 102.0
	fails += _check("global gap blocks", fv.try_play("idle"), false)

	# 间隔过了但单条冷却没过：near_mountain 仍不可播，idle 可播
	fv._t = 120.0
	fails += _check("cooldown blocks same line", fv.try_play("near_mountain"), false)
	fails += _check("can_play mirrors cooldown", fv.can_play("near_mountain"), false)
	fails += _check("idle plays meanwhile", fv.try_play("idle"), true)
	fv._player.stop()

	# 冷却结束：可再次播放
	fv._t = 200.0
	fails += _check("cooldown expired replays", fv.try_play("near_mountain"), true)
	fv._player.stop()

	# POI 数据完整性：world.gd 的每个 POI 触发器都有对应台词；
	# 全部台词的预制 WAV 都真实存在（防加词条忘跑 gen_voice_lines.mjs）。
	fv._t = 1000.0
	var world_script: GDScript = load("res://scripts/world.gd")
	for poi in world_script.POIS:
		var trig := String(poi["trigger"])
		fails += _check("poi has line: %s" % trig, fv.can_play(trig), true)

	# 点点人设触发器（fairy-persona P5）：world.gd 的造物生命周期与新交互会 try_play 这些触发词，
	# 每个都必须有台词——否则 world.gd 里拼错字（如 create_strat）会静默无声，现有测试抓不到。
	for trig in ["create_start", "create_fail", "create_done", "quiet", "bubble"]:
		fv._t += 100.0 # 逐个跳过全局间隔，各自独立验
		fails += _check("persona trigger has line: %s" % trig, fv.can_play(trig), true)
	for l in fv._lines:
		var wav := "%s/%s.wav" % [FairyVoice.VOICE_DIR, String(l["id"])]
		fails += _check("wav exists: %s" % l["id"], FileAccess.file_exists(wav), true)

	if fails == 0:
		print("fairy_voice tests PASS")
	else:
		printerr("fairy_voice tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
