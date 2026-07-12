class_name PaperCharacter
extends MeshInstance3D
## HD-2D 纸片角色：3D 世界里的 2D 立绘。不用 billboard——而是面向相机方向 +
## 固定小倾角（织梦岛/纸片马里奥式：站在地上、面向玩家，仍有立体感）。
## 倾角由 world.gd 随相机角度设置（rotation.x）。相机方位固定在 +Z，故默认朝向即正对相机。
##
## v2：从 Sprite3D 换成细分 QuadMesh + paper_character.gdshader——单面片只有 4 个顶点
## 弯不了，细分后顶点位移才能做「纸」的卷曲/飘动/翻面演出。
## 对外保持 Sprite3D 同名属性（texture/pixel_size/offset/modulate），上层零改动。

var char_name: String = "小伙伴"

## 占位立绘的世界高度（米）。在线生成 sprite 由 world.gd 覆盖为 ~6 单位。
const PLACEHOLDER_HEIGHT := 3.2
## 细分密度：宽 6 × 高 12 段（~91 顶点）足够卷曲平滑，安卓无压力。
const SUBDIV_W := 6
const SUBDIV_H := 12

static var _shader: Shader = null
static var _xray_shader: Shader = null

## X 光穿透剪影开关（画质旋钮 xray 驱动，同 SdfProp._snap_iters 模式）：
## 该 pass 每角色每帧多画一个全 quad 透明面并逐像素采样深度图，老 Mali 上深度采样
## 打断 tiled 渲染快路径。默认全平台开——角色走到房子/树后面仍见剪影是体验的一部分
## （老板拍板：默认保留），只有弱机被 benchmark 定档摘除、或用户在设置页手动关。
static var _xray_enabled := true

## 换档入口：作用于已存在（paper_chars 组）与后续创建的所有角色。
static func set_xray_enabled(on: bool, tree: SceneTree) -> void:
	_xray_enabled = on
	for n in tree.get_nodes_in_group("paper_chars"):
		var p := n as PaperCharacter
		if p != null:
			p._mat.next_pass = p._xray_mat if on else null
			p._pm_flutter = INF  # 重挂后强制下次 set_paper_motion 补齐 X 光 pass 的参数

var texture: Texture2D = null:
	set(v):
		texture = v
		_mat.set_shader_parameter("albedo_tex", v)
		_xray_mat.set_shader_parameter("albedo_tex", v)
		_refresh_geometry()
var pixel_size := 0.01:
	set(v):
		pixel_size = v
		_refresh_geometry()
## 与 Sprite3D.offset 同语义：按像素平移贴图（world.gd 传 (0, h/2) 把锚点放到脚底）。
var offset := Vector2.ZERO:
	set(v):
		offset = v
		_refresh_geometry()
var modulate := Color.WHITE:
	set(v):
		modulate = v
		_mat.set_shader_parameter("modulate", v)

var _mat: ShaderMaterial
## 穿透 pass 材质：被建筑/树/地形挡住时画半透明剪影浮在遮挡物上（见 paper_xray.gdshader）。
var _xray_mat: ShaderMaterial
## idle 动画图集 meta（空=静态整图）；非空时几何按单格 cellW×cellH 算、shader 分格播放。
var _sheet: Dictionary = {}

func _init() -> void:
	if _shader == null:
		_shader = load("res://shaders/paper_character.gdshader")
	if _xray_shader == null:
		_xray_shader = load("res://shaders/paper_xray.gdshader")
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_xray_mat = ShaderMaterial.new()
	_xray_mat.shader = _xray_shader
	if _xray_enabled:
		_mat.next_pass = _xray_mat  # 穿透剪影作为主材质的 next_pass，排在不透明之后读深度
	var q := QuadMesh.new()
	q.subdivide_width = SUBDIV_W
	q.subdivide_depth = SUBDIV_H
	mesh = q
	material_override = _mat

## 脚下伪影半径（setup/play_idle 记录，refresh_ground_shadow 复用）；wants_ground_shadow
## 落地角色为真、悬浮角色（仙子/飞行）由 world 置假——切「角色实时阴影」时据此挂/摘 blob。
var _blob_radius := 0.6
var wants_ground_shadow := true

