class_name PaperPhone
extends Node3D
## 3D 纸糊双折叠手机（设计: docs/paper-phone-design.md）。
## 一张对折的"卡纸"：两块带厚度的面板 A/B，铰链在 A 左缘。
##   合拢态(FRONT)  = B 叠在 A 背后，A 外面就是手机正面（屏幕+贴纸图标）。
##   展开态(SPREAD) = 整机绕 Y 翻 180° 同时铰链摊平，两个内面变成双倍宽跨页。
##   停靠态(DOCKED) = 手机常驻屏幕：缩小停在左下角当"图标"，点击搬到持机位放大。
## 本类只管 3D 载体：几何/状态机/动画/射线拾取，不懂任何业务（app 内容由
## SubViewport 贴上来，见 phone_ui.gd）。挂为 Camera3D 子节点，fit_to_camera 定位。
##
## 几何约定（本地单位，机身高恒为 1，整体大小由 fit_to_camera 的 scale 控制）：
##   面板 A 占 x∈[-W/2, W/2]，铰链在 (x=-W/2, z=-T/2)（背面边缘，纸板对折的真实轴）。
##   折叠角 fold: 180°=合拢（B 贴在 A 背后）、0°=摊平成跨页（B 占 x∈[-3W/2,-W/2]）。
##   整机 yaw: 0°=正面朝相机、180°=背面（跨页）朝相机。两者同 tween 并行播放。
##   跨页态 A 内面=左页、B 内面=右页（翻转后镜像正好左右各半）。

signal state_changed(new_state: int)

enum State { DOCKED, FRONT, SPREAD }

const PANEL_ASPECT := 2.10        ## 机身高:宽 ≈ iPhone 直板比例
const PANEL_H := 1.0              ## 面板高（本地基准，勿改：fit 按此反算 scale）
const PANEL_W := PANEL_H / PANEL_ASPECT
const PANEL_T := 0.032            ## 卡纸厚度（厚切边=硬卡纸手工感，侧面纸芯白最卖"纸做的"）
const FACE_EPS := 0.002           ## 贴面浮出板面的间隙（防 z-fighting）
const CORNER_R := PANEL_W * (27.0 / 480.0)  ## 芯板圆角半径=壳贴图 alpha 镂空的圆角（die-cut 剪影）
const SLAB_INSET := PANEL_W * (3.0 / 480.0) ## 芯板四周比贴面略缩（藏进贴图镂空边缘内，正视零穿帮）
const CORNER_SEGS := 6            ## 每个圆角的弧分段
const EDGE_COLOR := Color(0.965, 0.945, 0.905) ## 纸芯切边暖白（比印刷面亮——"剪出来的卡纸"信号）
## 手机独立渲染层（全仓库唯一用 .layers 处）：世界太阳 cull 掉该层、attach_light_rig 的
## 自带灯只照该层——shaded 纸面在相机环绕时亮度才稳定（P1 derisk：yaw 扫描波动 0.3%）。
const RENDER_LAYER := 1 << 10
const FLIP_DUR := 0.45            ## 翻转+展开动画时长
const MOVE_DUR := 0.40            ## 停靠位↔持机位搬移动画时长
const DOCK_ROT := Vector3(0.10, 0.44, -0.05) ## 停靠侧摆角(rad):脸朝屏幕中心(用户方向)侧身~25°,一眼立体手机
# 盖章后座（kick）：砸下那一瞬机身一沉 + 轻微侧抖，~0.35s 弹回
const KICK_DECAY := 3.0            ## 后座衰减速率（1.0 → 0 约 0.33s）
const KICK_PITCH := 0.10           ## 俯冲角(rad)
const KICK_ROLL := 0.05            ## 侧抖角(rad)
const KICK_DROP := 0.012           ## 下沉距离(m)

## 贴面 id（射线拾取返回、set_face_texture 寻址）
const FACE_FRONT := "front"        ## A 外面：手机正面壳
const FACE_BACK := "back"          ## B 外面：手机背面壳（三摄岛）
const FACE_SPREAD_L := "spread_l"  ## A 内面：跨页左页
const FACE_SPREAD_R := "spread_r"  ## B 内面：跨页右页
const FACE_SCREEN := "screen"      ## A 外面的屏幕区（正面壳内嵌，SubViewport 贴上来）
const SCREEN_FRAC := Vector2(0.90, 0.94)  ## 正面屏占面板比例（四周留纸质 bezel）

var state: int = State.DOCKED

