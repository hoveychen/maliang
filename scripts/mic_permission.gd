class_name MicPermission
extends RefCounted
## iOS 麦克风权限门禁。
##
## 为什么单独一层：iOS 上 Godot/GDScript 读不到麦克风授权状态（不像 Android 有
## OS.get_granted_permissions），而「权限被拒」与「采音坏」都表现为 PCM 全零、无法区分。
## 权限被家长/孩子关掉 = 整个语音沙盒悄悄失灵（采到全零静音、零提示）——必须在开麦前拦住、
## 全屏引导去设置，回前台自动复查解除（overlay 自管，见 mic_permission_overlay.gd）。
##
## 判据来自原生 MaliangAsr.ios_mic_permission()（gdextension_asr/src/platform_ios.mm，
## AVAudioSession.recordPermission）。缺单例/老插件/非 iOS 一律「视为已授予、不拦」，避免误伤
## 桌面/headless/Android（那些平台麦权限不归本层管）。

# 与原生 ios_mic_permission() 对齐：0=未决定 / 1=已拒绝 / 2=已授予。
const STATUS_UNDETERMINED := 0
const STATUS_DENIED := 1
const STATUS_GRANTED := 2

## 纯判定（供单测）：仅当 iOS + 能查到权限 + 权限=拒绝 才拦。
## 缺单例（singleton_present=false）时**不拦**——查不到就不该误伤（可能是老包/桌面）。
static func should_block(os_name: String, status: int, singleton_present: bool) -> bool:
	if os_name != "iOS":
		return false
	if not singleton_present:
		return false
	return status == STATUS_DENIED

## 查当前 iOS 麦权限。缺单例 / 老插件没这方法 / 非 iOS（原生恒返 2）→ STATUS_GRANTED。
static func query_status() -> int:
	if not Engine.has_singleton("MaliangAsr"):
		return STATUS_GRANTED
	var asr := Engine.get_singleton("MaliangAsr")
	if asr == null or not asr.has_method("ios_mic_permission"):
		return STATUS_GRANTED
	return int(asr.ios_mic_permission())

## 开麦前调用：iOS 权限被拒 → 盖引导层 + 暂停树，返回 true（调用方据此**不要**开麦）。
## 其它情况返回 false（照常开麦）。设计成在语义开麦入口（VoiceCapture.open / intro_listen_begin）
## 的「设 _open 标志之前」调用——这样被拦时标志不置位，解除后宿主重新调用即自动重试。
static func enforce(tree: SceneTree) -> bool:
	if tree == null:
		return false
	if not should_block(OS.get_name(), query_status(), Engine.has_singleton("MaliangAsr")):
		return false
	block(tree)
	return true

## 盖引导层 + 暂停树。幂等（已有层则只确保暂停）。层自带「打开设置」按钮与回前台自动复查。
static func block(tree: SceneTree) -> void:
	if tree == null:
		return
	if tree.root.get_node_or_null("MicPermissionOverlay") != null:
		tree.paused = true
		return
	var overlay: Node = load("res://scripts/mic_permission_overlay.gd").new()
	overlay.name = "MicPermissionOverlay"
	tree.root.add_child(overlay)
	tree.paused = true

## 复查通过后解除：移除引导层 + 解暂停（由 overlay 回前台复查到已授予时调用）。
static func clear(tree: SceneTree) -> void:
	if tree == null:
		return
	var overlay := tree.root.get_node_or_null("MicPermissionOverlay")
	if overlay != null:
		overlay.queue_free()
	tree.paused = false
