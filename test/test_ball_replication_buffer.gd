extends SceneTree
## BallReplicationBuffer 单测：窗内插值 / 到头按速度外推（含上限截断）/ 误差纠偏（平滑 vs snap / 首帧）/
## 失联判定 / 迟到样本丢弃。纯逻辑（不建节点、不联网），验证 C 档球复制缓冲区别于 A 档 hold 的外推行为。
## 运行: godot --headless --path . --script res://test/test_ball_replication_buffer.gd

func _init() -> void:
	var fails := 0

	# --- 空缓冲返回 fallback ---
	var b := BallReplicationBuffer.new()
	var fb := Vector2(3, 4)
	fails += _check("空缓冲返回 fallback", b.sample(1000, fb) == fb, true)
	fails += _check("空缓冲算陈旧", b.is_stale(0), true)
	fails += _check("空缓冲无样本", b.has_samples(), false)

	# --- 窗内插值：两样本间线性插值（用位置，不受速度影响）---
	b.push(1000, Vector2(10, 10), Vector2.ZERO, 1000)
	b.push(1100, Vector2(20, 10), Vector2(100, 0), 1100)
	fails += _check("有样本", b.has_samples(), true)
	# DELAY_MS=80：render=1130 → target=1050 → 位于 [1000,1100] 中点 → (15,10)
	var mid := b.sample(1130, Vector2.ZERO)
	fails += _approx("插值中点 x", mid.x, 15.0, 0.01)
	fails += _approx("插值中点 y", mid.y, 10.0, 0.01)

	# --- 早于最早样本 → 定在最早 ---
	var early := b.sample(1000, Vector2.ZERO) # target=920 < 1000
	fails += _approx("早于窗口定最早 x", early.x, 10.0, 0.01)

	# --- 到头外推：target 超过最新样本 → 按最新速度线性外推（非 hold）---
	# render=1280 → target=1200 → 超最新(1100) 100ms，速度(100,0) → (20,10)+(10,0)=(30,10)
	var extrap := b.sample(1280, Vector2.ZERO)
	fails += _approx("外推 100ms x", extrap.x, 30.0, 0.01)
	fails += _approx("外推 y 不漂", extrap.y, 10.0, 0.01)
	fails += _check("外推确实前进（非 hold 在 20）", extrap.x > 20.5, true)

	# --- 外推上限截断：render 极大 → dt 截到 EXTRAP_MAX_MS(250) → (20,10)+(25,0)=(45,10) ---
	var capped := b.sample(1000000, Vector2.ZERO)
	fails += _approx("外推上限截断 x", capped.x, 45.0, 0.01)

	# --- 迟到样本丢弃：t 不新于队尾直接丢，不破坏单调 ---
	b.push(1050, Vector2(999, 999), Vector2.ZERO, 1200) # t=1050 < 队尾1100 → 丢
	var still := b.sample(1130, Vector2.ZERO)
	fails += _approx("迟到样本被丢弃（插值不变）", still.x, 15.0, 0.01)

	# --- reconcile 首帧：current==INF → 直接落 target ---
	var target := Vector2(50, 50)
	fails += _check("首帧直接落 target", b.reconcile(Vector2.INF, target, 0.016) == target, true)
	fails += _check("delta<=0 直接落 target", b.reconcile(Vector2(0, 0), target, 0.0) == target, true)

	# --- reconcile 大误差 → snap（>= SNAP_DIST=4）---
	var snapped := b.reconcile(Vector2(10, 10), Vector2(20, 10), 0.016) # 误差 10 >= 4
	fails += _check("大误差 snap 到 target", snapped == Vector2(20, 10), true)

	# --- reconcile 小误差 → 平滑逼近（不硬跳，也没到 target）---
	# 误差 1 < 4；step=SMOOTH_RATE(18)*0.016=0.288 < 1 → 朝目标走 0.288
	var smooth := b.reconcile(Vector2(10, 10), Vector2(11, 10), 0.016)
	fails += _approx("平滑逼近前进 0.288", smooth.x, 10.288, 0.001)
	fails += _check("平滑未到 target", smooth.x < 11.0, true)
	fails += _check("平滑越过起点", smooth.x > 10.0, true)

	# --- reconcile 误差 <= 单帧步长 → 收到 target（大 delta）---
	var reach := b.reconcile(Vector2(10, 10), Vector2(11, 10), 1.0) # step=18 >= 误差1 → target
	fails += _check("步长够则收到 target", reach == Vector2(11, 10), true)

	# --- 失联判定：本地钟距上次收样超过 STALE_MS ---
	var s := BallReplicationBuffer.new()
	s.push(1000, Vector2(1, 1), Vector2.ZERO, 5000)
	fails += _check("刚收样不陈旧", s.is_stale(5000), false)
	fails += _check("窗内不陈旧", s.is_stale(5000 + BallReplicationBuffer.STALE_MS), false)
	fails += _check("超窗判陈旧", s.is_stale(5000 + BallReplicationBuffer.STALE_MS + 1), true)

	if fails == 0:
		print("ball_replication_buffer tests PASS")
	else:
		printerr("ball_replication_buffer tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _approx(name: String, got: float, want: float, tol: float) -> int:
	if absf(got - want) <= tol:
		return 0
	printerr("  FAIL %s: got %f want %f (±%f)" % [name, got, want, tol])
	return 1