var _pivot: Node3D                 ## 整机翻转（yaw）+ 跨页居中平移
var _hinge: Node3D                 ## 铰链（fold）
var _panel_a: Node3D
var _panel_b: Node3D
var _faces := {}                   ## face id → { mesh: MeshInstance3D, size: Vector2 }
var _front_vp: SubViewport         ## 正面主屏内容（create_screens 后有效）
var _spread_vp: SubViewport        ## 背面跨页内容（左右页各采样一半 UV）
var _drag_face := ""               ## 拖拽捕获中的贴面 id（按下命中屏区起、松手止）
var _fold_deg := 180.0
var _yaw_deg := 0.0
var _tween: Tween
var _hand_pos := Vector3.ZERO      ## 持机位（fit_hand 算出）
var _hand_scale := 1.0
var _dock_pos := Vector3.ZERO      ## 停靠位（fit_dock 算出；首次贴合前手机隐藏防闪原点）
var _dock_scale := 0.2
var _dock_fitted := false          ## 停靠位是否已按真实布局贴合过（首帧 Control 布局后才有）
var _base_rot := DOCK_ROT          ## 基础姿态角（停靠=DOCK_ROT 侧摆、持机=0；微摆叠加其上；初始即停靠）
var _sway_t := 0.0                 ## 持机微摆相位
var _drop_shadow: MeshInstance3D   ## 悬浮软影（机身后下方，宽度跟随折叠进度）
var _kick := 0.0                   ## 盖章后座余量 1→0（见 kick）
var _rest_pos := Vector3.ZERO      ## 后座前的静止位（衰减完精确复位）

# 在 _init 建几何而非 _ready：headless 测试在 SceneTree._initialize 阶段节点尚未进树、
# _ready 会延迟到首帧，_init 保证 new() 出来即可用（show_front/pick 不依赖树状态）。
func _init() -> void:
	_build()
	visible = false # 首次 fit_dock 前藏着（防止在相机原点闪现）
	_apply_pose(180.0, 0.0)

## 持机微摆：纸片"活着"的感觉（Origami King 的 paper-in-motion 极简版）。
## 只动整机根节点的 x/z 微旋（pivot 的 y 旋留给翻转姿态），收起时不跑。
## 叠加一记「后座」：集邮册上狠狠盖章的那一下，整台机身被砸得一沉（见 kick）。
func _process(delta: float) -> void:
	if not visible:
		return
	_sway_t += delta
	var sway := Vector3(sin(_sway_t * 0.9 + 1.7) * 0.008, 0.0, sin(_sway_t * 1.4) * 0.012)
	if _kick <= 0.0001:
		rotation = _base_rot + sway
		return
	# 后座期间才碰 position——平时不写，免得跟 _animate_move 的位移 tween 打架
	_kick = maxf(0.0, _kick - delta * KICK_DECAY)
	var k := _kick * _kick   # 平方衰减：砸下那一瞬最狠，回弹快
	rotation = _base_rot + sway + Vector3(k * KICK_PITCH, 0.0, sin(_kick * 34.0) * k * KICK_ROLL)
	position = _rest_pos + Vector3(0.0, -k * KICK_DROP, 0.0)
	if _kick <= 0.0001:
		position = _rest_pos   # 收干净，别留一丝位移残差

## 盖章砸下去的一记后座：机身俯冲一沉 + 轻微侧抖，指数衰减。手机是挂在相机下的实体，
## 抖机身比抖屏幕里的 UI 真实得多——「狠狠」主要就是这一下卖出来的。
func kick(strength := 1.0) -> void:
	_kick = clampf(strength, 0.0, 1.0)
	_rest_pos = position   # 记住当下的静止位（掏出/翻转动画中途也能挨这一下）

## ── 几何 ────────────────────────────────────────────────────────────────────

