extends SceneTree
## 物品外观缩略图捕获工具（debug 物品页配套）。
##
## 物品在服务端没有图片——全靠客户端按 renderRef 现场渲染（glTF 包 / SDF 着色器 / 贴纸）。
## 这个工具遍历服务端 /debug/api/items 里的每个 ItemDef，用与 chunk_manager 同一套 renderRef
## 分发在离屏 SubViewport 里把它渲染成一张 PNG，裁掉透明边后 base64 POST 到
## /admin/item-icon/:id 入库。debug 物品页随后就能显示缩略图。
##
## ⚠️ 必须**带窗**跑（不要 --headless）：SDF 物件靠 GPU 逐帧把顶点吸附到隐式面，
## headless 假视口不渲染（sdf_prop.gd 在 headless 下连 VisibleOnScreenEnabler3D 都不挂），
## 截出来会是空/冻结帧。glTF/贴纸类 headless 也能出，但为省心统一带窗。
##
## 运行（对本地服务器；服务器需先起在 8080，MALIANG_ADMIN_TOKEN 未配则本地开放）:
##   MALIANG_API_BASE=http://127.0.0.1:8080 godot --path . \
##     --script res://tools/item_icon_capture.gd --quit-after 100000
## 对生产（带 token）:
##   MALIANG_API_BASE=https://maliang-api.muveeai.com MALIANG_ADMIN_TOKEN=xxx godot --path . \
##     --script res://tools/item_icon_capture.gd --quit-after 100000
## 只跑指定 id（逗号分隔）:  加环境变量 ITEM_ICON_ONLY=tree_puff_a,rock_a
##
## 可续跑（默认）：已有缩略图的物品自动跳过，只补缺口。单进程连续渲染约 30 件后 GPU
## 资源累积会让后续渲染渐渐变空白/停滞（本地/生产都一样），所以一次跑不满是正常的——
## 反复跑同一条命令即可，每次新进程专攻剩余缺口，几遍后收敛到全齐。全量重渲用 ITEM_ICON_FORCE=1。
##   until 循环示例：while :; do <上面的命令>; done  # 直到「完成」里渲染失败跳过=0 再 Ctrl-C
##
## ⚠️ GPU 停滞会产出「冻结帧」而非空白帧：连续渲染到某件后 SubViewport 不再刷新、冻结在上一张
## 成功帧上。这帧非空白，光靠空白护栏（_render_item 里 area<64）拦不住，会被当成当前物品上传——
## 一整批连号物品就全焊上同一张冻结图（生产曾 98/156 件中招，分 4 个连号簇）。两道防线：
##   1) 每进程上限 ITEM_ICON_MAX_PER_RUN（默认 8，0=不限）【主防线/治本】：上传够 N 件就自动退出，
##      趁 GPU 未累积到停滞阈值就换新进程，配合 until 循环收敛。冻结阈值随机器差异极大（实测 5~30 不等），
##      若日志出现 stale 或事后发现重复图簇，就把它调更小；ITEM_ICON_MAX_PER_RUN=1（一件一进程）最稳、零冻结风险。
##   2) 停滞帧护栏【次要防线】：本进程内若一件的 PNG 与上一张已上传的字节完全相同，判为疑似冻结帧 → 跳过不传，
##      留给下个新进程单渲。注意：共享同一 glb 的合法物品（roman:* 复用 medieval、hospital 病床复用 furniture 单人床）
##      正常渲染就是字节相同，会被误判 stale 跳过——但它们随后会被单独重渲上传，只是多几趟、不会永久丢失。
## 修历史坏数据：ITEM_ICON_REDO_HASHES=hash1,hash2,... 让「当前 iconHash 命中该列表」的物品无视
##   已有图强制重渲（重渲出唯一新图后即脱离该列表，自然被后续进程跳过，配合上限+until 收敛）。

const VP_SIZE := 320               # 缩略图边长（正方形，透明底）
const SETTLE_FRAMES := 10          # 每个物品渲染前等的帧数（够 SDF 顶点吸附收敛）
const CAM_ELEV_DEG := 28.0         # 相机俯角（近似游戏内斜俯视）
const CAM_AZIM_DEG := 35.0         # 相机方位角
const FIT_MARGIN := 1.25           # AABB 初始取景留白系数（自动取景的起点）
const FIT_PASSES := 6              # 自动取景迭代上限（含空帧拉远重试的余量）
const FIT_TARGET := 0.6            # 目标：可见内容占视口边长比例（留足余量防偏心物出框，trim 会再裁紧）

