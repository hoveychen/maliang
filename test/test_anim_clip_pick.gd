extends SceneTree
## WorldScript.pick_clip 的纯函数测试：按角色状态选动画段（talking > moving > idle），
## 走路用滞回阈值（进 0.30 / 出 0.12）。
## 运行: Godot --headless --path . --script res://test/test_anim_clip_pick.gd

const WorldScript := preload("res://scripts/world.gd")

var _fails := 0

func _eq(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s: got %s want %s" % [name, got, want])
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

	if _fails == 0:
		print("anim_clip_pick tests PASS")
	else:
		printerr("anim_clip_pick tests FAILED: %d" % _fails)
	quit(_fails)
