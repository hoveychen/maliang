extends SceneTree
## P3 骨架 + P4 非教学路径：IntroDirector 早揭幕(world_ready) + 顺序旁白建造演出 + fetch/apply 转正 +
## 标记 intro 已看过。本测走「返回用户/仅补画质档」分支（预置 intro_seen=true → 无教学段），验证
## 非教学演出能跑到底且骨架完好。教学段的检测由 test_intro_tutorial 驱动覆盖。
## 离线（api 连不上）：fetch 空 → apply 保留虚拟世界（demo 占位村民仍在）；采纳保守画质档。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 600 \
##       --script res://test/test_intro_director.gd

var scene: Node
var frame := 0
var fails := 0
var ready_fired := false
var checked_active := false
var done := false

func _initialize() -> void:
	IntroDirector.pending = true # 显式触发 intro（不依赖 should_run 的持久态，测试确定性）
	var p := PlayerProfile.load_profile() # 预置已看过引导 → _tutorial=false，走非教学演出（确定性 + 免驱动）
	p["intro_seen"] = true
	PlayerProfile.save_profile(p)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.connect("world_ready", func() -> void: ready_fired = true)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null or done:
		return
	frame += 1
	if frame == 3 and not checked_active:
		checked_active = true
		_check("intro 模式已激活", bool(scene.call("intro_active")), true)
		_check("pending 已消费", IntroDirector.pending, false)
	var intro: Node = scene.get("_intro")
	if intro != null and bool(intro.call("is_done")):
		done = true
		_finish()

func _finish() -> void:
	_check("早揭幕：world_ready 已发", ready_fired, true)
	_check("转正后 intro_seen 保持（mark 未清）", PlayerProfile.intro_seen(), true)
	_check("采纳画质档（has_saved 转真）", GraphicsSettings.has_saved(), true)
	var demos := 0
	for d in (scene.get("npcs") as Array):
		if String(d.get("id", "")).begins_with("demo_"):
			demos += 1
	_check("离线转正保留 demo 占位村民", demos >= 3, true)
	_check("online 仍 false（离线）", bool(scene.get("online")), false)
	if fails == 0:
		print("intro_director tests PASS")
	else:
		printerr("intro_director tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
		fails += 1
