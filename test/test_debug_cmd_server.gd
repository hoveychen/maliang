extends SceneTree
## 端侧语音 e2e 注入 harness P2：debug TCP 命令服务器。验证：
##  1) parse_command 纯函数：合法命令解析出 op+args；坏 JSON/缺 op/缺参/未知 op 都拒（与 IO 分离）；
##  2) synth_pcm 纯函数：长度/采样率正确；
##  3) _execute("say") 走【真实链路】：ScriptedAsr 排文本 + 合成 PCM 喂真 VAD 断句 → local_final 出预排文本；
##     门禁生效（未开麦时 say 不喂、报 gate_closed）；
##  4) _execute("state") 快照含 naming_item/bag/vc 各态；confirm 三键路由到 _vc。
## 运行: godot --headless --path . --script res://test/test_debug_cmd_server.gd

## stub 宿主：DebugCmdServer 只从 world 懒查 _vc 与几个状态字段，内部类声明它们即可被 get() 读到。
class StubWorld extends Node:
	var _vc: VoiceCapture = null
	var _naming_item := "梯子"
	var banner: Label = null
	var bag := {}
	var selected: Node = null
	# harness 命令路由记录（talk_fairy / reset_budget 由 _execute 转调这两个方法）
	var talk_fairy_calls := 0
	var reset_budget_calls := 0
	func harness_talk_fairy() -> bool:
		talk_fairy_calls += 1
		return true
	func harness_reset_play_budget() -> void:
		reset_budget_calls += 1
	# 摄影钩子（photo/scene 命令路由记录）
	var photo_args := []
	var scene_ids := []
	func harness_photo(args: Dictionary) -> Dictionary:
		photo_args.append(args)
		return {"hud": bool(args.get("hud", true)), "photo_cam": args.has("cam")}
	func harness_enter_scene(id: String) -> bool:
		scene_ids.append(id)
		return true
	var teleports := []
	func harness_teleport(tile: Vector2i, near: bool) -> bool:
		teleports.append([tile, near])
		return true

