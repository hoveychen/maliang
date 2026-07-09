class_name AsrGuard
extends RefCounted
## 端侧 ASR 门禁：Android 上端侧模型（MaliangAsr 插件 + sherpa AAR）是硬依赖。
## 缺失/初始化失败绝不能静默回落服务端识别——否则「导出漏带 AAR」的坏包会悄悄
## 降级、一路流到小朋友手里都发现不了（老板 2026-07-09 明确要求：没模型直接启动报错）。
## 桌面/编辑器天然没有该单例，走服务端识别是合法的，不受此门禁约束。

## 本平台是否「本应有端侧 ASR」。仅 Android 为真；桌面/编辑器/其它平台为假。
static func asr_required(os_name: String) -> bool:
	return os_name == "Android"

## 判定「本应有却缺失/失败」是否致命：仅在需要 ASR 的平台上、且当前不可用时为真。
## available：setup 阶段传「有无单例」，asr_error 阶段传 false，utterance 阶段传 isReady()。
static func is_fatal(os_name: String, available: bool) -> bool:
	return asr_required(os_name) and not available

const MSG_MISSING := "语音识别模型缺失，App 可能未正确安装。\n请卸载后重新安装最新版本。"
const MSG_INIT_FAILED := "语音识别初始化失败：\n%s\n请卸载后重新安装最新版本。"

## 全屏阻断：盖一层不可穿透的错误层并暂停整棵树，拒绝进入游戏。
## 幂等：已有阻断层则只刷新文案，不重复叠加。
static func block(tree: SceneTree, message: String) -> void:
	if tree == null:
		return
	push_error("[ASR] " + message)
	var existing := tree.root.get_node_or_null("AsrFatalOverlay")
	if existing != null:
		var lbl := existing.get_node_or_null("BG/Msg")
		if lbl is Label:
			(lbl as Label).text = message
		tree.paused = true
		return
	var layer := CanvasLayer.new()
	layer.name = "AsrFatalOverlay"
	layer.layer = 128
	layer.process_mode = Node.PROCESS_MODE_ALWAYS # 暂停树后仍在最顶层
	var bg := ColorRect.new()
	bg.name = "BG"
	bg.color = Color(0.09, 0.09, 0.12, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP # 吞掉一切输入，游戏点不动
	layer.add_child(bg)
	var msg := Label.new()
	msg.name = "Msg"
	msg.text = message
	msg.set_anchors_preset(Control.PRESET_FULL_RECT)
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bg.add_child(msg)
	tree.root.add_child(layer)
	tree.paused = true
