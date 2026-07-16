class_name ItemThumbnailer
extends RefCounted
## 运行时物品缩略图服务（背包物品页用）。混合来源（docs/backpack-page-redesign-design.md §2）：
##   1) 服务端已烧缩略图优先——公开 GET /item-icons 拿 item_id→hash，命中就 api.fetch_texture 拉图。
##      内置物（~154）离线工具 item_icon_capture.gd 早已回填生产，走这条。
##   2) 没命中就客户端现场离屏渲染——把 item_icon_capture.gd 的渲染核心抽到这里复用：透明底
##      SubViewport + 斜俯视相机，按 renderRef 造节点、自动取景、裁边。孩子刚造的造物（唯一 id、
##      服务端没图）走这条。
##   3) 都失败回退（返回 null，调用方显示礼盒 ic_gift）。
##
## 用法：setup(host, api) → set_server_icons(map) → request(id, def)；解析完 emit
## thumbnail_ready(id, tex)。命中内存缓存的立即 emit。一次只渲一件（逐帧节流，避开
## item_icon_capture 记录的 GPU 连续渲染停滞坑）。RefCounted：SubViewport 挂到 host 节点树下。

signal thumbnail_ready(item_id: String, tex: Texture2D)

const VP_SIZE := 256               ## 缩略图边长（正方形透明底）
const SETTLE_FRAMES := 8           ## 每件渲染前等的帧数（够 SDF 顶点吸附/姿态摆定）
const CAM_ELEV_DEG := 28.0         ## 相机俯角（近似游戏内斜俯视）
const CAM_AZIM_DEG := 35.0
const FIT_MARGIN := 1.25           ## AABB 初始取景留白
const FIT_PASSES := 5              ## 自动取景迭代上限
const FIT_TARGET := 0.66           ## 目标：可见内容占视口边长比例

var _host: Node = null
var _api: Node = null                    ## Api（get 缩略图资产）
var _vp: SubViewport = null
var _cam: Camera3D = null
var _stage: Node3D = null
var _cache: Dictionary = {}              ## item_id -> Texture2D（本会话）
var _server_icons: Dictionary = {}       ## item_id -> asset_hash（公开 GET /item-icons）
var _inflight: Dictionary = {}           ## item_id -> true（去重在飞请求）
var _queue: Array = []                   ## [{ id, def }]
var _busy := false

## host 提供节点树（离屏 SubViewport 得入树才渲染）；api 用来拉服务端已烧缩略图。
func setup(host: Node, api: Node) -> void:
	_host = host
	_api = api

func set_server_icons(map: Dictionary) -> void:
	if map != null:
		_server_icons = map

func has_cached(item_id: String) -> bool:
	return _cache.has(item_id)

func get_cached(item_id: String) -> Texture2D:
	return _cache.get(item_id, null)

## 请求某物品缩略图。命中缓存 → 立即（deferred）emit。否则入队异步解析，解析完 emit
## thumbnail_ready(id, tex)；tex==null 表示解析失败，调用方回退礼盒。
func request(item_id: String, def: Dictionary) -> void:
	if item_id.is_empty():
		return
	if _cache.has(item_id):
		thumbnail_ready.emit.call_deferred(item_id, _cache[item_id])
		return
	if _inflight.has(item_id):
		return
	_inflight[item_id] = true
	_queue.append({ "id": item_id, "def": def })
	if not _busy:
		_pump()

## 预热：对命中服务端图的物品提前入队拉纹理（便宜，只走 fetch_texture + 磁盘缓存），
## 消除开背包页时"礼盒→真图"的可见延迟。**不预渲无服务端图的造物**（端侧渲染贵、占 GPU，
## 留到开页时才懒渲）。开手机/背包刷新时调；已缓存/在途的跳过，幂等。
func preheat(entries: Array) -> void:
	for e in entries:
		var d := e as Dictionary
		var id := String(d.get("id", ""))
		if id.is_empty() or _cache.has(id) or _inflight.has(id):
			continue
		if String(_server_icons.get(id, "")).is_empty():
			continue # 无服务端图 → 不预热（端侧渲染留到开页懒渲，别在这批量吃 GPU）
		request(id, d.get("def", {}))