func _enter_tree() -> void:
	add_to_group("paper_chars")  # set_xray_enabled / refresh_ground_shadow 换档批量寻址用

## 画质切「角色实时阴影」后刷新脚下 blob：attach 内部按 BlobShadow.suppress_actor_blob
## 自动挂/摘（suppress 时会 detach 旧的且不建新）。悬浮角色跳过（脚下暗斑穿帮）。
func refresh_ground_shadow() -> void:
	if wants_ground_shadow:
		BlobShadow.attach(self, _blob_radius)

func setup(tex: Texture2D, color: Color, cname: String) -> void:
	char_name = cname
	modulate = color
	# 任意分辨率纹理：按高度归一化到 PLACEHOLDER_HEIGHT；
	# 锚点移到脚底（上移半高，底边落在节点原点，绕脚底倾斜/翻面）
	var h := float(tex.get_height())
	pixel_size = PLACEHOLDER_HEIGHT / h
	offset = Vector2(0.0, h / 2.0)
	texture = tex
	# 脚下伪影（替代实时阴影，见 BlobShadow 注释）；换贴图重设尺寸时同步重挂
	_blob_radius = clampf(float(tex.get_width()) * pixel_size * 0.38, 0.4, 1.4)
	BlobShadow.attach(self, _blob_radius)

# ── 贴纸附着（character-anchors，docs/character-anchors-design.md §4）────────
# 锚点=立绘归一化坐标(原点左上)，服务端 vision 检测下发；缺失时按 alpha 现算兜底。
# 附着物是子节点，跟随面片倾斜/翻面(rotation.y=PI)。翻面后单片会转到角色面片背后
# 被深度遮挡，故每个槽位是「前后三明治」双片(±STICKER_Z，背片预转 PI)——哪面朝相机
# 哪面赢深度，背面看到镜像贴纸与角色本身镜像一致。

const STICKER_Z := 0.02          ## 贴纸离角色面片的前后距离（米），防 z-fight
const STICKER_W_RATIO := 0.22    ## 贴纸世界宽 ≈ 角色可见高的比例
## 兜底比例（与服务端 anchors.ts 同参）：手部所在身高比例/由身体边缘内收比例
const FALLBACK_HAND_Y := 0.55
const FALLBACK_HAND_INSET := 0.05

## 归一化锚点 { "headTop": {x,y}, "handL": {...}, "handR": {...} }；空 = 未下发（走兜底）。
var _anchors: Dictionary = {}
## 槽位 → 附着 holder 节点（Node3D，含前后两片）。
var _stickers: Dictionary = {}

## world.gd 在 spawn/换装时灌入服务端下发的 appearance.anchors（缺省空字典）。
func set_anchors(anchors: Dictionary) -> void:
	_anchors = anchors if anchors != null else {}
	for slot in _stickers:
		_position_sticker(slot) # 锚点后到（如老档案补算）时重摆已挂贴纸

## 挂贴纸到槽位（headTop/handL/handR）。同槽重复挂 = 换贴图。tex 为贴纸图（含白描边）。
func attach_sticker(slot: String, tex: Texture2D) -> void:
	detach_sticker(slot)
	var holder := Node3D.new()
	holder.name = "sticker_" + slot
	var h := visible_height()
	var w := h * STICKER_W_RATIO
	var sh := w * float(tex.get_height()) / float(tex.get_width())
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.albedo_texture = tex
	var q := QuadMesh.new()
	q.size = Vector2(w, sh)
	q.material = mat
	for side in [1.0, -1.0]:
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.position = Vector3(0.0, 0.0, STICKER_Z * side)
		if side < 0.0:
			mi.rotation.y = PI # 背片朝后：翻面时顶上，镜像与角色镜像一致
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)
	holder.set_meta("sticker_h", sh)
	add_child(holder)
	_stickers[slot] = holder
	_position_sticker(slot)

func detach_sticker(slot: String) -> void:
	var old: Node3D = _stickers.get(slot)
	if old != null:
		old.name = old.name + "_dying" # 让出槽位名：同帧重挂时新 holder 才不被自动改名（@Node3D@N）
		old.queue_free()
	_stickers.erase(slot)