var _base := "http://127.0.0.1:8080"
var _token := ""
var _only: PackedStringArray = []
var _force := false  # 默认跳过已有缩略图的物品（可续跑）；ITEM_ICON_FORCE=1 全量重渲
var _max_per_run := 8  # 每进程上传上限，够了就自退避免 GPU 累积到停滞（0=不限）；冻结阈值随机器差异大
                        #（实测 5~30 不等），若出现 stale 跳过或重复图簇就调小；ITEM_ICON_MAX_PER_RUN=1 最稳（一件一进程）
var _redo_hashes: PackedStringArray = []  # 当前 iconHash 命中即强制重渲（修历史坏数据）
var _last_png: PackedByteArray = PackedByteArray()  # 上一张已上传 PNG，用于停滞帧比对
var _vp: SubViewport
var _cam: Camera3D
var _stage: Node3D

func _initialize() -> void:
	var env := OS.get_environment("MALIANG_API_BASE")
	if not env.is_empty():
		_base = env
	_token = OS.get_environment("MALIANG_ADMIN_TOKEN")
	var only_env := OS.get_environment("ITEM_ICON_ONLY")
	if not only_env.is_empty():
		for s in only_env.split(",", false):
			_only.append(s.strip_edges())
	var force_env := OS.get_environment("ITEM_ICON_FORCE")
	_force = force_env == "1" or force_env.to_lower() == "true"
	var max_env := OS.get_environment("ITEM_ICON_MAX_PER_RUN")
	if not max_env.is_empty() and max_env.is_valid_int():
		_max_per_run = maxi(int(max_env), 0)
	var redo_env := OS.get_environment("ITEM_ICON_REDO_HASHES")
	if not redo_env.is_empty():
		for s in redo_env.split(",", false):
			_redo_hashes.append(s.strip_edges())
	_build_stage()
	_run()

## 离屏舞台：透明底 SubViewport + 斜俯视相机 + 主光/补光 + 环境光（免暗面全黑）。
func _build_stage() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(VP_SIZE, VP_SIZE)
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(_vp)

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

	_stage = Node3D.new()  # 每个物品挂这下面，截完清空
	_vp.add_child(_stage)

func _run() -> void:
	await process_frame  # 等一帧确保节点已入树（HTTPRequest.request 要求 is_inside_tree）
	var catalog: Dictionary = await _get_json("/debug/api/items")
	if catalog.is_empty():
		push_error("[icon] 拉取 /debug/api/items 失败（base=%s，token 是否正确？）" % _base)
		quit(1)
		return
	var defs: Array = []
	defs.append_array(catalog.get("builtin", []))
	defs.append_array(catalog.get("creations", []))
	print("[icon] 目录共 %d 个物品（内置 %d + 造物 %d），base=%s" % [
		defs.size(), (catalog.get("builtin", []) as Array).size(),
		(catalog.get("creations", []) as Array).size(), _base])

	var ok := 0
	var skip := 0
	var fail := 0
	var have := 0
	var stale := 0
	var capped := false
	for d in defs:
		var def := d as Dictionary
		var id := String(def.get("id", ""))
		if id.is_empty():
			continue
		if _only.size() > 0 and not (_only.has(id)):
			continue
		# 可续跑：已有缩略图的默认跳过（单进程渲染约 30 件后 GPU 累积会渐渐渲空白/停滞，
		# 分多次跑才能补满——跳过已有让每次新进程都专攻缺口，多跑几遍自然收敛到全齐）。
		# ITEM_ICON_FORCE=1 时无视已有、全量重渲；ITEM_ICON_REDO_HASHES 命中的坏图也强制重渲。
		var ih := String(def.get("iconHash", ""))
		var needs := ih.is_empty() or _redo_hashes.has(ih)
		if not _force and not needs:
			have += 1
			continue
		var img: Image = await _render_item(def)
		if img == null:
			print("[icon] skip %s（renderRef=%s 无法渲染）" % [id, def.get("renderRef", "")])
			skip += 1
			continue
		var png := img.save_png_to_buffer()
		# 停滞帧护栏（次要防线，主防线是每进程上限）：GPU 累积后 SubViewport 会冻结在上一张成功帧上，
		# 这帧非空白、骗过空白护栏，若与上一张已上传的 PNG 字节相同就判冻结帧、跳过留待新进程。
		# ⚠️ 注意：字节相同不一定是冻结——共享同一 glb 的物品（如 roman:* 复用 medieval 资产、
		# hospital 病床复用 furniture 单人床）正常渲染就是字节相同。此处会把这类合法项误判为 stale
		# 而跳过；但它们会在后续进程被单独重渲上传（until 收敛），不会永久丢失，只是多几趟。
		# 真正堵住冻结的是每进程上限（把每进程渲染件数压到 GPU 累积到冻结阈值之前）。
		if not _last_png.is_empty() and png == _last_png:
			print("[icon] stale %s（与上一张字节相同，疑冻结帧或合法共享资产）→ 跳过留待新进程单渲" % id)
			stale += 1
			continue
		var res: Dictionary = await _post_icon(id, Marshalls.raw_to_base64(png))
		if res.has("iconAsset"):
			ok += 1
			_last_png = png
			print("[icon] ok   %s → %s" % [id, res["iconAsset"]])
			# 每进程上限：够了就自退，趁 GPU 未累积到停滞阈值就换新进程（until 循环续补）。
			if _max_per_run > 0 and ok >= _max_per_run:
				capped = true
				print("[icon] 已达本进程上限 %d，自动退出让 until 循环换新 GPU 进程续跑。" % _max_per_run)
				break
		else:
			fail += 1
			push_warning("[icon] fail %s 上传失败" % id)

	print("[icon] 完成：上传 %d，渲染失败跳过 %d，停滞帧跳过 %d，已有跳过 %d，上传失败 %d" % [ok, skip, stale, have, fail])
	if not _force and (skip > 0 or stale > 0 or capped):
		print("[icon] 提示：本轮尚未收敛（GPU 累积/上限所致）。再跑一遍本命令即可续补缺口。")
	quit(1 if fail > 0 else 0)

