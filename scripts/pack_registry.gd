class_name PackRegistry
extends RefCounted
## 资产包注册表（world-themes P3，数据驱动化）。设计见 docs/world-themes-expansion-design.md §6。
##
## 取代 chunk_manager.gd 里 BAKED_MESHES/KAYKIT_SCATTER/KAYKIT_NODES/SCIFI_NODES 四张
## 编译期 preload 常量表：启动扫 assets/packs/index.json 列出的每个 pack，读 pack.json
## 建「渲染键 → 绑定」注册表；资源在**运行时 load()**（非 preload）按需载入 + 缓存。
## 「加主题包 = 丢个 assets/packs/<pack>/ 目录 + index.json 加一行」，零 GDScript 改动。
##
## 绑定字段：{ category: "baked"|"scatter"|"node", path: "res://…", pack: String }（纯路径注册表，
## 全量纲化后无 scale——node 视觉由 fit_scale_for(visualTiles×原始AABB) 派生，见 tile-dimensional-system）。
## - baked   烘焙 ArrayMesh(.res)，chunk_manager 收进 MultiMesh 合批（散布，_jitter_scale 抖动）。
## - scatter KayKit 场景(.gltf)，剥出 mesh 后同样 MultiMesh 合批（散布，_jitter_scale 抖动）。
## - node    独立节点建筑/角色(.gltf/.glb)，fit_scale_for 归一实例化（附椭圆阴影）。
## renderRef 里冒号前缀（baked:/kaykit:/scifi:…）只是语义标注，分发按冒号后段 key 查本表。

const INDEX_PATH := "res://assets/packs/index.json"
const PACKS_DIR := "res://assets/packs"

## 渲染键 → 绑定 Dictionary。启动扫描一次后常驻。
static var _entries: Dictionary = {}
## 资源路径 → 已 load() 的 Resource（ArrayMesh / PackedScene）。跨 chunk 复用，不重复读盘。
static var _res_cache: Dictionary = {}
## 渲染键 → 资产原始（scale=1）水平/竖直 AABB。实例化一次量得后常驻，供 fit_scale 派生视觉缩放。
static var _aabb_cache: Dictionary = {}
static var _loaded := false

static func reset() -> void:
	_entries = {}
	_res_cache = {}
	_aabb_cache = {}
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

## 资产原始（scale=1）AABB，跨轴累积各 MeshInstance3D 的 mesh AABB（按其相对场景根的变换，
## 而非 chunk_manager._visual_extent 那个忽略子节点偏移的近似——派生缩放要求精确）。实例化一次量得
## 后缓存常驻。资源缺/未挂载（load_resource 返 null）时返回**空 AABB 且不缓存**：与内容包分发守卫
## 同哲学，挂载后 chunk 重铺会重量（缓存空 AABB 会像 content-pck 那样永久污染，故不缓存）。
static func raw_aabb(key: String) -> AABB:
	ensure_loaded()
	if _aabb_cache.has(key):
		return _aabb_cache[key]
	var res := load_resource(key)
	if not (res is PackedScene):
		return AABB()  # 未挂载/非场景：不缓存，留待重铺重量
	var inst := (res as PackedScene).instantiate()
	var acc := {}
	_accumulate_aabb(inst, Transform3D.IDENTITY, acc)
	inst.free()
	var out: AABB = acc.get("aabb", AABB())
	_aabb_cache[key] = out
	return out

## 递归累积树内所有 MeshInstance3D 的 mesh AABB（8 角点经累积变换），并到一个总 AABB。
static func _accumulate_aabb(node: Node, xform: Transform3D, acc: Dictionary) -> void:
	var t := xform
	if node is Node3D:
		t = xform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var a := (node as MeshInstance3D).mesh.get_aabb()
		for i in range(8):
			var corner := a.position + Vector3(
				a.size.x * float(i & 1),
				a.size.y * float((i >> 1) & 1),
				a.size.z * float((i >> 2) & 1))
			var p := t * corner
			if acc.has("aabb"):
				acc["aabb"] = (acc["aabb"] as AABB).expand(p)
			else:
				acc["aabb"] = AABB(p, Vector3.ZERO)
	for c in node.get_children():
		_accumulate_aabb(c, t, acc)

