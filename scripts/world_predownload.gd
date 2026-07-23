class_name WorldPredownload
extends RefCounted
## 世界级内容包全量预下载编排器（world-full-predownload-gate P2，设计见 §handoff）。
##
## 进世界前把【这个世界要用的】所有内容包一次拉齐、逐包下载 + 挂载再放行：清单来自服务端
## GET /worlds/:wid/packs（api.fetch_world_packs），服务端已算好并集（所有场景 manifest ∪ 核心包
## bgm/voice_items/build_parts/stickers ∪ 在场故事册 voice_story_*）并去重。取代原
## world._prefetch_content_packs（那只管非场景包）——本编排器管全量，供下载页 gating（P3）。
##
## 逐包：已挂载(PackMounter.is_mounted)则跳过（内容寻址永久缓存，二次启动秒进），否则
## api.fetch_pack 下载 + PackMounter.ensure_mounted 挂载。全程发 progress_changed 供进度条；
## 结束发 finished(all_mounted)。run() 可重入（幂等）——弱网没全挂时调用层可再 run 一次重试
## （已挂的跳过，只补缺的），实现 P3 的自动重试。
##
## RefCounted（非 Node）：不进树，靠 api（Node，自管 HTTPRequest 子节点）跑网络；调用方持一个
## 引用（world._predownload）保活即可。纯函数 build_plan/plan_total_bytes/fmt_mb 供 headless 单测。

## 进度更新：已下 done_packs / 共 total_packs 包；已下 done_bytes / 共 total_bytes 字节。
signal progress_changed(done_packs: int, total_packs: int, done_bytes: int, total_bytes: int)
## 一轮处理完：all_mounted=true 表示清单里的包全挂上（gating 放行）；false=有包没下下来（弱网，调用层重试）。
signal finished(all_mounted: bool)

var total_packs := 0
var done_packs := 0
var total_bytes := 0
var done_bytes := 0
var all_mounted := false
var _running := false

# ── 纯函数（headless 单测）────────────────────────────────────────────────────

## 把 fetch_world_packs 的原始数组规整成下载计划：丢掉 name/hash 空的项，按 hash 去重
## （同一 .pck 只下一次、字节只计一次），保序返回 [{name,hash,bytes}]。服务端已按 name 去重，
## 这里再按 hash 兜一层——两个包名理论上可指同一 .pck，字节不该重复计进总量。
static func build_plan(raw: Array) -> Array:
	var seen := {}
	var out: Array = []
	for p in raw:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var d := p as Dictionary
		var name := String(d.get("name", ""))
		var h := String(d.get("hash", ""))
		if name.is_empty() or h.is_empty():
			continue
		if seen.has(h):
			continue
		seen[h] = true
		out.append({"name": name, "hash": h, "bytes": int(d.get("bytes", 0))})
	return out

## 计划总字节（build_plan 已去重）。
static func plan_total_bytes(plan: Array) -> int:
	var sum := 0
	for p in plan:
		sum += int((p as Dictionary).get("bytes", 0))
	return sum

## 字节 → MB 展示（1 位小数），给下载页 "X.X MB / Y.Y MB"。
static func fmt_mb(bytes: int) -> String:
	return "%.1f" % (float(bytes) / (1024.0 * 1024.0))

# ── 下载编排 ──────────────────────────────────────────────────────────────────

## 跑一轮预下载。api：Api 实例（fetch_world_packs / fetch_pack）；pm：PackMounter 节点
## （is_mounted / note_mounted_name / ensure_mounted）；world_id 非空。全程发 progress_changed，
## 结束发 finished(all_mounted)。可重入闸 _running 防并发重入；结束后可再调（重试补缺）。
func run(api: Object, pm: Object, world_id: String) -> void:
	if _running:
		return
	_running = true
	all_mounted = false
	if api == null or pm == null or world_id.is_empty():
		# 无法预下载（离线/无世界）：视作没有要下的，直接放行——缺包各守卫跳过，联网后自愈。
		total_packs = 0
		done_packs = 0
		total_bytes = 0
		done_bytes = 0
		all_mounted = true
		_running = false
		progress_changed.emit(0, 0, 0, 0)
		finished.emit(true)
		return
	var raw: Array = await api.fetch_world_packs(world_id)
	var plan := build_plan(raw)
	total_packs = plan.size()
	total_bytes = plan_total_bytes(plan)
	done_packs = 0
	done_bytes = 0
	var missing := 0
	progress_changed.emit(done_packs, total_packs, done_bytes, total_bytes)
	for entry in plan:
		var d := entry as Dictionary
		var h := String(d["hash"])
		var name := String(d["name"])
		var bytes := int(d["bytes"])
		if pm.is_mounted(h):
			pm.note_mounted_name(name) # 已挂（含二次启动 _mount_cached 只见 hash）：补记名字，不重下不重挂
			done_packs += 1
			done_bytes += bytes
			progress_changed.emit(done_packs, total_packs, done_bytes, total_bytes)
			continue
		var path: String = await api.fetch_pack(h) # 已缓存秒回；未缓存下载（弱网失败返回空）
		if path.is_empty() or not pm.ensure_mounted(h, name):
			missing += 1 # 没下下来/挂不上：本轮记缺，进度不计——调用层 finished(false) 后重试补它
		else:
			done_packs += 1
			done_bytes += bytes
		progress_changed.emit(done_packs, total_packs, done_bytes, total_bytes)
	all_mounted = (missing == 0 and done_packs == total_packs)
	_running = false
	finished.emit(all_mounted)
