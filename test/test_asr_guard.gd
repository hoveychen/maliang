extends SceneTree
## AsrGuard 门禁单测：Android 上端侧 ASR 缺失/失败必须判致命（硬报错），
## 桌面/编辑器合法走服务端（非致命）；block() 盖阻断层并暂停树。
## 运行: godot --headless --path . --script res://test/test_asr_guard.gd

func _init() -> void:
	var fails := 0

	# ── 致命判定：仅 Android 且不可用时致命 ──
	fails += _check("Android + 无单例 → 致命", AsrGuard.is_fatal("Android", false), true)
	fails += _check("Android + isReady 假 → 致命", AsrGuard.is_fatal("Android", false), true)
	fails += _check("Android + 可用 → 不致命", AsrGuard.is_fatal("Android", true), false)
	fails += _check("macOS + 无单例 → 不致命(合法走服务端)", AsrGuard.is_fatal("macOS", false), false)
	fails += _check("Linux + 无单例 → 不致命", AsrGuard.is_fatal("Linux", false), false)
	fails += _check("iOS + 无单例 → 不致命(暂不强制)", AsrGuard.is_fatal("iOS", false), false)

	fails += _check("asr_required(Android)", AsrGuard.asr_required("Android"), true)
	fails += _check("asr_required(macOS)", AsrGuard.asr_required("macOS"), false)

	# ── utterance 阶段：Android 未就绪必须等待，绝不回落服务端上传 PCM ──
	# （加载失败走 asr_error 硬报错；这里的未就绪只可能是 initialize() 异步没跑完）
	fails += _check("Android + 未就绪 → 必须等", AsrGuard.must_wait_for_ready("Android", false), true)
	fails += _check("Android + 已就绪 → 不等", AsrGuard.must_wait_for_ready("Android", true), false)
	fails += _check("macOS + 未就绪 → 不等(合法走服务端)", AsrGuard.must_wait_for_ready("macOS", false), false)
	fails += _check("iOS + 未就绪 → 不等", AsrGuard.must_wait_for_ready("iOS", false), false)

	# ── block()：盖阻断层 + 暂停树；幂等只刷新文案 ──
	AsrGuard.block(self, "错误A")
	var overlay := root.get_node_or_null("AsrFatalOverlay")
	fails += _check("block 后有阻断层", overlay != null, true)
	fails += _check("block 后树暂停", paused, true)
	var lbl := root.get_node_or_null("AsrFatalOverlay/BG/Msg")
	fails += _check("阻断层文案=错误A", (lbl as Label).text if lbl is Label else "", "错误A")

	AsrGuard.block(self, "错误B")
	var overlays := 0
	for c in root.get_children():
		if c.name == "AsrFatalOverlay":
			overlays += 1
	fails += _check("幂等：仍只有一层阻断层", overlays, 1)
	fails += _check("幂等：文案刷新为错误B", (lbl as Label).text if lbl is Label else "", "错误B")

	# 收尾：解暂停 + 清理，避免影响进程退出
	paused = false
	if overlay != null:
		overlay.free()

	if fails == 0:
		print("asr_guard tests PASS")
	else:
		printerr("asr_guard tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got=%s want=%s" % [name, str(got), str(want)])
	return 1