func _build() -> void:
	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)
	# 面板 A（固定）：薄纸板 + 外面(正面壳)/内面(跨页左页)两片贴面
	_panel_a = Node3D.new()
	_panel_a.name = "PanelA"
	_pivot.add_child(_panel_a)
	_panel_a.add_child(_make_slab())
	_add_face(FACE_FRONT, _panel_a, Vector3(0.0, 0.0, PANEL_T * 0.5 + FACE_EPS), false)
	_add_face(FACE_SPREAD_L, _panel_a, Vector3(0.0, 0.0, -PANEL_T * 0.5 - FACE_EPS), true)
	# 铰链在 A 左缘的背面边（纸板对折的真实轴）：绕 Y 转 180° 正好把 B 叠到 A 背后
	_hinge = Node3D.new()
	_hinge.name = "Hinge"
	_hinge.position = Vector3(-PANEL_W * 0.5, 0.0, -PANEL_T * 0.5)
	_pivot.add_child(_hinge)
	# 面板 B（挂铰链）：摊平时占铰链系 x∈[-W,0]、z∈[0,T]（背面与 A 背面共面）
	_panel_b = Node3D.new()
	_panel_b.name = "PanelB"
	_panel_b.position = Vector3(-PANEL_W * 0.5, 0.0, PANEL_T * 0.5)
	_hinge.add_child(_panel_b)
	_panel_b.add_child(_make_slab())
	_add_face(FACE_BACK, _panel_b, Vector3(0.0, 0.0, PANEL_T * 0.5 + FACE_EPS), false)
	_add_face(FACE_SPREAD_R, _panel_b, Vector3(0.0, 0.0, -PANEL_T * 0.5 - FACE_EPS), true)
	_build_drop_shadow()

## 悬浮软影：持机物没有落地面，"离你很近的一张实体卡"的存在感靠机身后下方
## 一片软影承担（纸艺观感第二支柱的持机版）。贴图复用 PaperBook 的超椭圆烘法
## （剪影内实心+轮廓外平滑衰减——纯径向渐变会把浓度全藏在机身正后方看不见）。
## 挂 root：跟机身一起搬移/缩放/侧摆；spread 视觉中心始终在 root 原点
## （_apply_pose 的 pivot 平移保证），软影只需随折叠加宽（见 _apply_pose）。
const SHADOW_CORE := 0.78         ## 影贴图实心核半径占比（衰减带只占外圈 22%——窄圈贴剪影）
func _build_drop_shadow() -> void:
	var q := QuadMesh.new()
	# 实心核对齐机身剪影：quad 取机身/CORE，窄衰减圈正好箍在剪影外一小圈。
	# 书影贴图（0.62 核+宽衰减）是桌面接触影的糊法，用在持机物上会糊成环境渐变（实测）。
	q.size = Vector2(PANEL_W / SHADOW_CORE, PANEL_H / SHADOW_CORE)
	_drop_shadow = MeshInstance3D.new()
	_drop_shadow.name = "DropShadow"
	_drop_shadow.mesh = q
	# 后下方偏移：光从左上前方来（attach_light_rig），影子落右下后方。
	# 深度别拉远：透视会把软影缩小+拖向灭点，整片藏到机身正后面看不见（实测 -0.5 全灭）。
	# x 偏移里有 ~0.045 是在抵消灭点漂移（持机位在画面右侧，靠后的影会向画面中心滑）
	_drop_shadow.position = Vector3(0.085, -0.055, -0.10)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = _make_drop_shadow_texture()
	m.albedo_color = Color(0.13, 0.12, 0.10, 0.42) # 中性软影（草地/任意场景上都是"影"）
	_drop_shadow.material_override = m
	_drop_shadow.layers = RENDER_LAYER
	_drop_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_drop_shadow)

## 悬浮影贴图：超椭圆（≈圆角矩形）剪影内实心 + 轮廓外窄带平滑衰减。
## 与 PaperBook._make_shadow_texture 同族，核更大衰减更窄（悬浮 drop shadow
## 要"贴着边缘的一圈"，不是桌面接触影那种大范围糊散）。
static func _make_drop_shadow_texture() -> ImageTexture:
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var p := Vector2(absf(x - 63.5) / 63.5, absf(y - 63.5) / 63.5)
			var d := pow(pow(p.x, 4.0) + pow(p.y, 4.0), 0.25) # 超椭圆≈圆角矩形
			var t := clampf((d - SHADOW_CORE) / (1.0 - SHADOW_CORE), 0.0, 1.0)
			var a := 1.0 - t * t * (3.0 - 2.0 * t)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)

