class_name AsrGuard
extends RefCounted
## 端侧 ASR 门禁：Android/导出 macOS 上端侧模型（MaliangAsr 插件 + sherpa）是硬依赖。
## 服务端 ASR 已整条退役（2026-07-13），端侧是唯一的识别路径——所以「导出漏带模型」的坏包
## 一旦放行就是个哑巴 App，必须在启动时硬报错拦住（老板 2026-07-09 明确要求：没模型直接报错）。
## editor/headless 从源码跑时模型不随包（除非 MALIANG_ASR_MODEL_DIR 指路），此时本机没有识别
## 能力：麦照开、VAD 照跑、转写恒空。这是开发环境的既定状态，不受此门禁约束——否则没建过
## GDExtension / 没拉过模型的干净 checkout 会被全屏挡在游戏外，整套 headless 回测也跑不了。

## 本平台是否「本应有端侧 ASR」。
## - Android：恒为真（AAR 打进 APK，缺失即坏包）。
## - macOS：仅**导出构建**（is_template=OS.has_feature("template")）为真——导出的 .app 把
##   GDExtension + 模型随包带走（play-mac.sh / package-mac-app.sh 注入 Contents/Resources/
##   asr-models），缺失即坏包，硬报错拒进游戏。editor/headless 从源码跑不受门禁约束（模型
##   不随包，见文件头）。真实端侧识别路径由 macos_asr_recognize.gd 专测覆盖。
## - 其它平台：为假。
static func asr_required(os_name: String, is_template: bool = false) -> bool:
	if os_name == "Android":
		return true
	if os_name == "macOS":
		return is_template
	return false

## 判定「本应有却缺失/失败」是否致命：仅在需要 ASR 的平台上、且当前不可用时为真。
## available：setup 阶段传「有无单例」，asr_error 阶段传 false。
## is_template：调用方传 OS.has_feature("template")（导出构建为真），仅影响 macOS。
## 注意：utterance 阶段不要用本函数——未就绪多半只是异步加载没跑完（initialize() 是
## executor 异步，~秒级），硬报错会误伤正常启动。那里用 must_wait_for_ready()。
static func is_fatal(os_name: String, available: bool, is_template: bool = false) -> bool:
	return asr_required(os_name, is_template) and not available

## utterance 阶段：是否必须等端侧就绪再开麦。
## Android/导出 macOS 上端侧 ASR 是硬依赖，未就绪时宁可不开麦、等 asr_ready 信号（没有服务端
## 可回落；加载失败会走 asr_error 硬报错，不会卡在这里）。editor/headless（is_template 为假）
## 永远不等待——那里本就没有识别能力，等也等不来。
static func must_wait_for_ready(os_name: String, is_ready: bool, is_template: bool = false) -> bool:
	return asr_required(os_name, is_template) and not is_ready

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
