extends SceneTree
## WorldScript.pick_clip 的纯函数测试：按角色状态选动画段（talking > moving > idle），
## 走路用滞回阈值（进 0.30 / 出 0.12）。
## 运行: Godot --headless --path . --script res://test/test_anim_clip_pick.gd

const WorldScript := preload("res://scripts/world.gd")

var _fails := 0

func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s want %s" % [got, want])

func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s: %s" % [name, detail])
		_fails += 1

## 只取段名（丢掉返回的 moving 态）。
func _clip(speaking: bool, walk: float, was_moving: bool) -> String:
	return String(WorldScript.pick_clip(speaking, walk, was_moving)[0])

func _moving(speaking: bool, walk: float, was_moving: bool) -> bool:
	return bool(WorldScript.pick_clip(speaking, walk, was_moving)[1])

func _init() -> void:
	# ── 基本三态 ──
	_eq("站着不动 → idle", _clip(false, 0.0, false), "idle")
	_eq("走起来 → moving", _clip(false, 0.9, false), "moving")
	_eq("说话 → talking", _clip(true, 0.0, false), "talking")

	# ── 优先级：说话压过走路（边走边被搭话时，嘴动比腿动重要）──
	_eq("边走边说 → talking（不是 moving）", _clip(true, 0.9, true), "talking")
	# 但 moving 态要照常维护：说完话若还在走，应立刻回到 moving 而不是 idle
	_eq("说话时仍记住在走", _moving(true, 0.9, true), true)
	_eq("说完还在走 → moving", _clip(false, 0.9, true), "moving")

	# ── 滞回：进 0.30 / 出 0.12 ──
	# 阈值带内（0.12 ~ 0.30）保持原状：这正是滞回的意义——单阈值会在这一带来回抖段
	_eq("带内且原本静止 → 仍 idle", _clip(false, 0.2, false), "idle")
	_eq("带内且原本在走 → 仍 moving", _clip(false, 0.2, true), "moving")
	# 刚好在阈值上（严格大于才进、严格小于才出）
	_eq("恰好 0.30 不进 moving", _clip(false, 0.30, false), "idle")
	_eq("越过 0.30 才进 moving", _clip(false, 0.31, false), "moving")
	_eq("恰好 0.12 不退出 moving", _clip(false, 0.12, true), "moving")
	_eq("落到 0.12 以下才回 idle", _clip(false, 0.11, true), "idle")

	# ── 起步→刹车全程不该出现抖动 ──
	# 走路强度缓慢升到 1 再缓慢降回 0：段序列必须是 idle...moving...idle，
	# 中间不能有任何来回跳（那就是滞回没生效）。
	var seq: Array[String] = []
	var mv := false
	var w := 0.0
	while w <= 1.0:
		var r := WorldScript.pick_clip(false, w, mv)
		mv = bool(r[1])
		seq.append(String(r[0]))
		w += 0.02
	while w >= 0.0:
		var r2 := WorldScript.pick_clip(false, w, mv)
		mv = bool(r2[1])
		seq.append(String(r2[0]))
		w -= 0.02
	# 数「段名发生变化」的次数：一次起步 + 一次停步 = 恰好 2 次
	var switches := 0
	for i in range(1, seq.size()):
		if seq[i] != seq[i - 1]:
			switches += 1
	_eq("加速再减速全程只切段 2 次（起步+停步）", switches, 2)
	_eq("起点是 idle", seq[0], "idle")
	_eq("终点回到 idle", seq[seq.size() - 1], "idle")

	# ── 踏步弹跳（走路观感是程序化的，没有 moving 图集段）──
	# 站着不能颠；走起来要颠；只往上不往下（否则角色会被压进地里）；一个摇摆周期颠两下
	# （左右脚各落一次地）。
	_eq("站着不颠", WorldScript.walk_bob(0.0, 1.234), 0.0)
	var peak := WorldScript.walk_bob(1.0, PI / 2.0)
	_ok("走起来会颠", peak > 0.0, "峰值 %f" % peak)
	var lowest := 1.0
	var bumps := 0
	var prev := WorldScript.walk_bob(1.0, -0.05)
	var rising_prev := false
	for i in range(200): # 扫一个完整摇摆周期 [0, TAU)
		var ph := float(i) / 200.0 * TAU
		var b: float = WorldScript.walk_bob(1.0, ph)
		lowest = minf(lowest, b)
		var rising := b > prev
		if rising_prev and not rising:
			bumps += 1 # 由升转降 = 一个波峰
		rising_prev = rising
		prev = b
	_ok("弹跳恒不为负（不会把角色压进地里）", lowest >= 0.0, "最低 %f" % lowest)
	_eq("一个摇摆周期颠两下（左右脚各一次）", bumps, 2)
	var half := WorldScript.walk_bob(0.5, PI / 2.0)
	_ok("幅度随走路强度缩放", is_equal_approx(half, peak * 0.5), "%f vs %f/2" % [half, peak])

	if _fails == 0:
		print("anim_clip_pick tests PASS")
	else:
		printerr("anim_clip_pick tests FAILED: %d" % _fails)
	quit(_fails)