var _ran := false

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ✓ %s" % name)
		return 0
	printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	print("[parse_command：合法命令]")
	var say := DebugCmdServer.parse_command('{"op":"say","text":"爬爬梯"}')
	fails += _check("say ok", say.get("ok"), true)
	fails += _check("say op", say.get("op"), "say")
	fails += _check("say text", say.get("text"), "爬爬梯")
	var tap := DebugCmdServer.parse_command('{"op":"tap","x":100,"y":200.5}')
	fails += _check("tap ok", tap.get("ok"), true)
	fails += _check("tap x", tap.get("x"), 100.0)
	fails += _check("tap y", tap.get("y"), 200.5)
	for op in ["state", "screencap", "accept", "replay", "retry", "talk_fairy", "reset_budget"]:
		var r := DebugCmdServer.parse_command('{"op":"%s"}' % op)
		fails += _check("%s ok" % op, r.get("ok"), true)
		fails += _check("%s op" % op, r.get("op"), op)

	print("[parse_command：photo/scene（menu 相册拍摄）]")
	var ph := DebugCmdServer.parse_command('{"op":"photo","hud":false,"pitch":28,"yaw":0.6,"dist":22}')
	fails += _check("photo ok", ph.get("ok"), true)
	fails += _check("photo hud", ph.get("hud"), false)
	fails += _check("photo cam pitch", (ph.get("cam") as Dictionary).get("pitch"), 28.0)
	fails += _check("photo cam lift 缺省", (ph.get("cam") as Dictionary).get("lift"), 0.0)
	var ph2 := DebugCmdServer.parse_command('{"op":"photo","clear_cam":true}')
	fails += _check("photo clear_cam", ph2.get("clear_cam"), true)
	fails += _check("photo 只 clear 不带 cam 键", ph2.has("cam"), false)
	var sc := DebugCmdServer.parse_command('{"op":"scene","id":"forest"}')
	fails += _check("scene ok", sc.get("ok"), true)
	fails += _check("scene id", sc.get("id"), "forest")
	fails += _check("scene 缺 id 拒", DebugCmdServer.parse_command('{"op":"scene"}').get("ok"), false)
	var tp := DebugCmdServer.parse_command('{"op":"teleport","tileX":37,"tileY":40}')
	fails += _check("teleport ok", tp.get("ok"), true)
	fails += _check("teleport tileX", tp.get("tileX"), 37)
	fails += _check("teleport near 缺省 false", tp.get("near"), false)
	fails += _check("teleport near=true 免坐标",
		DebugCmdServer.parse_command('{"op":"teleport","near":true}').get("ok"), true)
	fails += _check("teleport 缺参拒", DebugCmdServer.parse_command('{"op":"teleport"}').get("ok"), false)

	print("[parse_command：非法输入全部拒]")
	fails += _check("空行拒", DebugCmdServer.parse_command("   ").get("ok"), false)
	fails += _check("坏 JSON 拒", DebugCmdServer.parse_command("{not json").get("ok"), false)
	fails += _check("非对象拒", DebugCmdServer.parse_command("[1,2,3]").get("ok"), false)
	fails += _check("缺 op 拒", DebugCmdServer.parse_command('{"text":"x"}').get("ok"), false)
	fails += _check("say 缺 text 拒", DebugCmdServer.parse_command('{"op":"say"}').get("ok"), false)
	fails += _check("say 空 text 拒", DebugCmdServer.parse_command('{"op":"say","text":""}').get("ok"), false)
	fails += _check("tap 缺 y 拒", DebugCmdServer.parse_command('{"op":"tap","x":1}').get("ok"), false)
	fails += _check("未知 op 拒", DebugCmdServer.parse_command('{"op":"nope"}').get("ok"), false)

	print("[synth_pcm：长度/采样率]")
	# 30ms @ 16k mono 16bit = 16*30 样本 * 2 字节 = 960 字节
	fails += _check("30ms 长度", DebugCmdServer.synth_pcm(30, 0.3).size(), 960)
	fails += _check("0ms 空", DebugCmdServer.synth_pcm(0, 0.3).size(), 0)

	print("[_execute say：真实注入链路 → local_final 出预排文本]")
	# 走真实 ScriptedAsr 注入（同 test_scripted_asr）：写 flag → VoiceCapture 注替身。
	var flag := FileAccess.open("user://asr_harness", FileAccess.WRITE)
	if flag != null:
		flag.store_string("1"); flag.close()
	var world := StubWorld.new()
	world.banner = Label.new()
	world.banner.text = "想说什么就直接跟点点说吧"
	world.banner.visible = true
	root.add_child(world)
	var vc := VoiceCapture.new()
	world._vc = vc
	world.add_child(vc) # _ready → debug+flag → 注 ScriptedAsr
	fails += _check("flag 注入了 ScriptedAsr", vc._asr is ScriptedAsr, true)
	var finals: Array[String] = []
	vc.local_final.connect(func(t: String) -> void: finals.append(t))
	var gate := [false]
	vc.should_capture = func() -> bool: return gate[0]
	var srv := DebugCmdServer.make(world)
	root.add_child(srv)

	# 门禁关（未开麦）：say 排了文本但不喂，报 gate_closed。
	var r_closed := srv._execute({"ok": true, "op": "say", "text": "爬爬梯"})
	fails += _check("门禁关时不喂", r_closed.get("fed"), false)
	fails += _check("门禁关时排队 +1", r_closed.get("pending"), 1)
	fails += _check("门禁关时不出 final", finals.size(), 0)

	# 开麦 + 门禁放行：say 喂 PCM 驱 VAD 断句 → ScriptedAsr 吐队首 → local_final。
	vc.open()
	gate[0] = true
	var r_fed := srv._execute({"ok": true, "op": "say", "text": "大风车"})
	fails += _check("门禁开时喂了", r_fed.get("fed"), true)
	# 队列此刻：["爬爬梯"(上轮没喂), "大风车"]；断一次句吐队首"爬爬梯"。
	fails += _check("断句吐队首经真实链路出 local_final", finals, ["爬爬梯"])

	print("[_execute state：状态快照]")
	var snap := srv._execute({"ok": true, "op": "state"})
	fails += _check("naming_item", snap.get("naming_item"), "梯子")
	fails += _check("bag_size", snap.get("bag_size"), 0)
	fails += _check("banner_text", snap.get("banner_text"), "想说什么就直接跟点点说吧")
	fails += _check("banner_visible", snap.get("banner_visible"), true)
	fails += _check("selected 空", snap.get("selected"), "")
	fails += _check("scene_id 宿主无字段兜底空", snap.get("scene_id"), "")
	fails += _check("transitioning 宿主无字段兜底 false", snap.get("transitioning"), false)
	fails += _check("vc_open", snap.get("vc_open"), true)
	fails += _check("asr_pending 剩1(大风车)", snap.get("asr_pending"), 1)

	print("[_execute 确认三键：路由到 _vc 不崩]")
	# 非确认态调 retry/accept 是 no-op（_vc 内部 guard），只验路由通、回包带 vc_confirming。
	var r_retry := srv._execute({"ok": true, "op": "retry"})
	fails += _check("retry 回包", r_retry.get("ok"), true)
	fails += _check("retry 后未在确认", r_retry.get("vc_confirming"), false)

	print("[_execute talk_fairy / reset_budget：路由到宿主 harness 钩子]")
	var r_tf := srv._execute({"ok": true, "op": "talk_fairy"})
	fails += _check("talk_fairy 回包 ok", r_tf.get("ok"), true)
	fails += _check("talk_fairy entered", r_tf.get("entered"), true)
	fails += _check("talk_fairy 转调宿主一次", world.talk_fairy_calls, 1)
	var r_rb := srv._execute({"ok": true, "op": "reset_budget"})
	fails += _check("reset_budget 回包 ok", r_rb.get("ok"), true)
	fails += _check("reset_budget 转调宿主一次", world.reset_budget_calls, 1)

	print("[_execute photo / scene：路由到宿主摄影钩子]")
	var r_ph := srv._execute(DebugCmdServer.parse_command('{"op":"photo","hud":false,"pitch":30,"dist":20}'))
	fails += _check("photo 回包 ok", r_ph.get("ok"), true)
	fails += _check("photo 转调宿主一次", world.photo_args.size(), 1)
	fails += _check("photo 透传 hud", (world.photo_args[0] as Dictionary).get("hud"), false)
	fails += _check("photo 透传 cam dist",
		((world.photo_args[0] as Dictionary).get("cam") as Dictionary).get("dist"), 20.0)
	var r_sc := srv._execute({"ok": true, "op": "scene", "id": "forest"})
	fails += _check("scene 回包 ok", r_sc.get("ok"), true)
	fails += _check("scene 转调宿主", world.scene_ids, ["forest"])
	var r_tp := srv._execute(DebugCmdServer.parse_command('{"op":"teleport","near":true}'))
	fails += _check("teleport 回包 ok", r_tp.get("ok"), true)
	fails += _check("teleport 透传 near", (world.teleports[0] as Array)[1], true)

	print("[autoload 路径：_world=null 时 talk_fairy/reset_budget 经 current_scene 兜底]")
	# 真机上 HarnessCmd 是 [autoload]，由 Godot 默认构造（不走 make）→ _world 恒为 null；
	# 命令必须回退到 get_tree().current_scene（在 world 场景即 world 节点）才能路由到宿主钩子。
	# 不兜底则 talk_fairy/reset_budget 在真机上全废（voice-e2e 的进对话入口断掉）。
	var auto_srv := DebugCmdServer.new()  # 不走 make → _world 保持 null（复现 autoload 构造）
	root.add_child(auto_srv)
	var prev_scene := current_scene       # 本脚本 extends SceneTree，current_scene 即 tree 自身属性
	current_scene = world                 # 模拟「当前活跃场景就是 world」（srv._do_* 内走 get_tree().current_scene）
	var r_tf2 := auto_srv._execute({"ok": true, "op": "talk_fairy"})
	fails += _check("autoload talk_fairy 回包 ok", r_tf2.get("ok"), true)
	fails += _check("autoload talk_fairy 经 current_scene 转调宿主", world.talk_fairy_calls, 2)
	var r_rb2 := auto_srv._execute({"ok": true, "op": "reset_budget"})
	fails += _check("autoload reset_budget 回包 ok", r_rb2.get("ok"), true)
	fails += _check("autoload reset_budget 经 current_scene 转调宿主", world.reset_budget_calls, 2)
	current_scene = prev_scene
	auto_srv.queue_free()

	vc.close(); vc.queue_free()
	srv.queue_free()
	world.queue_free()
	DirAccess.remove_absolute("user://asr_harness")

	if fails == 0:
		print("test_debug_cmd_server: 全部通过")
	else:
		printerr("test_debug_cmd_server: %d 处失败" % fails)
	quit(1 if fails > 0 else 0)
