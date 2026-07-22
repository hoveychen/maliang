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
func ensure_mounted(pack_hash: String) -> bool:
	if pack_hash.is_empty():
		return false
	if _mounted.has(pack_hash):
		return true
	var path := PACKS_DIR.path_join(pack_hash + ".pck")
	if not FileAccess.file_exists(path):
		return false
	if not ProjectSettings.load_resource_pack(path):
		push_warning("[packs] 挂载失败: %s" % path)
		return false
	_mounted[pack_hash] = true
	return true

## 某包是否已挂载（预热器 diff 用：已挂的不重下不重挂）。
func is_mounted(pack_hash: String) -> bool:
	return _mounted.has(pack_hash)