## 纸板芯：面板的厚度体（侧面即纸边）。贴面用独立 quad 盖在两大面上。
## 圆角矩形棱柱（非 BoxMesh）：直角盒芯会从壳贴图的圆角镂空后面露出灰角，
## 圆角芯+镂空贴图=真 die-cut 卡纸剪影。侧壁法线沿轮廓外向（弧段平滑），
## 吃光后一圈切边自带明暗渐变——翻转/展开时最抢眼的"纸做的"信号。
func _make_slab() -> MeshInstance3D:
	var hw := PANEL_W * 0.5 - SLAB_INSET
	var hh := PANEL_H * 0.5 - SLAB_INSET
	var prof := _rounded_profile(hw, hh, CORNER_R, CORNER_SEGS)
	var ht := PANEL_T * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := prof.size()
	for i in n:
		var a: Dictionary = prof[i]
		var b: Dictionary = prof[(i + 1) % n]
		var pa := a["p"] as Vector2
		var pb := b["p"] as Vector2
		var na := a["n"] as Vector2
		var nb := b["n"] as Vector2
		# 侧壁条：+z 沿 → -z 沿（法线=轮廓外向，弧段相邻共享方向 → 平滑着色）
		for spec: Array in [
				[Vector3(pa.x, pa.y, ht), na], [Vector3(pb.x, pb.y, ht), nb], [Vector3(pb.x, pb.y, -ht), nb],
				[Vector3(pa.x, pa.y, ht), na], [Vector3(pb.x, pb.y, -ht), nb], [Vector3(pa.x, pa.y, -ht), na]]:
			var nv := spec[1] as Vector2
			st.set_normal(Vector3(nv.x, nv.y, 0.0))
			st.add_vertex(spec[0] as Vector3)
		# 前后盖板（扇形三角到中心；贴面 quad 盖在外面，盖板只在斜视/镂空角外露）
		st.set_normal(Vector3(0.0, 0.0, 1.0))
		st.add_vertex(Vector3(0.0, 0.0, ht))
		st.set_normal(Vector3(0.0, 0.0, 1.0))
		st.add_vertex(Vector3(pa.x, pa.y, ht))
		st.set_normal(Vector3(0.0, 0.0, 1.0))
		st.add_vertex(Vector3(pb.x, pb.y, ht))
		st.set_normal(Vector3(0.0, 0.0, -1.0))
		st.add_vertex(Vector3(0.0, 0.0, -ht))
		st.set_normal(Vector3(0.0, 0.0, -1.0))
		st.add_vertex(Vector3(pb.x, pb.y, -ht))
		st.set_normal(Vector3(0.0, 0.0, -1.0))
		st.add_vertex(Vector3(pa.x, pa.y, -ht))
	var mi := MeshInstance3D.new()
	mi.name = "Slab"
	mi.mesh = st.commit()
	mi.material_override = _paper_mat(EDGE_COLOR)
	mi.layers = RENDER_LAYER
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

## 圆角矩形轮廓（CCW 闭合）：每点带外向法线。四个角圆弧相接，弧端点法线与
## 直边法线一致 → 直边平直、圆角平滑，无接缝跳变。返回 [{p:Vector2, n:Vector2}]。
static func _rounded_profile(hw: float, hh: float, r: float, segs: int) -> Array:
	var out: Array = []
	var corners := [
		[Vector2(hw - r, hh - r), 0.0],
		[Vector2(-(hw - r), hh - r), 90.0],
		[Vector2(-(hw - r), -(hh - r)), 180.0],
		[Vector2(hw - r, -(hh - r)), 270.0],
	]
	for c: Array in corners:
		for i in segs + 1:
			var ang := deg_to_rad(float(c[1]) + 90.0 * float(i) / float(segs))
			var nv := Vector2(cos(ang), sin(ang))
			out.append({ "p": (c[0] as Vector2) + nv * r, "n": nv })
	return out

## 贴面 quad：flip=true 时绕 Y 转 180°（面朝 -Z 且从该侧看贴图左右不镜像）。
func _add_face(id: String, parent: Node3D, pos: Vector3, flip: bool,
		size := Vector2(PANEL_W, PANEL_H)) -> void:
	var q := QuadMesh.new()
	q.size = size
	var mi := MeshInstance3D.new()
	mi.name = "Face_" + id
	mi.mesh = q
	mi.position = pos
	if flip:
		mi.rotation.y = PI
	mi.material_override = _paper_mat(Color(0.98, 0.96, 0.90)) # 白卡纸占位
	mi.layers = RENDER_LAYER
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_faces[id] = { "mesh": mi, "size": size }

