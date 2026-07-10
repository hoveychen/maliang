extends SceneTree
## RemoteActorBuffer 远端位置插值缓冲的独立测试（纯逻辑，见 remote_actor_buffer.gd）。
## 运行: Godot --headless --path . --script res://test/test_remote_actor_buffer.gd

func _init() -> void:
	var fails := 0

	# 空缓冲：返回 fallback
	var b0 := RemoteActorBuffer.new()
	fails += _vec("空缓冲返回 fallback", b0.sample(1000, Vector2(7, 8)), Vector2(7, 8))
	fails += _eq("空缓冲无样本", b0.has_samples(), false)
	fails += _eq("空缓冲算陈旧", b0.is_stale(0), true)

	# 两采样中点线性插值：t=0→(0,0), t=1000→(40,0)；DELAY_MS=200。
	# 采样间距取 <半环面（span/2=75），避免最短弧绕行——真实高频流采样本就相邻。
	# 渲染时刻 render=700 → target=500 → 半程 → (20,0)。
	var b := RemoteActorBuffer.new()
	b.push(0, Vector2(0, 0), 0)
	b.push(1000, Vector2(40, 0), 0)
	fails += _vec("中点插值", b.sample(700, Vector2.ZERO), Vector2(20, 0))
	# render=200 → target=0 → 落在最早样本
	fails += _vec("对齐最早样本", b.sample(200, Vector2.ZERO), Vector2(0, 0))
	# render 早于 (最早+DELAY) → 定在最早，不外推
	fails += _vec("早于窗口定最早", b.sample(100, Vector2.ZERO), Vector2(0, 0))
	# render 远晚于最新+DELAY → 定在最新，不外推
	fails += _vec("晚于窗口定最新", b.sample(5000, Vector2.ZERO), Vector2(40, 0))
	# 1/4 程：target=250 → (10,0)
	fails += _vec("四分位插值", b.sample(450, Vector2.ZERO), Vector2(10, 0))

	# 迟到样本（时戳不新于队尾）被丢弃，不破坏单调
	var b2 := RemoteActorBuffer.new()
	b2.push(1000, Vector2(10, 0), 0)
	b2.push(500, Vector2(999, 0), 0)   # 迟到：丢
	b2.push(1000, Vector2(999, 0), 0)  # 同时戳：丢
	b2.push(2000, Vector2(20, 0), 0)
	# render=1400 → target=1200 → 1000..2000 的 20% → 10 + (20-10)*0.2 = 12
	fails += _vec("迟到样本被丢-插值不受污染", b2.sample(1400, Vector2.ZERO), Vector2(12, 0))

	# 陈旧判定：超过 STALE_MS 无新样本
	var b3 := RemoteActorBuffer.new()
	b3.push(0, Vector2(1, 1), 1000)          # 本地钟 1000 收样
	fails += _eq("刚收样不陈旧", b3.is_stale(1500), false)
	fails += _eq("超时陈旧", b3.is_stale(1000 + RemoteActorBuffer.STALE_MS + 1), true)

	# 环面最短弧插值：跨接缝不瞬移（span-10 → 10 应向 +x 走 20，中点在接缝外侧绕回）
	var span := WorldGrid.WORLD_SPAN
	var b4 := RemoteActorBuffer.new()
	b4.push(0, Vector2(span - 10.0, 0.0), 0)
	b4.push(1000, Vector2(10.0, 0.0), 0)
	# render=700 → target=500 → 半程 → 从 span-10 前进 10 → wrap 到 0.0
	fails += _vec("跨接缝走最短弧", b4.sample(700, Vector2.ZERO), Vector2(0.0, 0.0))

	if fails == 0:
		print("remote_actor_buffer tests PASS")
	else:
		printerr("remote_actor_buffer tests FAILED: %d" % fails)
	quit(fails)

func _vec(name: String, got: Vector2, want: Vector2) -> int:
	if got.distance_to(want) < 0.01:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, got, want])
	return 1

func _eq(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
