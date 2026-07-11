class_name PackRegistry
extends RefCounted
## 资产包注册表（world-themes P3，数据驱动化）。设计见 docs/world-themes-expansion-design.md §6。
##
## 取代 chunk_manager.gd 里 BAKED_MESHES/KAYKIT_SCATTER/KAYKIT_NODES/SCIFI_NODES 四张
## 编译期 preload 常量表：启动扫 assets/packs/index.json 列出的每个 pack，读 pack.json
## 建「渲染键 → 绑定」注册表；资源在**运行时 load()**（非 preload）按需载入 + 缓存。
## 「加主题包 = 丢个 assets/packs/<pack>/ 目录 + index.json 加一行」，零 GDScript 改动。
##
## 绑定字段：{ category: "baked"|"scatter"|"node", path: "res://…", scale: float, pack: String }
## - baked   烘焙 ArrayMesh(.res)，chunk_manager 收进 MultiMesh 合批（散布）。
## - scatter KayKit 场景(.gltf)，剥出 mesh 后同样 MultiMesh 合批（散布）。
## - node    独立节点建筑/角色(.gltf/.glb)，按 scale 实例化（附椭圆阴影）。
## renderRef 里冒号前缀（baked:/kaykit:/scifi:…）只是语义标注，分发按冒号后段 key 查本表。

const INDEX_PATH := "res://assets/packs/index.json"
const PACKS_DIR := "res://assets/packs"

## 渲染键 → 绑定 Dictionary。启动扫描一次后常驻。
static var _entries: Dictionary = {}
## 资源路径 → 已 load() 的 Resource（ArrayMesh / PackedScene）。跨 chunk 复用，不重复读盘。
static var _res_cache: Dictionary = {}
static var _loaded := false

static func reset() -> void:
	_entries = {}
	_res_cache = {}
	_loaded = false

## 幂等扫描：读 index.json → 逐 pack 读 pack.json → 合并 entries。缺文件/格式错静默降级
## （世界秃但能跑，与 ItemCatalog.ensure_builtin 同哲学）。所有查询前自动调用。
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var index: Variant = _read_json(INDEX_PATH)
	if typeof(index) != TYPE_ARRAY:
		push_warning("[packs] index.json 缺失或非数组：%s" % INDEX_PATH)
		return
	for pack_name in index:
		if typeof(pack_name) != TYPE_STRING:
			continue
		_load_pack(String(pack_name))

static func _load_pack(pack_name: String) -> void:
	var path := "%s/%s/pack.json" % [PACKS_DIR, pack_name]
	var doc: Variant = _read_json(path)
	if typeof(doc) != TYPE_DICTIONARY:
		push_warning("[packs] pack %s 的 pack.json 缺失或非对象：%s" % [pack_name, path])
		return
	var entries: Variant = (doc as Dictionary).get("entries", {})
	if typeof(entries) != TYPE_DICTIONARY:
		push_warning("[packs] pack %s 的 entries 非对象" % pack_name)
		return
	for key in (entries as Dictionary):
		var e: Variant = (entries as Dictionary)[key]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var ed := e as Dictionary
		var cat := String(ed.get("category", ""))
		var rpath := String(ed.get("path", ""))
		if cat.is_empty() or rpath.is_empty():
			push_warning("[packs] %s/%s 缺 category 或 path，跳过" % [pack_name, key])
			continue
		if _entries.has(key):
			push_warning("[packs] 渲染键 %s 重复（pack %s 覆盖 %s）" % [key, pack_name, _entries[key].get("pack", "?")])
		_entries[String(key)] = {
			"category": cat,
			"path": rpath,
			"scale": float(ed.get("scale", 1.0)),
			"pack": pack_name,
		}

static func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed

## 该渲染键是否已注册（sdf_res:/sdf_inline 不进本表，返回 false 由调用方走 SDF 分支）。
static func has(key: String) -> bool:
	ensure_loaded()
	return _entries.has(key)

## 分类字符串（"baked"/"scatter"/"node"），未注册返回 ""。
static func category(key: String) -> String:
	ensure_loaded()
	return String(_entries.get(key, {}).get("category", ""))

## 实例化/合批缩放（node 建筑；baked/scatter 的散布抖动缩放另由 chunk_manager._jitter_scale 定）。
static func scale(key: String) -> float:
	ensure_loaded()
	return float(_entries.get(key, {}).get("scale", 1.0))

## 运行时按需 load() 资源并缓存（baked→ArrayMesh，scatter/node→PackedScene）。
## 路径错/资源缺返回 null，调用方须容错（与旧 preload 表不同，运行时才知道加载成败）。
static func load_resource(key: String) -> Resource:
	ensure_loaded()
	var entry: Variant = _entries.get(key, null)
	if entry == null:
		return null
	var path := String((entry as Dictionary).get("path", ""))
	if path.is_empty():
		return null
	if _res_cache.has(path):
		return _res_cache[path]
	var res := load(path)
	if res == null:
		push_warning("[packs] 渲染键 %s 资源载入失败：%s" % [key, path])
		return null
	_res_cache[path] = res
	return res

## 某个 pack 声明的所有渲染键（守门测试用；无该 pack 返回空）。
static func keys_in_pack(pack_name: String) -> Array:
	ensure_loaded()
	var out: Array = []
	for key in _entries:
		if String(_entries[key].get("pack", "")) == pack_name:
			out.append(key)
	return out

## 全部已注册渲染键（守门测试孤儿检查用）。
static func all_keys() -> Array:
	ensure_loaded()
	return _entries.keys()