## 纸面材质：吃光的哑光卡纸（纸艺观感第一支柱——素色材质+真实光照，PaperBook 同款）。
## 亮度稳定性不靠 unshaded，靠渲染层隔离：世界太阳不照手机、自带灯挂相机随视角走
## （见 attach_light_rig）。粗糙度拉满零高光；双面渲染省绕序心智负担。
static func _paper_mat(albedo: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = albedo
	m.roughness = 1.0
	m.metallic_specular = 0.0
	return m

## 自带灯 rig：挂到父节点（相机）——只照 RENDER_LAYER 的左上前方暖平行光
## （onboarding 故事书同参）。跟相机走 → 手机相对光向恒定，环绕世界不忽明忽暗；
## 环境光(AMBIENT_SOURCE_COLOR)无方向性天然稳定，保留补底。世界侧还需把太阳
## light_cull_mask 去掉 RENDER_LAYER（见 world._setup_environment）。
func attach_light_rig() -> void:
	var parent := get_parent() as Node3D
	if parent == null or parent.get_node_or_null("PhoneRigLight") != null:
		return
	var rig := DirectionalLight3D.new()
	rig.name = "PhoneRigLight"
	rig.light_cull_mask = RENDER_LAYER
	rig.rotation = Vector3(-0.95, -0.35, 0.0)
	rig.light_color = Color(1.0, 0.965, 0.90)
	rig.light_energy = 1.05
	rig.shadow_enabled = false
	parent.add_child(rig)

## 给某个贴面换贴图（AIGC 纸壳 / SubViewport 屏幕都走这里）。
## alpha=true 时开透明（正/背面壳贴图带圆角镂空）。
func set_face_texture(id: String, tex: Texture2D, alpha := false) -> void:
	var f: Dictionary = _faces.get(id, {})
	if f.is_empty():
		return
	var mat := (f["mesh"] as MeshInstance3D).material_override as StandardMaterial3D
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = tex
	if alpha:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

## ── SubViewport 屏幕 ────────────────────────────────────────────────────────

## 建两块屏幕内容视口并贴上贴面：正面主屏(front_px) + 背面跨页(spread_px，左右页各采样一半)。
## Control 树由业务层(phone_ui)塞进 front_viewport()/spread_viewport()。
func create_screens(front_px: Vector2i, spread_px: Vector2i) -> void:
	_front_vp = _make_screen_vp(front_px, false)
	# 跨页视口透明底：底图（phone3d_spread_bg）外侧角带圆角 alpha 镂空，
	# 摊开的双页剪影才跟芯板一样圆角（die-cut），不是四角戳出的方贴图。
	_spread_vp = _make_screen_vp(spread_px, true)
	# 正面屏幕区：内嵌于正面壳的 quad（浮出 2ε，拾取时先于 front 命中）
	_add_face(FACE_SCREEN, _panel_a, Vector3(0.0, 0.0, PANEL_T * 0.5 + FACE_EPS * 2.0), false,
		Vector2(PANEL_W, PANEL_H) * SCREEN_FRAC)
	_bind_vp_texture(FACE_SCREEN, _front_vp, Vector3.ONE, Vector3.ZERO, false)
	# 跨页左右页：同一块 spread 视口的左半/右半（uv1 scale/offset 切）
	_bind_vp_texture(FACE_SPREAD_L, _spread_vp, Vector3(0.5, 1.0, 1.0), Vector3.ZERO, true)
	_bind_vp_texture(FACE_SPREAD_R, _spread_vp, Vector3(0.5, 1.0, 1.0), Vector3(0.5, 0.0, 0.0), true)
	_update_screen_activity()

func _make_screen_vp(px: Vector2i, transparent: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = px
	vp.disable_3d = true
	vp.transparent_bg = transparent
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED # 收起时不烧 GPU
	add_child(vp)
	return vp

func _bind_vp_texture(face: String, vp: SubViewport, uv_scale: Vector3, uv_offset: Vector3,
		alpha: bool) -> void:
	var f: Dictionary = _faces.get(face, {})
	if f.is_empty():
		return
	var mat := (f["mesh"] as MeshInstance3D).material_override as StandardMaterial3D
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = vp.get_texture()
	mat.uv1_scale = uv_scale
	mat.uv1_offset = uv_offset
	if alpha:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

func front_viewport() -> SubViewport:
	return _front_vp

func spread_viewport() -> SubViewport:
	return _spread_vp

## 只让可见屏更新：正面态跑主屏、跨页态跑跨页、收起全停。
func _update_screen_activity() -> void:
	# 停靠态两块都停（时钟走字靠 refresh_dock_screen 低频 UPDATE_ONCE），使用态只跑可见屏
	if _front_vp != null:
		_front_vp.render_target_update_mode = \
			SubViewport.UPDATE_ALWAYS if state == State.FRONT else SubViewport.UPDATE_DISABLED
	if _spread_vp != null:
		_spread_vp.render_target_update_mode = \
			SubViewport.UPDATE_ALWAYS if state == State.SPREAD else SubViewport.UPDATE_DISABLED

## 贴面 uv → 屏幕视口像素（纯函数，headless 可单测）。
## 命中屏幕内容返回 { "vp": "front"|"spread", "px": Vector2 }；非屏区（壳）返回 {}。
static func screen_px(face: String, uv: Vector2, front_px: Vector2i, spread_px: Vector2i) -> Dictionary:
	match face:
		FACE_SCREEN:
			return { "vp": "front", "px": uv * Vector2(front_px) }
		FACE_SPREAD_L:
			return { "vp": "spread", "px": Vector2(uv.x * 0.5, uv.y) * Vector2(spread_px) }
		FACE_SPREAD_R:
			return { "vp": "spread", "px": Vector2(0.5 + uv.x * 0.5, uv.y) * Vector2(spread_px) }
	return {}

## 屏幕坐标鼠标/触摸(经 emulate mouse)事件 → 射线拾取 → 转发进对应 SubViewport。
## 返回 true=命中机身（含壳非屏区，事件被手机吞掉）；false=没打在手机上（调用方决定收起等）。
## 拖拽捕获：按下命中屏区后，后续拖动/松手投影到同一贴面转发（允许超出面外）——
## 否则拖出机身边缘会丢 release，ScrollContainer 永远停在拖拽态（图标分页实测）。
func route_gui_event(cam: Camera3D, ev: InputEvent) -> bool:
	if _front_vp == null or not (ev is InputEventMouse):
		return false
	var pos: Vector2 = (ev as InputEventMouse).position
	var ro := cam.project_ray_origin(pos)
	var rd := cam.project_ray_normal(pos)
	if _drag_face != "":
		var uv: Variant = _face_uv_unclamped(_drag_face, ro, rd)
		if uv is Vector2:
			var croute := screen_px(_drag_face, uv, _front_vp.size, _spread_vp.size)
			if not croute.is_empty():
				_push_to_vp(ev, croute)
		if ev is InputEventMouseButton and not (ev as InputEventMouseButton).pressed:
			_drag_face = "" # 松手结束捕获
		return true # 捕获期间事件都归手机
	var hit := pick(ro, rd)
	if hit.is_empty():
		return false
	var route := screen_px(String(hit["face"]), hit["uv"], _front_vp.size, _spread_vp.size)
	if route.is_empty():
		return true # 打在纸壳 bezel 上：吞掉但不进屏
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
		_drag_face = String(hit["face"])
	_push_to_vp(ev, route)
	return true

func _push_to_vp(ev: InputEvent, route: Dictionary) -> void:
	var dup := ev.duplicate() as InputEventMouse
	dup.position = route["px"]
	dup.global_position = route["px"]
	(_front_vp if String(route["vp"]) == "front" else _spread_vp).push_input(dup)

## 射线 vs 贴面所在无限平面（不裁剪矩形边界，拖拽捕获用）；平行/背离返回 null。
func _face_uv_unclamped(id: String, ro: Vector3, rd: Vector3) -> Variant:
	var f: Dictionary = _faces.get(id, {})
	if f.is_empty():
		return null
	var mesh := f["mesh"] as MeshInstance3D
	var xf := mesh.global_transform
	var n := xf.basis.z.normalized()
	var denom := rd.dot(n)
	if absf(denom) < 1e-6:
		return null
	var t := (xf.origin - ro).dot(n) / denom
	if t <= 0.0:
		return null
	var local := xf.affine_inverse() * (ro + rd * t)
	var size: Vector2 = (mesh.mesh as QuadMesh).size
	return Vector2(local.x / size.x + 0.5, 0.5 - local.y / size.y)

## ── 状态机 ──────────────────────────────────────────────────────────────────

## 搬到持机位（正面合拢态）：从停靠位=位移+放大；从跨页=原位翻回正面。
func show_front(animate := true) -> void:
	if state == State.FRONT:
		return
	var from_dock := state == State.DOCKED
	_set_state(State.FRONT)
	if not animate:
		_apply_pose(180.0, 0.0)
		position = _hand_pos
		scale = Vector3.ONE * _hand_scale
		_base_rot = Vector3.ZERO
		return
	if from_dock:
		_apply_pose(180.0, 0.0)
		_animate_move(_hand_pos, _hand_scale, Vector3.ZERO, false)
	else:
		_animate_flip(180.0, 0.0)

func show_spread(animate := true) -> void:
	if state == State.SPREAD:
		return
	_set_state(State.SPREAD)
	if not animate:
		position = _hand_pos
		scale = Vector3.ONE * _hand_scale
		_base_rot = Vector3.ZERO
		_apply_pose(0.0, 180.0)
		return
	_animate_flip(0.0, 180.0)

## 搬回停靠位（合拢正面朝屏的小手机）：跨页态时合拢+翻正与搬移并行。
func dock(animate := true) -> void:
	if state == State.DOCKED:
		return
	var was_spread := state == State.SPREAD
	_set_state(State.DOCKED)
	if not animate:
		_apply_pose(180.0, 0.0)
		position = _dock_pos
		scale = Vector3.ONE * _dock_scale
		_base_rot = DOCK_ROT
		return
	_animate_move(_dock_pos, _dock_scale, DOCK_ROT, was_spread)

func _set_state(s: int) -> void:
	state = s
	_drag_face = "" # 状态切换终止拖拽捕获（翻面/收起后旧面不再收事件）
	_update_screen_activity()
	state_changed.emit(s)

## ── 动画/姿态 ───────────────────────────────────────────────────────────────

## 摆姿态：fold=折叠角(180 合拢/0 摊平)、yaw=整机翻转角。
## 跨页态把 pivot 左移半页宽，使双页整体居中（A 占 x∈[-W/2,W/2]、B 翻到 +X 侧）。
func _apply_pose(fold_deg: float, yaw_deg: float) -> void:
	_fold_deg = fold_deg
	_yaw_deg = yaw_deg
	_hinge.rotation.y = deg_to_rad(fold_deg)
	_pivot.rotation.y = deg_to_rad(yaw_deg)
	var spread_frac := 1.0 - fold_deg / 180.0 # 0=合拢 → 1=摊平
	_pivot.position.x = -PANEL_W * 0.5 * spread_frac
	if _drop_shadow != null:
		_drop_shadow.scale.x = 1.0 + spread_frac # 摊平双倍宽，软影跟着加宽

func _animate_flip(fold_to: float, yaw_to: float) -> void:
	_kill_tween()
	scale = Vector3.ONE * _hand_scale
	var fold_from := _fold_deg
	var yaw_from := _yaw_deg
	_tween = create_tween().set_parallel(true)
	_tween.tween_method(func(t: float) -> void:
		_apply_pose(lerpf(fold_from, fold_to, t), lerpf(yaw_from, yaw_to, t)),
		0.0, 1.0, FLIP_DUR).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# 翻转恒在持机位发生：DOCKED→FRONT 的搬移 tween 若被打断（开手机后立刻开 app，
	# _kill_tween 掐断未走完的搬移），position 会卡在半路。这里把它并行收回 _hand_pos，
	# 否则跨页/正面会停在停靠位与持机位之间的随机位置（时左时右，取决于打断时机）。
	_tween.tween_property(self, "position", _hand_pos, FLIP_DUR) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## 停靠位↔持机位搬移：位移+缩放并行 tween（带一点回弹的"拿起/放回"手感）；
## fold_back=true 时（从跨页收）合拢+翻回正面与搬移并行。
func _animate_move(to_pos: Vector3, to_scale: float, to_rot: Vector3, fold_back: bool) -> void:
	_kill_tween()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(self, "position", to_pos, MOVE_DUR) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scale", Vector3.ONE * to_scale, MOVE_DUR) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "_base_rot", to_rot, MOVE_DUR) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if fold_back:
		var fold_from := _fold_deg
		var yaw_from := _yaw_deg
		_tween.tween_method(func(t: float) -> void:
			_apply_pose(lerpf(fold_from, 180.0, t), lerpf(yaw_from, 0.0, t)),
			0.0, 1.0, MOVE_DUR).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()

## ── 相机贴合 ────────────────────────────────────────────────────────────────

## 挂相机子节点后按竖直 FOV 反算大小/位置：机身高占屏 fill，中心落在 NDC(ndc.x, ndc.y)。
## dist 取小（默认 0.42）让手机比一切世界物件都近，天然不被树/山挡（近平面 0.05 仍有余量：
## 翻转扫掠半径 ~PANEL_W*scale < dist-near）。
static func _fit(cam: Camera3D, fill: float, ndc: Vector2, dist: float) -> Dictionary:
	var tanhalf := tan(deg_to_rad(cam.fov * 0.5))
	var vpn := cam.get_viewport()
	var vp := vpn.get_visible_rect().size if vpn != null else Vector2.ZERO
	var aspect := (vp.x / vp.y) if vp.y > 1.0 else (16.0 / 9.0)
	return {
		"scale": fill * 2.0 * dist * tanhalf / PANEL_H,
		"pos": Vector3(ndc.x * dist * tanhalf * aspect, ndc.y * dist * tanhalf, -dist),
	}

## 贴合持机位（使用态目标）；当前就在手上且没在动画中则立即应用。
func fit_hand(cam: Camera3D, fill: float, ndc: Vector2, dist := 0.42) -> void:
	var t := _fit(cam, fill, ndc, dist)
	_hand_pos = t["pos"]
	_hand_scale = t["scale"]
	if state != State.DOCKED and not _tween_running():
		position = _hand_pos
		scale = Vector3.ONE * _hand_scale

## 贴合停靠位（左下角"图标"目标）；停靠中则立即应用。首次贴合才现身（防原点闪现）。
func fit_dock(cam: Camera3D, fill: float, ndc: Vector2, dist := 0.42) -> void:
	var t := _fit(cam, fill, ndc, dist)
	_dock_pos = t["pos"]
	_dock_scale = t["scale"]
	if state == State.DOCKED and not _tween_running():
		position = _dock_pos
		scale = Vector3.ONE * _dock_scale
	if not _dock_fitted:
		_dock_fitted = true
		visible = true

func _tween_running() -> bool:
	return _tween != null and _tween.is_valid() and _tween.is_running()

## 是否正在播状态切换动画（开/关/翻页搬移未落定）。harness 据此 action-based 等待，
## 不靠卡 sleep 时长——改了动画时长/参数，等待逻辑照样对。
func is_settling() -> bool:
	return _tween_running()

## 停靠态低频刷一帧正面屏（时钟走字用；渲染一次自动回 DISABLED）。
func refresh_dock_screen() -> void:
	if state == State.DOCKED and _front_vp != null:
		_front_vp.render_target_update_mode = SubViewport.UPDATE_ONCE

## ── 射线拾取 ────────────────────────────────────────────────────────────────

## 射线 vs 有限矩形面（面的本地 +Z 为法线、尺寸 size，quad 居中）。
## 命中返回 { "dist": float, "uv": Vector2 }（uv 原点=贴图左上），否则 {}。
## 只认从正面打进来的（背面/平行拒绝）——纯数学，无物理体，headless 可单测。
static func face_uv(xf: Transform3D, size: Vector2, ro: Vector3, rd: Vector3) -> Dictionary:
	var n := xf.basis.z.normalized()
	var denom := rd.dot(n)
	if denom >= -1e-6: # 背面或平行
		return {}
	var t := (xf.origin - ro).dot(n) / denom
	if t <= 0.0:
		return {}
	var local := xf.affine_inverse() * (ro + rd * t)
	var u := local.x / size.x + 0.5
	var v := 0.5 - local.y / size.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return {}
	return { "dist": t, "uv": Vector2(u, v) }

## 当前状态下可交互的贴面
func _pickable_faces() -> Array:
	match state:
		State.FRONT:
			# 屏幕 quad 浮在正面壳之上（更近），pick 取最近命中 → 屏区优先给 screen
			return [FACE_SCREEN, FACE_FRONT] if _faces.has(FACE_SCREEN) else [FACE_FRONT]
		State.SPREAD:
			return [FACE_SPREAD_L, FACE_SPREAD_R]
	return [] # DOCKED：点击走透明热区按钮（world），机身不拾取

## 拾取：世界系射线 → 命中的贴面 id + uv。未中返回 {}。
func pick(ro: Vector3, rd: Vector3) -> Dictionary:
	var best := {}
	for id: String in _pickable_faces():
		var f: Dictionary = _faces[id]
		var mesh := f["mesh"] as MeshInstance3D
		var quad := mesh.mesh as QuadMesh
		var hit := face_uv(mesh.global_transform, quad.size, ro, rd)
		if hit.is_empty():
			continue
		if best.is_empty() or float(hit["dist"]) < float(best["dist"]):
			best = { "face": id, "uv": hit["uv"], "dist": hit["dist"] }
	return best

## 屏幕坐标是否打在机身任一可交互面上（真机 ScreenTouch 只吞不转发时用）。
func hit_test(cam: Camera3D, screen_pos: Vector2) -> bool:
	return not pick(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos)).is_empty()

## 贴面全局变换（测试/调试用）
func face_transform(id: String) -> Transform3D:
	var f: Dictionary = _faces.get(id, {})
	if f.is_empty():
		return Transform3D.IDENTITY
	return (f["mesh"] as MeshInstance3D).global_transform
