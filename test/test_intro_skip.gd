extends SceneTree
## P3：家长长按跳过（IntroDirector.skip）—— 建造演出段提前结束、直奔转正，且不破坏转正/标记。
## 断言：skip 后编排器仍完成（done + intro_seen），且完成得比不跳过的建造演出时长更早
## （BUILD_SHOW_SEC=2.0s≈20 帧@fixed-fps10；skip 后应在 ~个位数帧内完成 _sleep 段）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 60 \
##       --script res://test/test_intro_skip.gd

var scene: Node
var frame := 0
var fails := 0
var skip_frame := -1
var done := false

func _initialize() -> void:
	IntroDirector.pending = true
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null or done:
		return
	frame += 1
	var intro: Node = scene.get("_intro")
	if frame == 3 and intro != null:
		intro.call("skip") # 建造演出刚开演就长按跳过
		skip_frame = frame
	if intro != null and bool(intro.call("is_done")):
		done = true
		_finish()

func _finish() -> void:
	_check("skip 后编排器仍完成转正", done, true)
	_check("skip 后仍标记 intro_seen", PlayerProfile.intro_seen(), true)
	# skip 于 frame 3；不跳过建造演出约 20 帧。宽松上限 15 帧内完成 = skip 真的缩短了 _sleep。
	var elapsed := frame - skip_frame
	_check("skip 缩短了建造演出（%d 帧内完成）" % elapsed, elapsed <= 15, true)
	# skip 别停在半成品：小伙伴(压测负载)必须退场干净、散布植被必须已揭示（不停在空地）。
	var bench_residue := 0
	for n in (scene.get("npcs") as Array):
		if String((n as Dictionary).get("id", "")).begins_with("bench_"):
			bench_residue += 1
	_check("skip 后无 bench_ 小伙伴残留（负载退场干净）", bench_residue, 0)
	var props := scene.get_tree().get_nodes_in_group("perf_props")
	var any_vis := props.is_empty() # 无 props 视作通过（不该发生，别误伤）
	for pn in props:
		if (pn as Node3D).visible:
			any_vis = true
	_check("skip 后散布植被已揭示（不停在空地）", any_vis, true)
	if fails == 0:
		print("intro_skip tests PASS")
	else:
		printerr("intro_skip tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
		fails += 1