## 渲染一个物品 → 裁边后的 Image。贴纸直接取平面纹理（就是它的样子）；
## 其余按 renderRef 造 3D 节点丢进舞台，斜俯视取景，等 SETTLE_FRAMES 帧后截 SubViewport。
func _render_item(def: Dictionary) -> Image:
	var rref := String(def.get("renderRef", ""))
	var key := rref.get_slice(":", 1)
	var cat := PackRegistry.category(key)

	# 贴纸：平面纹理即缩略图，无需 3D
	if cat == "sticker":
		var tex := PackRegistry.load_resource(key) as Texture2D
		if tex == null:
			return null
		return tex.get_image()

	var node := _make_node(def, rref, key, cat)
	if node == null:
		return null
	_stage.add_child(node)
	# 先等几帧再算 AABB：add_child 同帧 global_transform 还没吸收 inst.scale、动画也没摆姿态，
	# 立刻算 AABB 会拿到未缩放的裸模型包围盒——如宝塔 scale=0.0007 会算出 8605 单位的巨盒，
	# 相机停到 1.3 万单位外、超出远裁面 → 整帧空白 → 被误判成渲染失败。等姿态/变换定了再取景。
	for _i in range(SETTLE_FRAMES):
		await process_frame
	var framing := _frame_camera(node)
	# 自动取景：SDF 的 shell mesh 基础 AABB 远大于着色器吸附后的可见面，node 模型
	# 尺度也各异——纯按 AABB 摆相机会渲出极小或截断的图。改成「渲一帧→量实际填充像素
	# →调相机距离命中目标占比→再渲」的反馈闭环，各类物品统一按可见内容取景。
	var center: Vector3 = framing["center"]
	var dir: Vector3 = framing["dir"]
	var img: Image = null
	for pass_i in range(FIT_PASSES):
		for _i in range(SETTLE_FRAMES):
			await process_frame
		img = _vp.get_texture().get_image()
		var used := img.get_used_rect()
		if used.size == Vector2i.ZERO:
			# 这一帧全空（相机太近钻进模型 / 太远出裁面）：拉远一档重试，别直接判空白
			var back := (_cam.position - center).length() * 2.0
			_cam.position = center + dir * back
			_cam.look_at(center, Vector3.UP)
			continue
		var span := float(maxi(used.size.x, used.size.y))
		var target := float(VP_SIZE) * FIT_TARGET
		if pass_i == FIT_PASSES - 1 or absf(span - target) < VP_SIZE * 0.06:
			break  # 已够贴合或用完次数
		var dist := (_cam.position - center).length()
		var new_dist := clampf(dist * span / target, 0.4, 200000.0)
		_cam.position = center + dir * new_dist
		_cam.look_at(center, Vector3.UP)
	for c in _stage.get_children():
		c.queue_free()
	# 空白/近空白护栏：渲染彻底失败（资源缺失、尺度撑爆远裁面等）不上传占位空图
	if img == null or img.get_used_rect().get_area() < 64:
		return null
	return _trim(img)