## 锚点 → 面片局部坐标：quad 局部 y∈[0,h]（脚底原点）、x∈[-w/2,w/2]；
## 归一化 (ax,ay) 原点左上 → x=(ax-0.5)*w、y=(1-ay)*h。
## 头顶槽贴纸「底边」对齐锚点（帽子坐在头上），手槽「中心」对齐。
func _position_sticker(slot: String) -> void:
	var holder: Node3D = _stickers.get(slot)
	if holder == null or texture == null:
		return
	var a := _anchor_for(slot)
	var tw := float(texture.get_width())
	var th := float(texture.get_height())
	if not _sheet.is_empty():
		tw = float(_sheet.get("cellW", tw))
		th = float(_sheet.get("cellH", th))
	var w := tw * pixel_size
	var h := th * pixel_size
	var y := (1.0 - float(a.y)) * h
	if slot == "headTop":
		y += float(holder.get_meta("sticker_h", 0.0)) * 0.5
	holder.position = Vector3((float(a.x) - 0.5) * w, y, 0.0)

## 槽位锚点：优先服务端下发；缺失按贴图 alpha 现算（与服务端 anchors.ts 兜底同规则）并缓存。
func _anchor_for(slot: String) -> Dictionary:
	var a: Variant = _anchors.get(slot)
	if typeof(a) == TYPE_DICTIONARY and (a as Dictionary).has("x"):
		return a
	var fb := _fallback_anchor(slot)
	_anchors[slot] = fb
	return fb

## alpha 兜底：headTop=最顶不透明行中心；hand=身高 55% 行身体边缘内收 5%。
## 图集模式/取不到 Image 时用固定比例。
func _fallback_anchor(slot: String) -> Dictionary:
	var img: Image = texture.get_image() if texture != null and _sheet.is_empty() else null
	if img == null:
		match slot:
			"headTop": return { "x": 0.5, "y": 0.02 }
			"handL": return { "x": 0.25, "y": FALLBACK_HAND_Y }
			_: return { "x": 0.75, "y": FALLBACK_HAND_Y }
	var w := img.get_width()
	var h := img.get_height()
	if slot == "headTop":
		for y in range(h):
			var sum := 0.0
			var n := 0
			for x in range(w):
				if img.get_pixel(x, y).a > 0.03:
					sum += float(x)
					n += 1
			if n > 0:
				return { "x": sum / float(n) / float(w - 1), "y": float(y) / float(h - 1) }
		return { "x": 0.5, "y": 0.02 }
	var row := int(FALLBACK_HAND_Y * float(h - 1))
	var min_x := -1
	var max_x := -1
	for x in range(w):
		if img.get_pixel(x, row).a > 0.03:
			if min_x < 0:
				min_x = x
			max_x = x
	if min_x < 0:
		return { "x": 0.25 if slot == "handL" else 0.75, "y": FALLBACK_HAND_Y }
	var inset := float(w) * FALLBACK_HAND_INSET
	var px := float(min_x) + inset if slot == "handL" else float(max_x) - inset
	return { "x": clampf(px / float(w - 1), 0.0, 1.0), "y": FALLBACK_HAND_Y }

## 演出参数量化步长（米）：4mm 对 45mm 的慢呼吸卷曲肉眼不可辨，
## 却把待机时的 uniform 上传从每帧降到 ~1/5——旧版每角色每帧 4 次 set_shader_parameter。
const PM_STEP := 0.004
var _pm_flutter := INF
var _pm_curl := INF

## 纸片演出参数（world.gd 每帧驱动）：走路飘动幅度 / 待机呼吸卷曲，单位米。
## 量化脏检查：值未跨过步长格子就不重传；X 光 pass 摘除时也不给游离材质上传。
func set_paper_motion(flutter_amp: float, curl: float) -> void:
	var qf := snappedf(flutter_amp, PM_STEP)
	var qc := snappedf(curl, PM_STEP)
	if qf == _pm_flutter and qc == _pm_curl:
		return
	_pm_flutter = qf
	_pm_curl = qc
	_mat.set_shader_parameter("flutter_amp", qf)
	_mat.set_shader_parameter("curl", qc)
	if _mat.next_pass != null:
		_xray_mat.set_shader_parameter("flutter_amp", qf)
		_xray_mat.set_shader_parameter("curl", qc)

