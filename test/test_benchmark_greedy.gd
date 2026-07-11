extends SceneTree
## 贪心求解的决策逻辑：注入 p95 序列（不依赖 GPU），断言它降对了旋钮、该停手时停手。
##
## 手法：Benchmark 实例不入树（不触发 _ready → 不 spawn 负载 / 不动 max_fps），只喂 _advance()。
## _apply_graphics_key 仍打到真实 world 上，所以「最终档真的被应用」也一并验证。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_benchmark_greedy.gd

var world: Node
var frame := 0
var fails := 0
var _backup: Dictionary

func _initialize() -> void:
	_backup = PlayerProfile.load_profile()
	PlayerProfile.clear()
	world = load("res://main.tscn").instantiate()
	root.add_child(world)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame != 10:
		if frame == 14:
			if _backup.is_empty():
				PlayerProfile.clear()
			else:
				PlayerProfile.save_profile(_backup)
			if fails == 0:
				print("benchmark_greedy PASS")
			else:
				printerr("benchmark_greedy FAILED: %d" % fails)
		elif frame == 16:
			quit(fails)
		return

	# —— 场景 A：强机。基线就达标 → 一个旋钮都不许降 ——
	var a := _make_bench()
	var a_got := _catch(a)  # lambda 按值捕获局部变量，只能往 Dictionary 里塞
	a._advance(20.0)  # 基线 20ms ≤ 33.3ms 达标线
	_check("强机：立即收工", a._done, true)
	_check("强机：零试降（只测了基线）", a._measures, 0)
	_check("强机：画质全保最高", _all_max(a_got["levels"]), true)
	_check("强机：上报 p95=20", is_equal_approx(float(a_got["p95"]), 20.0), true)

	# —— 场景 B：中机。只有角色阴影是瓶颈 → 只降它，达标即停 ——
	var b := _make_bench()
	var b_got := _catch(b)
	b._advance(45.0)  # 基线 45ms，未达标 → 开第一轮试降
	var guard := 0
	while not b._done and guard < 40:
		guard += 1
		# 关角色阴影收益巨大（45→25），其余旋钮关了几乎没用（45→44）
		b._advance(25.0 if b._trial_key == "actor_shadows" else 44.0)
	var b_levels: Dictionary = b_got["levels"]
	_check("中机：收敛（未死循环）", b._done, true)
	_check("中机：降了角色阴影", int(b_levels.get("actor_shadows", -1)), 0)
	_check("中机：没有误伤其他旋钮", _all_max_except(b_levels, ["actor_shadows"]), true)
	_check("中机：一轮 9 次试降后达标即停", b._measures, 9)

	# —— 场景 C（老板的约束）：瓶颈不在画质旋钮。每个都关了也只提升 0.5ms →
	# 低于 MIN_GAIN_MS 门槛，宁可不达标也不白掉画质 ——
	var c := _make_bench()
	var c_got := _catch(c)
	c._advance(50.0)  # 基线 50ms，未达标
	guard = 0
	while not c._done and guard < 40:
		guard += 1
		c._advance(49.5)  # 每个旋钮试降都只赚 0.5ms（< 1.5ms 门槛）
	var c_p95 := float(c_got["p95"])
	_check("瓶颈不在旋钮：停手", c._done, true)
	_check("瓶颈不在旋钮：一档都不降（保画质）", _all_max(c_got["levels"]), true)
	_check("瓶颈不在旋钮：如实上报未达标 p95", is_equal_approx(c_p95, 50.0), true)
	_check("瓶颈不在旋钮：p95 确实超线", c_p95 > GraphicsSettings.TARGET_FRAME_MS, true)

	# —— 场景 D：最弱机。每关一个都有明显收益、但怎么降都追不上达标线 →
	# 测量预算（MAX_MEASURES）兜底收手，交出当前最优档，如实上报未达标 ——
	var d := _make_bench()
	var d_got := _catch(d)
	d._advance(200.0)  # 基线 200ms，怎么降都追不上达标线
	guard = 0
	while not d._done and guard < 80:
		guard += 1
		d._advance(d._cur_ms - 10.0)  # 每个候选都比当前档快 10ms → 每轮必采纳
	var d_levels: Dictionary = d_got["levels"]
	var lowered := 0
	for k: String in GraphicsSettings.KEYS:
		if int(d_levels.get(k, -1)) < GraphicsSettings.max_level(k):
			lowered += 1
	_check("最弱机：收敛（未死循环）", d._done, true)
	_check("最弱机：预算兜底，测量次数不超上限", d._measures <= Benchmark.MAX_MEASURES, true)
	_check("最弱机：确实降了几档（每档都有明显收益）", lowered > 0, true)
	_check("最弱机：如实上报未达标", float(d_got["p95"]) > GraphicsSettings.TARGET_FRAME_MS, true)

## finished 的结果收进 Dictionary——GDScript lambda 按值捕获，直接给局部变量赋值外面看不到。
func _catch(b: Benchmark) -> Dictionary:
	var got := {"levels": {}, "p95": -1.0}
	b.finished.connect(func(lv: Dictionary, p: float) -> void:
		got["levels"] = lv.duplicate()
		got["p95"] = p)
	return got

func _make_bench() -> Benchmark:
	var b := Benchmark.new()  # 不入树：不跑 _ready，不塞负载、不动 max_fps
	b._world = world
	b._levels = GraphicsSettings.all_max()
	return b

func _all_max(levels: Dictionary) -> bool:
	return _all_max_except(levels, [])

func _all_max_except(levels: Dictionary, skip: Array) -> bool:
	for k: String in GraphicsSettings.KEYS:
		if skip.has(k):
			continue
		if int(levels.get(k, -1)) != GraphicsSettings.max_level(k):
			return false
	return true

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
