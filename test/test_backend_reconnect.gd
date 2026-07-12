extends SceneTree
## Backend 自动重连退避（心跳+重连 P1）：不依赖真 server，直接驱动 _tick_reconnect 调度器
## 与纯函数 _next_backoff 验证退避序列、should_reconnect 门控。
## 运行: godot --headless --path . --script res://test/test_backend_reconnect.gd

func _init() -> void:
	var fails := 0
	var b := Backend.new()

	# ── _next_backoff：翻倍封顶 15s ──
	fails += _check("backoff 1→2", b._next_backoff(1.0), 2.0)
	fails += _check("backoff 2→4", b._next_backoff(2.0), 4.0)
	fails += _check("backoff 8→15(封顶)", b._next_backoff(8.0), 15.0)
	fails += _check("backoff 15→15(封顶)", b._next_backoff(15.0), 15.0)

	# ── connect_to_server：起意重连 + 退避复位 ──
	b._reconnect_backoff = 8.0 # 脏值
	b.connect_to_server()
	fails += _check("connect 置 should_reconnect", b._should_reconnect, true)
	fails += _check("connect 复位退避为 base", b._reconnect_backoff, 1.0)

	# ── disconnect_from_server：停掉重连 ──
	b.disconnect_from_server()
	fails += _check("disconnect 停 should_reconnect", b._should_reconnect, false)

	# ── _tick_reconnect 调度：should_reconnect=false 时永不重拨（退避不动）──
	b._should_reconnect = false
	b._reconnect_backoff = 1.0
	b._reconnect_wait = 0.0
	for i in range(5):
		b._tick_reconnect(1.0)
	fails += _check("不重连时退避不变", b._reconnect_backoff, 1.0)

	# ── _tick_reconnect 调度：should_reconnect=true 倒计时到点重拨 + 退避翻倍 ──
	b._should_reconnect = true
	b._reconnect_backoff = 1.0
	b._reconnect_wait = 1.0
	b._tick_reconnect(0.5) # 0.5<1.0：未到点，不重拨
	fails += _check("未到点退避不变", b._reconnect_backoff, 1.0)
	fails += _check("未到点倒计时递减", is_equal_approx(b._reconnect_wait, 0.5), true)
	b._tick_reconnect(0.6) # 累计 1.1≥1.0：到点重拨，退避翻倍、倒计时重置为新退避
	fails += _check("到点退避翻倍", b._reconnect_backoff, 2.0)
	fails += _check("到点倒计时重置为新退避", b._reconnect_wait, 2.0)
	b._tick_reconnect(2.0) # 再到点：4s
	fails += _check("二次退避翻倍", b._reconnect_backoff, 4.0)

	# ── _step_heartbeat：到点发 ping（用 sent 信号观测）──
	var pings: Array = []
	b.sent.connect(func(m: Dictionary) -> void:
		if m.get("type", "") == "ping": pings.append(m))
	b._ping_accum = 0.0
	b._since_rx = 0.0
	var timed_out := b._step_heartbeat(9.0, false) # 9<10：未到发 ping 点
	fails += _check("未到点不发 ping", pings.size(), 0)
	fails += _check("未超时", timed_out, false)
	b._step_heartbeat(1.5, false) # 累计 10.5≥10：发一条 ping
	fails += _check("到点发一条 ping", pings.size(), 1)

	# ── _step_heartbeat：收到回包复位活跃时钟，永不超时 ──
	b._since_rx = 25.0 # 逼近超时
	b._step_heartbeat(10.0, true) # got_rx=true → 复位
	fails += _check("收回包复位活跃时钟", b._since_rx, 0.0)

	# ── _step_heartbeat：持续无回包，超过 30s 判超时 ──
	b._since_rx = 0.0
	b._ping_accum = 0.0
	var died := false
	for i in range(40): # 40×1s=40s > 30s
		if b._step_heartbeat(1.0, false):
			died = true
			break
	fails += _check("持续无回包最终超时", died, true)

	b.free()
	if fails == 0:
		print("backend_reconnect tests PASS")
	else:
		printerr("backend_reconnect tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
