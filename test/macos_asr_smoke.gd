extends SceneTree
## P1 冒烟：验证 macOS GDExtension 被 Godot 4.6 加载、MaliangAsr 单例可达且接口正确。
## 跑法：Godot --headless --path <worktree> --script res://test/macos_asr_smoke.gd
## 成功打印 "P1 PASS" 并 quit(0)；任一断言失败 quit(1)。

func _initialize() -> void:
	var fail := func(msg: String) -> void:
		push_error("[P1 FAIL] " + msg)
		printerr("[P1 FAIL] " + msg)
		quit(1)

	if OS.get_name() != "macOS":
		fail.call("本冒烟仅在 macOS 有意义，当前 = " + OS.get_name())
		return

	if not Engine.has_singleton("MaliangAsr"):
		fail.call("Engine.has_singleton(\"MaliangAsr\") == false —— GDExtension 未加载或未注册单例")
		return

	var asr := Engine.get_singleton("MaliangAsr")
	if asr == null:
		fail.call("get_singleton 返回 null")
		return

	# 探针：证明单例来自原生扩展而非别处
	if not asr.has_method("backend"):
		fail.call("单例无 backend() 方法")
		return
	var backend: String = asr.backend()
	if backend != "gdextension-stub":
		fail.call("backend() = %s，期望 gdextension-stub" % backend)
		return

	# P1 阶段 sherpa 未接，is_ready 必须为 false（客户端据此仍走服务端识别，不误伤）
	if not asr.has_method("is_ready"):
		fail.call("单例无 is_ready() 方法")
		return
	if asr.is_ready() != false:
		fail.call("is_ready() 应为 false（P1 未接模型）")
		return

	print("[P1 PASS] MaliangAsr 单例已由 GDExtension 提供：backend=%s is_ready=%s" % [backend, asr.is_ready()])
	quit(0)
