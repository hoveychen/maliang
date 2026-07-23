extends Node
## 内容包(.pck)挂载单例（content-pck-distribution P3，设计见 docs/content-pack-distribution-design.md）。
## autoload 名 PackMounter，无 class_name（避免与 autoload 全局名冲突，照 HarnessCmd/SdfBakeSwap 先例）。
##
## 职责：把已下载到 user://packs/ 的 .pck 用 ProjectSettings.load_resource_pack 挂载。挂载后，包里
## 资产的 res:// 路径自动解析进包——PackRegistry / chunk_manager 一行不用改（load(path) 语义不变）。
##
## 两个入口：
## - 启动扫挂载：_ready 扫 user://packs/ 把上次已下载的包全挂上（早于任何 PackRegistry.load_resource），
##   实现「分发≠在线」——下载过一次后永久离线可用，启动即就位。
## - 运行时挂载：ensure_mounted(hash) 供预热器（world._prewarm_packs）下载完某包后当场挂上。
##
## 幂等：已挂载的包不重挂（ProjectSettings.load_resource_pack 重复挂同一包行为未定义，故自己记账）。
## 挂载后【无需】PackRegistry.reset()：PackRegistry.load_resource 对 load() 失败(null)不缓存，
## 挂上后下次查询自然重试成功（见 pack_registry.gd load_resource）。

const PACKS_DIR := "user://packs"

## 已挂载的包 hash 集合（hash → true）。进程级、跨场景常驻。
var _mounted: Dictionary = {}
## 已挂载的包【名】集合（pack 名 → true）。按 hash 挂载时由调用方带上名字记账，
## 供各降级守卫「按包名」判断该内容包资源现在能否安全 load——见 is_pack_mounted / pack_available。
## 内容寻址分发按 hash 记账（去重），但守卫拿到的是包名（PackRegistry 的 pack 字段 / bgm / voice_items），
## 故并存一张名字账（启动扫挂载 _mount_cached 只见 hash 无名，名字由 world 后续 _prewarm/_prefetch 补记）。
var _mounted_names: Dictionary = {}

func _ready() -> void:
	_mount_cached()

## 扫 user://packs/ 挂载所有已缓存 .pck（启动期一次）。目录不存在（首次运行/无网）静默跳过。
func _mount_cached() -> void:
	var dir := DirAccess.open(PACKS_DIR)
	if dir == null:
		return
	for fn in dir.get_files():
		if not fn.ends_with(".pck"):
			continue
		ensure_mounted(fn.trim_suffix(".pck"))

## 确保某 hash 对应的 .pck 已挂载（幂等）。文件在 user://packs/<hash>.pck。
## 成功 / 已挂载返回 true；文件不存在或挂载失败返回 false（调用方据此决定是否先 fetch_pack 下载）。
## pack_name 非空时（调用方从 manifest/index 拿到包名）：挂载成功 / 已挂载即把名字记进 _mounted_names，
## 供守卫按名查询（is_pack_mounted）。失败不记名（离线/缺文件时 pack_available 应仍回 false）。
func ensure_mounted(pack_hash: String, pack_name := "") -> bool:
	if pack_hash.is_empty():
		return false
	if _mounted.has(pack_hash):
		note_mounted_name(pack_name) # 已挂载：补记名字（启动期 _mount_cached 只见 hash 无名，这里补上）
		return true
	var path := PACKS_DIR.path_join(pack_hash + ".pck")
	if not FileAccess.file_exists(path):
		return false
	if not ProjectSettings.load_resource_pack(path):
		push_warning("[packs] 挂载失败: %s" % path)
		return false
	_mounted[pack_hash] = true
	note_mounted_name(pack_name)
	return true

## 记录某【包名】已挂载（供 is_pack_mounted 按名查）。空名 no-op。
## 用于「hash 已挂但当时没带名字」的补记（world._prewarm/_prefetch 对 is_mounted(h) 命中的包调用）。
func note_mounted_name(pack_name: String) -> void:
	if not pack_name.is_empty():
		_mounted_names[pack_name] = true

## 某包是否已挂载（按 hash；预热器 diff 用：已挂的不重下不重挂）。
func is_mounted(pack_hash: String) -> bool:
	return _mounted.has(pack_hash)

## 某内容包（按【名】）是否已挂载。各降级守卫据此判断：该包资源现在能否安全 load。
## 未挂载时【绝不】能碰 ResourceLoader.load/exists/threaded_request——未挂就碰会污染 ResourceCache，
## 之后即便挂上包 load 也永远返回 null（只有重启才自愈）。真根因见记忆
## content-pck-android-load-stage-failure（2026-07-23 华为真机 CACHE_IGNORE 对照铁证）。
func is_pack_mounted(pack_name: String) -> bool:
	return not pack_name.is_empty() and _mounted_names.has(pack_name)

## 某内容包资源现在能否安全 load。编辑器/headless（从项目目录跑）：res:// 即完整源、无内容包挂载一说，
## 恒 true——故 headless 回测照常渲染打包 prop / 播 bgm，不受挂载守卫影响。导出包里：必须该包已挂载。
func pack_available(pack_name: String) -> bool:
	if OS.has_feature("editor"):
		return true
	return is_pack_mounted(pack_name)