## 队列泵：一次只解析一件（服务端图不占 GPU，渲染逐帧节流），串行避开连续渲染停滞。
func _pump() -> void:
	_busy = true
	while not _queue.is_empty():
		var job: Dictionary = _queue.pop_front()
		var id := String(job["id"])
		var def: Dictionary = job["def"]
		var tex: Texture2D = await _resolve(id, def)
		_inflight.erase(id)
		if tex != null:
			_cache[id] = tex
		thumbnail_ready.emit(id, tex)
	_busy = false

## 解析单件：服务端已烧图优先，否则离屏渲染。
func _resolve(id: String, def: Dictionary) -> Texture2D:
	var hash := String(_server_icons.get(id, ""))
	if not hash.is_empty() and _api != null and _api.has_method("fetch_texture"):
		var tex: Texture2D = await _api.fetch_texture(hash)
		if tex != null:
			return tex
	var img: Image = await _render_def(def)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

# ── 离屏渲染（抽自 tools/item_icon_capture.gd，运行时复用）───────────────────────

## 懒建离屏舞台：透明底 SubViewport + 斜俯视相机 + 主光/补光 + 环境光。挂到 host 树下。
func _ensure_stage() -> bool:
	if _vp != null and is_instance_valid(_vp):
		return true
	if _host == null or not _host.is_inside_tree():
		return false
	_vp = SubViewport.new()
	_vp.size = Vector2i(VP_SIZE, VP_SIZE)
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	_host.add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -40, 0)
	sun.light_energy = 1.2
	_vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 140, 0)
	fill.light_energy = 0.4
	_vp.add_child(fill)

	_cam = Camera3D.new()
	_vp.add_child(_cam)
	_stage = Node3D.new()
	_vp.add_child(_stage)
	return true

## 渲染一个物品 → 裁边后的 Image（失败返回 null）。贴纸直接取平面纹理；其余按 renderRef 造
## 3D 节点丢进舞台、斜俯视自动取景、等帧后截 SubViewport。
func _render_def(def: Dictionary) -> Image:
	var rref := String(def.get("renderRef", ""))
	var key := rref.get_slice(":", 1)
	var cat := PackRegistry.category(key)

	if cat == "sticker":
		var tex := PackRegistry.load_resource(key) as Texture2D
		return tex.get_image() if tex != null else null

	if not _ensure_stage():
		return null
	var tree := _vp.get_tree()
	if tree == null:
		return null

	var node := _make_node(def, rref, key, cat)
	if node == null:
		return null
	_stage.add_child(node)
	# 先等几帧：add_child 同帧 global_transform 还没吸收 scale、动画未摆姿态，立刻算 AABB 会拿到裸盒。
	for _i in range(SETTLE_FRAMES):
		await tree.process_frame
	var framing := _frame_camera(node)
	var center: Vector3 = framing["center"]
	var dir: Vector3 = framing["dir"]
	var img: Image = null
	# 自动取景反馈闭环：渲一帧→量实际填充像素→调相机距离命中目标占比→再渲。
	for pass_i in range(FIT_PASSES):
		for _i in range(SETTLE_FRAMES):
			await tree.process_frame
		img = _vp.get_texture().get_image()
		var used := img.get_used_rect()
		if used.size == Vector2i.ZERO:
			var back := (_cam.position - center).length() * 2.0
			_cam.position = center + dir * back
			_cam.look_at(center, Vector3.UP)
			continue
		var span := float(maxi(used.size.x, used.size.y))
		var target := float(VP_SIZE) * FIT_TARGET
		if pass_i == FIT_PASSES - 1 or absf(span - target) < VP_SIZE * 0.06:
			break
		var dist := (_cam.position - center).length()
		var new_dist := clampf(dist * span / target, 0.4, 200000.0)
		_cam.position = center + dir * new_dist
		_cam.look_at(center, Vector3.UP)
	for c in _stage.get_children():
		c.queue_free()
	if img == null or img.get_used_rect().get_area() < 64:
		return null
	return _trim(img)