## renderRef 分发（与 chunk_manager._rebuild_chunk 同规则，但单体实例化，不合批/不占地）。
func _make_node(def: Dictionary, rref: String, key: String, cat: String) -> Node3D:
	if rref == "sdf_inline":
		var spec: Variant = def.get("spec", null)
		if typeof(spec) != TYPE_DICTIONARY:
			return null
		return _prep_sdf(SdfProp.from_spec(spec))
	if rref.begins_with("sdf_res:"):
		return _prep_sdf(SdfProp.from_json_file("res://assets/sdf_props/%s.json" % key))
	if rref.begins_with("composed:"):
		# 组合物（积木式造物）：零件树 quad 拍平定妆照（图标拍平无所谓，世界里实体永远是零件树）
		var spec: Variant = def.get("spec", null)
		if typeof(spec) != TYPE_DICTIONARY:
			return null
		return ComposedProp.from_spec(spec)
	if cat == "baked" or cat == "scatter" or cat == "node":
		var resrc := PackRegistry.load_resource(key)
		if resrc == null:
			return null
		if resrc is PackedScene:
			# node 建筑（及各主题散件）按 pack 声明的 scale 实例化——原始模型尺度差异极大
			# （如宝塔 8605 单位、scale 0.0007），不缩放会撑爆 AABB 冲出远裁面渲成空白。
			var inst := (resrc as PackedScene).instantiate() as Node3D
			var nsc := PackRegistry.scale(key)
			inst.scale = Vector3(nsc, nsc, nsc)
			return inst
		if resrc is Mesh:
			# baked ArrayMesh 不自带材质：颜色靠 chunk_manager 合批时套的共享材质
			# （SdfStaticBaker.material()，读顶点色）。不套的话烘焙树/石全渲成白块。
			var mi := MeshInstance3D.new()
			mi.mesh = resrc
			mi.material_override = SdfStaticBaker.material()
			var sc := PackRegistry.scale(key)
			mi.scale = Vector3(sc, sc, sc)
			return mi
		return null
	return null  # 未注册键（漏声明）

## SdfProp 为游戏内视锥剔除挂了 VisibleOnScreenEnabler3D，用它父节点的可见性/进程门控——
## 在离屏 SubViewport 里它判不到主窗相机，会把物件挂起（_process 停摆、渲染失效）。
## 单体截图不需要剔除，直接摘掉 enabler 并强制常驻进程，保证 SDF 面正常吸附着色。
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

## 按节点世界 AABB 摆相机（自动取景的初始猜测）：斜俯视对准中心，距离按 AABB 半径定。
## 返回 { center, dir } 供自动取景闭环按可见像素微调距离。
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
	_cam.near = 0.01  # 自动取景会拉近，小近裁面防切进模型
	_cam.far = 100000.0  # 大远裁面兜底：巨模型（宝塔等）初始取景距离极大也不至于落到裁面外
	_cam.position = center + dir * dist
	_cam.look_at(center, Vector3.UP)
	return { "center": center, "dir": dir }

## 递归合并所有 VisualInstance3D 的世界空间 AABB（SDF 的 shell mesh 也算在内）。
func _node_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var has := false
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var local := vi.get_aabb()
			var world := vi.global_transform * local
			if not has:
				out = world
				has = true
			else:
				out = out.merge(world)
		for c in n.get_children():
			stack.append(c)
	return out

## 裁掉透明边（贴身盒），再补一圈小留白。全透明返回原图。
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

# ── HTTP：自带 x-admin-token 头（api.gd 的 post_json 不支持自定义头）───────────

func _get_json(path: String) -> Dictionary:
	var http := HTTPRequest.new()
	root.add_child(http)
	var headers := PackedStringArray()
	if not _token.is_empty():
		headers.append("x-admin-token: " + _token)
	var err := http.request(_base + path, headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		push_error("[icon] GET %s → HTTP %d" % [path, int(res[1])])
		return {}
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else {}

func _post_icon(id: String, png_b64: String) -> Dictionary:
	var http := HTTPRequest.new()
	root.add_child(http)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not _token.is_empty():
		headers.append("x-admin-token: " + _token)
	var body := JSON.stringify({ "pngBase64": png_b64 })
	var err := http.request(_base + "/admin/item-icon/" + id, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		push_warning("[icon] POST item-icon/%s → HTTP %d" % [id, int(res[1])])
		return {}
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else {}