## 折纸机关参数（动作层每帧驱动，仅折纸类动作期间非零）。折痕格式见 shader 注释：
## crease=Vector4(痕点 xn,yn, 痕方向 dx,dy)（归一化纸面坐标）。全零→全零是恒等快路径，
## 待机时零上传；动作期间角度连续变化，逐帧重传（每场景同时折纸的角色至多一两个）。
var _fold_active := false

func set_paper_fold(f1: Vector4, a1: float, f2: Vector4, a2: float, pleat: float, crumple: float) -> void:
	var active := a1 != 0.0 or a2 != 0.0 or pleat != 0.0 or crumple != 0.0
	if not active and not _fold_active:
		return
	_fold_active = active
	var mats := [_mat] if _mat.next_pass == null else [_mat, _xray_mat]
	for m in mats:
		var sm := m as ShaderMaterial
		sm.set_shader_parameter("fold1", f1)
		sm.set_shader_parameter("fold1_angle", a1)
		sm.set_shader_parameter("fold2", f2)
		sm.set_shader_parameter("fold2_angle", a2)
		sm.set_shader_parameter("pleat_amp", pleat)
		sm.set_shader_parameter("crumple_amp", crumple)

## 从静态立绘切到 idle 动画图集。meta 为服务端 SpriteSheetMeta（cols/rows/frameCount/fps/cellW/cellH）。
## world_height：期望世界高度（米），与切换前静态立绘保持一致，观感不跳。phase：相位偏移（秒）。
func play_idle(atlas: Texture2D, meta: Dictionary, world_height: float, phase := 0.0) -> void:
	var ch := float(meta.get("cellH", 0))
	var cw := float(meta.get("cellW", 0))
	if atlas == null or ch <= 0.0 or cw <= 0.0:
		return
	_sheet = meta
	for m in [_mat, _xray_mat]:
		m.set_shader_parameter("sheet_cols", int(meta.get("cols", 1)))
		m.set_shader_parameter("sheet_rows", int(meta.get("rows", 1)))
		m.set_shader_parameter("sheet_frames", int(meta.get("frameCount", 0)))
		m.set_shader_parameter("sheet_fps", float(meta.get("fps", 8)))
		m.set_shader_parameter("sheet_phase", phase)
	pixel_size = world_height / ch  # setter 会触发 _refresh_geometry（此时 _sheet 已置）
	offset = Vector2(0.0, ch / 2.0)
	texture = atlas
	_blob_radius = clampf(cw * pixel_size * 0.38, 0.4, 1.4)
	BlobShadow.attach(self, _blob_radius)

## 可见世界高度（米）：动画图集按单格 cellH 算，静态整图按贴图高算。
## 头顶挂饰定位/相机构图都按这个——整张图集高度是 rows×cellH，会把动画角色算高 rows 倍。
func visible_height() -> float:
	if texture == null:
		return 0.0
	var th := float(texture.get_height())
	if not _sheet.is_empty():
		th = float(_sheet.get("cellH", th))
	return th * pixel_size

func _refresh_geometry() -> void:
	if texture == null:
		return
	# sprite-sheet 模式按单格尺寸算几何（整张图集含多格，可见的只有一格）
	var tw := float(texture.get_width())
	var th := float(texture.get_height())
	if not _sheet.is_empty():
		tw = float(_sheet.get("cellW", tw))
		th = float(_sheet.get("cellH", th))
	var w := tw * pixel_size
	var h := th * pixel_size
	var q := mesh as QuadMesh
	q.size = Vector2(w, h)
	q.center_offset = Vector3(offset.x * pixel_size, offset.y * pixel_size, 0.0)
	_mat.set_shader_parameter("quad_size", Vector2(w, h))
	_xray_mat.set_shader_parameter("quad_size", Vector2(w, h))