## 视觉缩放派生（全量纲化核心）：等比缩放使资产水平 AABB 恰好填满 footprint(W×H tile) 的 fill 比例。
## 取两水平轴的 min 保证既不溢出格子、又保持资产原始长宽比（uniform scale，与 inst.scale=ONE×sc 一致）。
## 严格「视觉=碰撞」：footprint 即尺寸唯一真相。AABB 无效（未挂载/空 mesh）时回落 1.0 不崩。
static func fit_scale(ab: AABB, fp_w: float, fp_h: float, fill := 0.9) -> float:
	if ab.size.x <= 0.0 or ab.size.z <= 0.0:
		return 1.0
	var tile := WorldGrid.TILE_SIZE
	return fill * minf(fp_w * tile / ab.size.x, fp_h * tile / ab.size.z)

## 实体 def 的视觉水平占格（tile）：visualTilesW/H 缺省回落 footprintW/H。可 > footprint 让视觉外延
## 超出地基（树冠超地基交叠邻树）；碰撞另走 footprint。纯函数（不碰资源），headless 可测。
static func visual_tiles(def: Dictionary) -> Vector2:
	var vw := float(def.get("visualTilesW", def.get("footprintW", 1)))
	var vh := float(def.get("visualTilesH", def.get("footprintH", 1)))
	return Vector2(maxf(vw, 1.0), maxf(vh, 1.0))

## node 类视觉缩放的唯一入口：按实体 def 的 visualTiles(缺省 footprint) × 资产原始 AABB 派生等比缩放。
## chunk_manager 世界渲染 / item_thumbnailer 缩略图 / item_icon_capture 图标三处共用，单一真相。
## raw_aabb 取不到（未挂载/baked mesh 非 PackedScene）时 fit_scale 回落 1.0，相机自动按 AABB 取景不受影响。
static func fit_scale_for(key: String, def: Dictionary, fill := 0.9) -> float:
	var vt := visual_tiles(def)
	return fit_scale(raw_aabb(key), vt.x, vt.y, fill)

## 该渲染键所属资产包名（pack.json 所在目录名，如 "base"/"toyroom"/"stickers"）。未注册返回 ""。
## "base" = 主包内（打进 APK，恒在）；其余 = 可分发内容包（.pck，须挂载后才在 res:// 里）。
static func pack_of(key: String) -> String:
	ensure_loaded()
	return String(_entries.get(key, {}).get("pack", ""))

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
	# 内容包(.pck)分发守卫：该键属某内容包（非 base 主包）且其包【尚未挂载】时，绝不调 load()。
	# 未挂就碰 ResourceLoader 会污染 ResourceCache——之后即便挂上包，默认/REPLACE 缓存模式的 load 也
	# 永远返回被污染的 null（只有重启才自愈）。真根因见记忆 content-pck-android-load-stage-failure
	# （2026-07-23 华为真机 CACHE_IGNORE 对照铁证）。返 null（不缓存）走与「资源缺」相同的降级路径；
	# 预热器挂载该包后 chunk 重铺重走本函数，此时 _pack_loadable→true → load 干净成功。
	if not _pack_loadable(String((entry as Dictionary).get("pack", ""))):
		return null
	var res := load(path)
	if res == null:
		push_warning("[packs] 渲染键 %s 资源载入失败：%s" % [key, path])
		return null
	_res_cache[path] = res
	return res

## 该 pack 的资源现在能否安全 load。base/空名=主包恒可；其余内容包委托 PackMounter.pack_available
## （编辑器/headless 恒 true；导出包须已挂载）。取不到 PackMounter（脱离 autoload 的孤立测试）时，
## 编辑器直载、导出保守跳过（不污染缓存）。
static func _pack_loadable(pack_name: String) -> bool:
	if pack_name.is_empty() or pack_name == "base":
		return true
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		# autoload 是 root 的直接子节点，按名取（从 root 自身用绝对 "/root/..." 会报
		# "absolute paths from outside the active scene tree"，见 game-pilot 回测）。
		var pm := (loop as SceneTree).root.get_node_or_null(^"PackMounter")
		if pm != null:
			return pm.pack_available(pack_name)
	return OS.has_feature("editor")

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
