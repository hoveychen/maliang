extends SceneTree
## MicPermission 门禁单测：仅 iOS + 能查到权限 + 拒绝 才拦；非 iOS/缺单例/未定/授予都不拦；
## block/clear 盖层+暂停 / 移除+解暂停，幂等。
## 运行: godot --headless --path . --script res://test/test_mic_permission.gd

func _init() -> void:
	var fails := 0

	# ── should_block 纯判定 ──
	fails += _check("iOS+拒+有单例 → 拦", MicPermission.should_block("iOS", MicPermission.STATUS_DENIED, true), true)
	fails += _check("iOS+授+有单例 → 不拦", MicPermission.should_block("iOS", MicPermission.STATUS_GRANTED, true), false)
	fails += _check("iOS+未定+有单例 → 不拦", MicPermission.should_block("iOS", MicPermission.STATUS_UNDETERMINED, true), false)
	# 查不到权限（缺单例/老包）绝不误伤：宁可不拦
	fails += _check("iOS+拒+缺单例 → 不拦", MicPermission.should_block("iOS", MicPermission.STATUS_DENIED, false), false)
	fails += _check("Android+拒 → 不拦", MicPermission.should_block("Android", MicPermission.STATUS_DENIED, true), false)
	fails += _check("macOS+拒 → 不拦", MicPermission.should_block("macOS", MicPermission.STATUS_DENIED, true), false)
	fails += _check("Linux+拒 → 不拦", MicPermission.should_block("Linux", MicPermission.STATUS_DENIED, true), false)

	# ── query_status：headless 无 MaliangAsr 单例 → 视为已授予（不拦） ──
	fails += _check("缺单例 query_status → 已授予", MicPermission.query_status(), MicPermission.STATUS_GRANTED)

	# ── enforce：本机是 macOS/Linux headless（非 iOS）→ 恒不拦、不盖层 ──
	fails += _check("enforce(本机非iOS) → 不拦", MicPermission.enforce(self), false)
	fails += _check("enforce 后无引导层", root.get_node_or_null("MicPermissionOverlay") == null, true)
	fails += _check("enforce 后树未暂停", paused, false)

	# ── block/clear：盖层 + 暂停；幂等；clear 移除 + 解暂停 ──
	MicPermission.block(self)
	fails += _check("block 后有引导层", root.get_node_or_null("MicPermissionOverlay") != null, true)
	fails += _check("block 后树暂停", paused, true)

	MicPermission.block(self) # 幂等
	var overlays := 0
	for c in root.get_children():
		if c.name == "MicPermissionOverlay":
			overlays += 1
	fails += _check("幂等：仍只有一层引导层", overlays, 1)

	var overlay := root.get_node_or_null("MicPermissionOverlay")
	MicPermission.clear(self)
	fails += _check("clear 后解暂停", paused, false)
	fails += _check("clear 后引导层待移除", overlay.is_queued_for_deletion() if overlay != null else false, true)

	# 收尾：确保解暂停，别影响退出
	paused = false

	if fails == 0:
		print("mic_permission tests PASS")
	else:
		printerr("mic_permission tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got=%s want=%s" % [name, str(got), str(want)])
	return 1
