extends SceneTree
## BallOwnership 所有权状态机单测：中立/踢者转移/滚停交回 + 逐端 simulates 权威判定。
## 纯状态机（不建节点、不联网）：验证「host 默认拥 + 踢击临时转踢者 + 滚停交回」的转移与共识语义。
## 运行: godot --headless --path . --script res://test/test_ball_ownership.gd

func _init() -> void:
	var fails := 0
	var HOST := "hostPid"
	var A := "playerA"
	var B := "playerB"

	# --- 初始中立：owner 为空，host 模拟、非 host 不模拟 ---
	var own := BallOwnership.new()
	fails += _check("初始中立", own.is_neutral(), true)
	fails += _check("初始 owner 空", own.owner(), "")
	fails += _check("中立态 host 模拟", own.simulates(HOST, true), true)
	fails += _check("中立态非 host 不模拟", own.simulates(A, false), false)

	# --- 踢击转移：owner→踢者；只有踢者模拟，host 与旁观者都让出 ---
	fails += _check("kick 发生转移返回 true", own.kick(A), true)
	fails += _check("owner 变踢者", own.owner(), A)
	fails += _check("非中立", own.is_neutral(), false)
	fails += _check("踢者本人模拟", own.simulates(A, false), true)
	fails += _check("host 不再模拟（已让给踢者）", own.simulates(HOST, true), false)
	fails += _check("旁观者不模拟", own.simulates(B, false), false)

	# --- 幂等：再踢同一人不算变化（不重复广播）---
	fails += _check("重复 kick 同人返回 false", own.kick(A), false)
	fails += _check("owner 不变", own.owner(), A)

	# --- 抢断：另一玩家踢 → 转移给新踢者 ---
	fails += _check("换人 kick 返回 true", own.kick(B), true)
	fails += _check("owner 变新踢者", own.owner(), B)
	fails += _check("新踢者模拟", own.simulates(B, false), true)
	fails += _check("原踢者不再模拟", own.simulates(A, false), false)

	# --- 滚停交回中立：settle → owner 空，host 重新模拟 ---
	fails += _check("settle 发生变化返回 true", own.settle(), true)
	fails += _check("交回后中立", own.is_neutral(), true)
	fails += _check("交回后 host 模拟", own.simulates(HOST, true), true)
	fails += _check("中立态重复 settle 返回 false", own.settle(), false)

	# --- 空 player_id（离线未注册）不转移：保持中立由 host 模拟 ---
	var off := BallOwnership.new()
	fails += _check("空 id kick 不转移", off.kick(""), false)
	fails += _check("仍中立", off.is_neutral(), true)
	fails += _check("离线 host（is_host=true）仍模拟", off.simulates("", true), true)

	# --- 踢者本人恰是 host：owner=自己，仍模拟（owner 命中优先于 host 判定）---
	var hk := BallOwnership.new()
	hk.kick(HOST)
	fails += _check("host 踢球后自己模拟", hk.simulates(HOST, true), true)

	if fails == 0:
		print("ball_ownership tests PASS")
	else:
		printerr("ball_ownership tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