## renderRef 分发（与 chunk_manager 同规则，但单体实例化，不合批/不占地）。
func _make_node(def: Dictionary, rref: String, key: String, cat: String) -> Node3D:
	if rref == "sdf_inline":
		var spec: Variant = def.get("spec", null)
		if typeof(spec) != TYPE_DICTIONARY:
			return null
		return _prep_sdf(SdfProp.from_spec(spec))
	if rref.begins_with("sdf_res:"):
		return _prep_sdf(SdfProp.from_json_file("res://assets/sdf_props/%s.json" % key))
	if rref.begins_with("composed:"):
		var spec2: Variant = def.get("spec", null)
		if typeof(spec2) != TYPE_DICTIONARY:
			return null
		return ComposedProp.from_spec(spec2)
	if cat == "baked" or cat == "scatter" or cat == "node":
		var resrc := PackRegistry.load_resource(key)
		if resrc == null:
			return null
		if resrc is PackedScene:
			var inst := (resrc as PackedScene).instantiate() as Node3D
			var nsc := PackRegistry.scale(key)
			inst.scale = Vector3(nsc, nsc, nsc)
			return inst
		if resrc is Mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = resrc
			mi.material_override = SdfStaticBaker.material()
			var sc := PackRegistry.scale(key)
			mi.scale = Vector3(sc, sc, sc)
			return mi
		return null
	return null

## SdfProp 在离屏 SubViewport 里判不到主窗相机会被挂起——摘 enabler、强制常驻进程，保证吸附着色。
func _prep_sdf(prop: SdfProp) -> SdfProp:
	if prop == null:
		return null
	for c in prop.get_children():
		if c is VisibleOnScreenEnabler3D:
			prop.remove_child(c)
			c.queue_free()
	prop.visible = true
	prop.process_mode = Node.PROCESS_MODE_ALWAYS
	return prop

## 按节点世界 AABB 摆相机（自动取景初始猜测）：斜俯视对准中心，距离按 AABB 半径定。
func _frame_camera(node: Node3D) -> Dictionary:
	var aabb := _node_aabb(node)
	if aabb.size == Vector3.ZERO:
		aabb = AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1, 1))
	var center := aabb.position + aabb.size * 0.5
	var radius := aabb.size.length() * 0.5
	var dist := maxf(radius * FIT_MARGIN / tan(deg_to_rad(_cam.fov * 0.5)), 0.6)
	var elev := deg_to_rad(CAM_ELEV_DEG)
	var azim := deg_to_rad(CAM_AZIM_DEG)
	var dir := Vector3(cos(elev) * sin(azim), sin(elev), cos(elev) * cos(azim))
	_cam.near = 0.01
	_cam.far = 100000.0
	_cam.position = center + dir * dist
	_cam.look_at(center, Vector3.UP)
	return { "center": center, "dir": dir }

## 递归合并所有 VisualInstance3D 的世界空间 AABB。
func _node_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var has := false
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var world := vi.global_transform * vi.get_aabb()
			if not has:
				out = world
				has = true
			else:
				out = out.merge(world)
		for c in n.get_children():
			stack.append(c)
	return out

## 裁掉透明边再补一圈小留白。全透明返回原图。
func _trim(img: Image) -> Image:
	var used := img.get_used_rect()
	if used.size == Vector2i.ZERO:
		return img
	var pad := 6
	var x := maxi(used.position.x - pad, 0)
	var y := maxi(used.position.y - pad, 0)
	var w := mini(used.size.x + pad * 2, img.get_width() - x)
	var h := mini(used.size.y + pad * 2, img.get_height() - y)
	return img.get_region(Rect2i(x, y, w, h))

## 释放离屏舞台（背包关闭或 world 退出时调）。
func teardown() -> void:
	if _vp != null and is_instance_valid(_vp):
		_vp.queue_free()
	_vp = null
	_cam = null
	_stage = null
