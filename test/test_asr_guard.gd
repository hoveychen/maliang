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
	# iOS 上端侧 ASR 是硬依赖：没有 editor 形态（iOS 只可能是导出包），静态库+模型必随包，
	# 缺了就是哑巴包——服务端 ASR 已退役，没有回落路径。故与 Android 同档：恒 required。
	fails += _check("iOS + 无单例 → 致命(坏包)", AsrGuard.is_fatal("iOS", false), true)
	fails += _check("iOS + 可用 → 不致命", AsrGuard.is_fatal("iOS", true), false)

	fails += _check("asr_required(Android)", AsrGuard.asr_required("Android"), true)
	fails += _check("asr_required(macOS)", AsrGuard.asr_required("macOS"), false)
	fails += _check("asr_required(iOS)", AsrGuard.asr_required("iOS"), true)
	fails += _check("asr_required(iOS, 导出)", AsrGuard.asr_required("iOS", true), true)

	# ── macOS：仅导出构建(is_template)才 required——editor/headless 不受门禁约束 ──
	# 否则整套 headless 回测会因 worktree/源码没随包模型被 block。真识别路径见 macos_asr_recognize.gd。
	fails += _check("asr_required(macOS, 非导出)", AsrGuard.asr_required("macOS", false), false)
	fails += _check("asr_required(macOS, 导出)", AsrGuard.asr_required("macOS", true), true)
	fails += _check("asr_required(Android, 导出)", AsrGuard.asr_required("Android", true), true)
	fails += _check("asr_required(Android, 非导出)", AsrGuard.asr_required("Android", false), true)
	# 导出 macOS 缺单例/模型 → 致命(坏包硬报错)；非导出缺失 → 不致命(合法走服务端)
	fails += _check("导出 macOS + 无单例 → 致命", AsrGuard.is_fatal("macOS", false, true), true)
	fails += _check("导出 macOS + 可用 → 不致命", AsrGuard.is_fatal("macOS", true, true), false)
	fails += _check("非导出 macOS + 无单例 → 不致命", AsrGuard.is_fatal("macOS", false, false), false)
	# 导出 macOS 未就绪必须等；非导出 macOS 从不等(服务端合法)
	fails += _check("导出 macOS + 未就绪 → 必须等", AsrGuard.must_wait_for_ready("macOS", false, true), true)
	fails += _check("导出 macOS + 已就绪 → 不等", AsrGuard.must_wait_for_ready("macOS", true, true), false)
	fails += _check("非导出 macOS + 未就绪 → 不等", AsrGuard.must_wait_for_ready("macOS", false, false), false)

	# ── utterance 阶段：Android 未就绪必须等待，绝不回落服务端上传 PCM ──
	# （加载失败走 asr_error 硬报错；这里的未就绪只可能是 initialize() 异步没跑完）
	fails += _check("Android + 未就绪 → 必须等", AsrGuard.must_wait_for_ready("Android", false), true)
	fails += _check("Android + 已就绪 → 不等", AsrGuard.must_wait_for_ready("Android", true), false)
	fails += _check("macOS + 未就绪 → 不等(合法走服务端)", AsrGuard.must_wait_for_ready("macOS", false), false)
	fails += _check("iOS + 未就绪 → 必须等", AsrGuard.must_wait_for_ready("iOS", false), true)
	fails += _check("iOS + 已就绪 → 不等", AsrGuard.must_wait_for_ready("iOS", true), false)

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
