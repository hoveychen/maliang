class_name PaperBook
extends Node3D
## 3D 卡纸故事书（onboarding 用，仿 PaperPhone 套路）。
## 一本摊开的精装绘本：带厚度的封面板/书脊 + 左右两摞页堆（侧面看得见一页页）+
## 弯曲页面网格——纸面从书脊沟槽（gutter）下潜再爬上页堆顶，插画贴上去会真实凹陷变形。
## 本类只管 3D 载体：几何/剖面数学/姿态/射线拾取；页面内容由 SubViewport 贴上来
## （spread 视口左右页各采样半幅 UV，PaperPhone 同款），业务在 onboarding.gd。
##
## 几何约定（本地单位，页高恒为 1，整体大小由 fit_to_camera 的 scale 控制）：
##   书摊平在本地 XY 面、+Z 朝相机（俯视倾角由宿主设 rotation 提供）。
##   书脊中线在 x=0：右页剖面 x∈[0, PAGE_W]，左页镜像 x∈[-PAGE_W, 0]。
##   z 轴叠层：封面板 z∈[0, COVER_T]，页堆坐在板顶（剖面 z 以板顶为 0 基准）。
##   开合是铰链链：右板固定 → 书脊板（铰链在右板左缘）→ 前封面板（铰链在书脊左缘）。
##   左页堆挂在前封面铰链上——合书时它翻转叠在右页堆顶（=真实的"翻到书中间"物理），
##   开书动画一次带出"封面+左半摞页"整体翻开的效果。
##   open_frac 0=合上 → 1=摊平；progress 0..1=翻书进度（左堆增厚、右堆变薄）。

const PAGE_H := 1.0               ## 页高（本地基准，勿改：fit 按此反算 scale）
const PAGE_W := 0.85              ## 单页宽（跨页 1.7:1，对齐 story 插画宽幅比例）
const PAGE_STACK_T := 0.085       ## 页堆总厚（左+右恒等于它；厚书才有"书册边缘"）
const STACK_BASE_FRAC := 0.35     ## 两侧页堆基线占比（走进度的只有中间 30%，两边始终厚）
const COVER_T := 0.030            ## 精装封面板厚
const COVER_MARGIN := 0.045       ## 封面板比页面多出的裙边
const BIND_Z := 0.010             ## 书脊装订点高度（纸面在书脊处下潜到这里）
const SEGS := 20                  ## 页面剖面分段数（弯曲网格与拾取共用）
const SPINE_W := PAGE_STACK_T + COVER_T + 0.014  ## 书脊板宽=合书时的书侧高
const FACE_EPS := 0.0015          ## 贴面浮起间隙（防 z-fighting）
const EDGE_LINE_SCALE := 18.0     ## 页缘细线密度（z 每单位的纹理重复数，64px 纹理≈21 条线）

## 拾取面 id
const FACE_PAGE_L := "page_l"
const FACE_PAGE_R := "page_r"

var _spread_vp: SubViewport            ## 跨页内容视口（create_spread 后有效）
var _hinge_spine: Node3D
var _hinge_front: Node3D
var _board_front: MeshInstance3D
var _page_l: MeshInstance3D            ## 左页堆（挂前封面铰链：合书时翻叠到右堆顶）
var _page_r: MeshInstance3D
var _sheet: MeshInstance3D             ## 翻页纸（翻页动画期间可见，P3）
var _page_mat_l: StandardMaterial3D    ## 左页纸面材质（顶面，贴 spread 左半）
var _page_mat_r: StandardMaterial3D
var _edge_mat: StandardMaterial3D      ## 页缘（一页页细线）
var _sheet_mat_f: StandardMaterial3D   ## 翻页纸正面（旧右页快照）
var _sheet_mat_b: StandardMaterial3D   ## 翻页纸背面（新左页,live）
var _open_frac := 1.0
var _progress := 0.0
var _turning := false
## 拾取缓存：face id → [{xf: Transform3D(页块本地), size: Vector2, u0, u1}]，
## 弯曲面按剖面分段近似成平面矩形条。
var _pick_segs := {}

func _init() -> void:
	_build()

# ── 剖面纯数学（headless 可单测）────────────────────────────────────────────

## 页面剖面：书脊(x=0)→前口(x=w)，返回 segs+1 个 (x, z)。z 以封面板顶为 0：
## 书脊处下潜到装订点 bind_z，经 smoothstep 谷壁爬升到页堆顶 t，其后平铺。
## 谷宽随页堆增厚变宽（厚书沟深谷宽）。
static func page_profile(t: float, w: float, segs: int, bind_z := BIND_Z) -> PackedVector2Array:
	var dw := clampf(0.16 + 2.2 * t, 0.18, 0.40) * w
	var pts := PackedVector2Array()
	for i in segs + 1:
		var x := w * float(i) / float(segs)
		var k := clampf(x / dw, 0.0, 1.0)
		var s := k * k * (3.0 - 2.0 * k)
		pts.append(Vector2(x, bind_z + maxf(t - bind_z, 0.0) * s))
	return pts

## 剖面各点归一化弧长（0=书脊，1=前口）。纸面贴图按弧长展开——
## 谷壁斜着走的路程比水平投影长，贴图在沟槽里被"压缩"，这就是凹陷变形感的来源。
static func profile_us(pts: PackedVector2Array) -> PackedFloat32Array:
	var acc := PackedFloat32Array()
	acc.resize(pts.size())
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
		acc[i] = total
	if total > 0.0:
		for i in acc.size():
			acc[i] = acc[i] / total
	return acc

## 剖面各点明暗（顶点色烘焙的沟槽阴影）：材质 unshaded 保纸面亮度稳定，
## 凹陷立体感靠它——越深入沟槽越暗，页堆顶=1。
static func profile_shade(pts: PackedVector2Array, t: float, bind_z := BIND_Z) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(pts.size())
	var depth_range := maxf(t - bind_z, 1e-5)
	for i in pts.size():
		var d := clampf((t - pts[i].y) / depth_range, 0.0, 1.0)
		out[i] = 1.0 - 0.42 * pow(d, 1.15)
	return out

## 翻页纸形变（P3 翻页动画用）：右页剖面 → 左页剖面（镜像）的弧线插值。
## k∈[0,1] 翻页进度；每个顶点沿"起点→终点直线 + 抛物线上抬"走，
## k=0/1 与静止剖面严丝合缝（无跳变），k=0.5 时纸立在书脊正上方成拱。
static func sheet_points(rest_r: PackedVector2Array, rest_l: PackedVector2Array, k: float) -> PackedVector2Array:
	var n := rest_r.size()
	var out := PackedVector2Array()
	out.resize(n)
	var arc := 0.0
	var lift := 4.0 * k * (1.0 - k)
	for i in n:
		if i > 0:
			arc += rest_r[i].distance_to(rest_r[i - 1])
		var a := rest_r[i]
		var b := Vector2(-rest_l[i].x, rest_l[i].y)
		var p := a.lerp(b, k)
		p.y += lift * arc * 0.92
		out[i] = p
	return out

## 页堆厚度分配：进度 0→1，左堆从基线长到基线+可变段，右堆反向。两侧永远 ≥ 基线厚。
static func stack_split(progress: float) -> Vector2:
	var vari := 1.0 - 2.0 * STACK_BASE_FRAC
	var l := PAGE_STACK_T * (STACK_BASE_FRAC + vari * clampf(progress, 0.0, 1.0))
	return Vector2(l, PAGE_STACK_T - l)

## 页面 uv → 跨页视口像素（左页采样左半、右页右半；u 0=书脊 1=前口）。
static func spread_px(face: String, uv: Vector2, px: Vector2i) -> Vector2:
	var sx := (0.5 + 0.5 * uv.x) if face == FACE_PAGE_R else (0.5 - 0.5 * uv.x)
	return Vector2(sx, uv.y) * Vector2(px)

# ── 几何 ─────────────────────────────────────────────────────────────────────

func _build() -> void:
	var board_w := PAGE_W + COVER_MARGIN
	# 右封面板（固定，=后封面）
	add_child(_make_board("BoardR", board_w,
		Vector3(SPINE_W * 0.5 + board_w * 0.5, 0.0, COVER_T * 0.5)))
	# 书脊板（铰链在右板左缘 x=SPINE_W/2）→ 前封面板（铰链在书脊左缘）
	_hinge_spine = Node3D.new()
	_hinge_spine.name = "HingeSpine"
	_hinge_spine.position = Vector3(SPINE_W * 0.5, 0.0, 0.0)
	add_child(_hinge_spine)
	_hinge_spine.add_child(_make_board("BoardSpine", SPINE_W,
		Vector3(-SPINE_W * 0.5, 0.0, COVER_T * 0.5)))
	_hinge_front = Node3D.new()
	_hinge_front.name = "HingeFront"
	_hinge_front.position = Vector3(-SPINE_W, 0.0, 0.0)
	_hinge_spine.add_child(_hinge_front)
	_board_front = _make_board("BoardFront", board_w, Vector3(-board_w * 0.5, 0.0, COVER_T * 0.5))
	_hinge_front.add_child(_board_front)
	# 页堆材质：纸面（跨页贴图+顶点色沟槽阴影）+ 页缘细线
	_page_mat_l = _paper_mat(Color(0.97, 0.95, 0.90))
	_page_mat_r = _paper_mat(Color(0.97, 0.95, 0.90))
	_page_mat_l.vertex_color_use_as_albedo = true
	_page_mat_r.vertex_color_use_as_albedo = true
	_edge_mat = _paper_mat(Color.WHITE)
	_edge_mat.albedo_texture = _make_edge_texture()
	# 左页堆挂前封面铰链（合书时随铰链链翻叠到右堆顶）；本地系补回铰链偏移，
	# 摊平时与挂根节点完全等价（world = hinge_open(-S/2) * local(+S/2)）。
	_page_l = MeshInstance3D.new()
	_page_l.name = "PageL"
	_page_l.position = Vector3(SPINE_W * 0.5, 0.0, COVER_T)
	_hinge_front.add_child(_page_l)
	_page_r = MeshInstance3D.new()
	_page_r.name = "PageR"
	_page_r.position = Vector3(0.0, 0.0, COVER_T)
	add_child(_page_r)
	# 翻页纸（翻页动画期间才可见）
	_sheet_mat_f = _paper_mat(Color(0.97, 0.95, 0.90))
	_sheet_mat_b = _paper_mat(Color(0.97, 0.95, 0.90))
	_sheet = MeshInstance3D.new()
	_sheet.name = "Sheet"
	_sheet.position = Vector3(0.0, 0.0, COVER_T)
	_sheet.visible = false
	add_child(_sheet)
	rebuild_pages()
	set_open_frac(1.0)

func _make_board(bname: String, w: float, pos: Vector3) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3(w, PAGE_H + COVER_MARGIN * 2.0, COVER_T)
	var mi := MeshInstance3D.new()
	mi.name = bname
	mi.mesh = box
	mi.position = pos
	mi.material_override = _paper_mat(Color(0.78, 0.45, 0.40)) # 布面精装酒红占位（P4 换贴图）
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

## 纸面材质：unshaded 保证亮度稳定（沟槽立体感靠顶点色，见 profile_shade）；
## 双面渲染省掉绕序心智负担（几何量小，代价可忽略）。
static func _paper_mat(albedo: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = albedo
	return m

## 页缘贴图：程序化"一页页"细线（沿 v 重复的深浅纸线），贴页堆侧壁。
static func _make_edge_texture() -> ImageTexture:
	var img := Image.create(8, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		var base := 0.90 + 0.06 * sin(float(y) * 1.7)
		var line := 0.74 if (y % 3 == 0) else base
		for x in 8:
			img.set_pixel(x, y, Color(line, line * 0.985, line * 0.94))
	return ImageTexture.create_from_image(img)

## 按当前 progress 重建左右页堆（顶面弯曲纸面 + 前口/上下页缘侧壁）+ 拾取缓存。
func rebuild_pages() -> void:
	var split := stack_split(_progress)
	_build_page_block(_page_l, split.x, true)
	_build_page_block(_page_r, split.y, false)

## 单侧页堆网格：surface0=顶面（跨页贴图+顶点色沟槽阴影）、surface1=页缘侧壁。
## mirror=true 为左页（x 取负；注意左页挂在铰链下，本地系相对 _page_l 自身）。
func _build_page_block(mi: MeshInstance3D, t: float, mirror: bool) -> void:
	var pts := page_profile(t, PAGE_W, SEGS)
	var us := profile_us(pts)
	var shade := profile_shade(pts, t)
	var sx := -1.0 if mirror else 1.0
	var hy := PAGE_H * 0.5
	# 顶面：SEGS 条矩形带（v: 0=页顶 1=页底）
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEGS:
		var a := pts[i]
		var b := pts[i + 1]
		_quad(st,
			Vector3(sx * a.x, hy, a.y + FACE_EPS), Vector3(sx * b.x, hy, b.y + FACE_EPS),
			Vector3(sx * b.x, -hy, b.y + FACE_EPS), Vector3(sx * a.x, -hy, a.y + FACE_EPS),
			Vector2(us[i], 0.0), Vector2(us[i + 1], 0.0), Vector2(us[i + 1], 1.0), Vector2(us[i], 1.0),
			Color(shade[i], shade[i], shade[i]), Color(shade[i + 1], shade[i + 1], shade[i + 1]))
	var top := st.commit()
	# 页缘侧壁：前口立面 + 上下沿剖面的曲面裙（细线贴图=一页页）
	var se := SurfaceTool.new()
	se.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fe := pts[SEGS]
	_quad(se,
		Vector3(sx * fe.x, hy, fe.y), Vector3(sx * fe.x, hy, 0.0),
		Vector3(sx * fe.x, -hy, 0.0), Vector3(sx * fe.x, -hy, fe.y),
		Vector2(0.0, fe.y * EDGE_LINE_SCALE), Vector2(0.0, 0.0),
		Vector2(1.0, 0.0), Vector2(1.0, fe.y * EDGE_LINE_SCALE),
		Color.WHITE, Color.WHITE)
	for i in SEGS:
		var a := pts[i]
		var b := pts[i + 1]
		for side: float in [1.0, -1.0]:
			_quad(se,
				Vector3(sx * a.x, side * hy, a.y), Vector3(sx * b.x, side * hy, b.y),
				Vector3(sx * b.x, side * hy, 0.0), Vector3(sx * a.x, side * hy, 0.0),
				Vector2(0.2, a.y * EDGE_LINE_SCALE), Vector2(0.8, b.y * EDGE_LINE_SCALE),
				Vector2(0.8, 0.0), Vector2(0.2, 0.0),
				Color.WHITE, Color.WHITE)
	var walls := se.commit()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, top.surface_get_arrays(0))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, walls.surface_get_arrays(0))
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_surface_override_material(0, _page_mat_l if mirror else _page_mat_r)
	mi.set_surface_override_material(1, _edge_mat)
	# 拾取缓存：每条带一个平面矩形（页块本地系）。face_uv 约定 basis.x=u 增方向、
	# basis.y=+Y（v=0 在页顶）、basis.z=朝外法线；镜像页只翻 bz（face_uv 走
	# affine_inverse，不要求右手系，u/v 由 x/y 轴独立决定）。
	var segs_cache: Array = []
	for i in SEGS:
		var a := pts[i]
		var b := pts[i + 1]
		var mid := Vector3(sx * (a.x + b.x) * 0.5, 0.0, (a.y + b.y) * 0.5 + FACE_EPS)
		var dx := Vector3(sx * (b.x - a.x), 0.0, b.y - a.y)
		var w := dx.length()
		var bx := dx / w
		var by := Vector3(0.0, 1.0, 0.0)
		var bz := bx.cross(by)
		if bz.z < 0.0:
			bz = -bz
		segs_cache.append({
			"xf": Transform3D(Basis(bx, by, bz), mid),
			"size": Vector2(w, PAGE_H),
			"u0": us[i], "u1": us[i + 1],
		})
	_pick_segs[FACE_PAGE_L if mirror else FACE_PAGE_R] = segs_cache

## 四边形（两三角）帮手：p1..p4 依次一圈，p1/p4 用 c_a、p2/p3 用 c_b。
static func _quad(st: SurfaceTool,
		p1: Vector3, p2: Vector3, p3: Vector3, p4: Vector3,
		uv1: Vector2, uv2: Vector2, uv3: Vector2, uv4: Vector2,
		c_a: Color, c_b: Color) -> void:
	for spec: Array in [[p1, uv1, c_a], [p2, uv2, c_b], [p3, uv3, c_b],
			[p1, uv1, c_a], [p3, uv3, c_b], [p4, uv4, c_a]]:
		st.set_color(spec[2] as Color)
		st.set_uv(spec[1] as Vector2)
		st.add_vertex(spec[0] as Vector3)

# ── 姿态 ─────────────────────────────────────────────────────────────────────

## 开合：0=合上（书脊立起 90°、前封面再折 90° 连同左页堆盖到右堆顶）→ 1=完全摊平。
func set_open_frac(f: float) -> void:
	_open_frac = clampf(f, 0.0, 1.0)
	var closed := 1.0 - _open_frac
	_hinge_spine.rotation.y = deg_to_rad(90.0) * closed
	_hinge_front.rotation.y = deg_to_rad(90.0) * closed

func open_frac() -> float:
	return _open_frac

## 翻书进度（0..1）：左右页堆厚度此消彼长，重建网格。
func set_progress(p: float) -> void:
	_progress = clampf(p, 0.0, 1.0)
	rebuild_pages()

func progress() -> float:
	return _progress

func is_turning() -> bool:
	return _turning

# ── 动画：开书 / 翻页 ────────────────────────────────────────────────────────

## 合书→摊平（协程，await 到动画完）。封面连同左半摞页整体翻开，右页内容渐次露出。
func play_open(dur := 0.9) -> void:
	var tw := create_tween()
	tw.tween_method(set_open_frac, _open_frac, 1.0, dur) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

## 真实翻页（协程）：一张纸从右页顶起、绕书脊划拱、落到左页顶。
## 编排：快照冻结旧跨页 → swap_content 换新内容（live）→ 右堆先按新进度变薄
## （新右页在翻页纸下方渐次露出）→ 纸沿 sheet_points 弧线逐帧变形 → 落地后
## 左堆按新进度增厚、左页解冻回 live。
## swap_content: 调用方在此回调里把跨页 Control 树换成新页内容。
func turn_page(swap_content: Callable, new_progress: float, dur := 0.55) -> void:
	if _turning or _spread_vp == null:
		if not swap_content.is_null():
			swap_content.call()
		return
	_turning = true
	var old_split := stack_split(_progress)
	_progress = clampf(new_progress, 0.0, 1.0)
	var new_split := stack_split(_progress)
	# 快照旧跨页（headless dummy 渲染器可能给空图：跳过冻结，动画照跑）
	var snap := _snapshot_spread()
	if snap != null:
		_page_mat_l.albedo_texture = snap   # 左页冻结在旧内容（uv 变换不变）
		_sheet_mat_f.albedo_texture = snap  # 纸正面=旧右页
		_sheet_mat_f.albedo_color = Color.WHITE
		_sheet_mat_f.uv1_scale = Vector3(0.5, 1.0, 1.0)
		_sheet_mat_f.uv1_offset = Vector3(0.5, 0.0, 0.0)
		_sheet_mat_b.albedo_texture = _spread_vp.get_texture() # 纸背面=新左页(live)
		_sheet_mat_b.albedo_color = Color.WHITE
		_sheet_mat_b.uv1_scale = Vector3(-0.5, 1.0, 1.0)
		_sheet_mat_b.uv1_offset = Vector3(0.5, 0.0, 0.0)
	swap_content.call()
	# 右堆立刻按新进度变薄（翻页纸盖在上面,新右页内容在纸下渐次露出）；左堆落地才增厚
	_build_page_block(_page_r, new_split.y, false)
	var rest_r := page_profile(old_split.y, PAGE_W, SEGS)
	var rest_l := page_profile(new_split.x, PAGE_W, SEGS)
	_sheet.visible = true
	var tw := create_tween()
	tw.tween_method(func(k: float) -> void:
		_update_sheet_mesh(sheet_points(rest_r, rest_l, k)),
		0.0, 1.0, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	_sheet.visible = false
	_build_page_block(_page_l, new_split.x, true)
	if snap != null:
		_page_mat_l.albedo_texture = _spread_vp.get_texture() # 左页解冻回 live
	_turning = false

## 快照当前跨页视口；headless dummy 渲染器拿不到像素时返回 null。
func _snapshot_spread() -> ImageTexture:
	var img := _spread_vp.get_texture().get_image()
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)

## 按翻页曲线点重建翻页纸网格：正/背两片沿曲线法向各偏 ε（防共面 z-fighting，
## 材质双面渲染下背面片会遮住正面片的反面）。uv=归一化弧长（与 sheet_points 同源）。
func _update_sheet_mesh(pts: PackedVector2Array) -> void:
	var n := pts.size()
	var arcs := PackedFloat32Array()
	arcs.resize(n)
	var total := 0.0
	for i in range(1, n):
		total += pts[i].distance_to(pts[i - 1])
		arcs[i] = total
	var hy := PAGE_H * 0.5
	var st_f := SurfaceTool.new()
	st_f.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_b := SurfaceTool.new()
	st_b.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in n - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var tg := (b - a).normalized()
		var nrm := Vector2(-tg.y, tg.x) # 曲线左法向（k=0 平铺时朝上）
		var ua := arcs[i] / maxf(total, 1e-6)
		var ub := arcs[i + 1] / maxf(total, 1e-6)
		var af := a + nrm * FACE_EPS
		var bf := b + nrm * FACE_EPS
		var ab := a - nrm * FACE_EPS
		var bb := b - nrm * FACE_EPS
		_quad(st_f,
			Vector3(af.x, hy, af.y), Vector3(bf.x, hy, bf.y),
			Vector3(bf.x, -hy, bf.y), Vector3(af.x, -hy, af.y),
			Vector2(ua, 0.0), Vector2(ub, 0.0), Vector2(ub, 1.0), Vector2(ua, 1.0),
			Color.WHITE, Color.WHITE)
		_quad(st_b,
			Vector3(ab.x, hy, ab.y), Vector3(bb.x, hy, bb.y),
			Vector3(bb.x, -hy, bb.y), Vector3(ab.x, -hy, ab.y),
			Vector2(ua, 0.0), Vector2(ub, 0.0), Vector2(ub, 1.0), Vector2(ua, 1.0),
			Color.WHITE, Color.WHITE)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st_f.commit().surface_get_arrays(0))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st_b.commit().surface_get_arrays(0))
	_sheet.mesh = mesh
	_sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sheet.set_surface_override_material(0, _sheet_mat_f)
	_sheet.set_surface_override_material(1, _sheet_mat_b)

# ── SubViewport 跨页内容 ─────────────────────────────────────────────────────

## 建跨页内容视口并贴上左右页面（Control 树由业务层塞进 spread_viewport()）。
func create_spread(px: Vector2i) -> void:
	_spread_vp = SubViewport.new()
	_spread_vp.size = px
	_spread_vp.disable_3d = true
	_spread_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_spread_vp)
	var tex := _spread_vp.get_texture()
	# 右页网格 u∈[0,1]（0=书脊）采样右半幅：scale 0.5、offset 0.5
	_page_mat_r.albedo_color = Color.WHITE
	_page_mat_r.albedo_texture = tex
	_page_mat_r.uv1_scale = Vector3(0.5, 1.0, 1.0)
	_page_mat_r.uv1_offset = Vector3(0.5, 0.0, 0.0)
	# 左页网格 u 也是 0=书脊，采样左半幅需反向：scale -0.5、offset 0.5
	_page_mat_l.albedo_color = Color.WHITE
	_page_mat_l.albedo_texture = tex
	_page_mat_l.uv1_scale = Vector3(-0.5, 1.0, 1.0)
	_page_mat_l.uv1_offset = Vector3(0.5, 0.0, 0.0)

func spread_viewport() -> SubViewport:
	return _spread_vp

# ── 射线拾取（PaperPhone.face_uv 同款数学，弯曲面=分段平面近似）────────────────

## 拾取：世界系射线 → { face, uv(u 0=书脊 1=前口, v 0=页顶 1=页底), dist }；未中 {}。
func pick(ro: Vector3, rd: Vector3) -> Dictionary:
	if _open_frac < 0.999 or _turning:
		return {} # 合书/开合/翻页动画期间页面不可交互
	var best := {}
	for face: String in _pick_segs:
		var base := (_page_l if face == FACE_PAGE_L else _page_r).global_transform
		for seg: Dictionary in (_pick_segs[face] as Array):
			var hit := PaperPhone.face_uv(base * (seg["xf"] as Transform3D), seg["size"] as Vector2, ro, rd)
			if hit.is_empty():
				continue
			if best.is_empty() or float(hit["dist"]) < float(best["dist"]):
				var uv := hit["uv"] as Vector2
				best = {
					"face": face,
					"uv": Vector2(lerpf(float(seg["u0"]), float(seg["u1"]), uv.x), uv.y),
					"dist": hit["dist"],
				}
	return best

## 屏幕坐标事件 → 射线拾取 → 转发进跨页视口（PaperPhone.route_gui_event 同款，
## 无拖拽捕获——绘本页只有大按钮点击，无滚动）。返回 true=命中书页。
func route_gui_event(cam: Camera3D, ev: InputEvent) -> bool:
	if _spread_vp == null or not (ev is InputEventMouse):
		return false
	var pos: Vector2 = (ev as InputEventMouse).position
	var hit := pick(cam.project_ray_origin(pos), cam.project_ray_normal(pos))
	if hit.is_empty():
		return false
	var dup := ev.duplicate() as InputEventMouse
	var px := spread_px(String(hit["face"]), hit["uv"] as Vector2, _spread_vp.size)
	dup.position = px
	dup.global_position = px
	_spread_vp.push_input(dup)
	return true

# ── 相机贴合 ─────────────────────────────────────────────────────────────────

## 挂相机子节点后按竖直 FOV 反算大小/位置：跨页宽占屏 fill，中心落 NDC(ndc.x, ndc.y)。
func fit_to_camera(cam: Camera3D, fill: float, ndc: Vector2, dist := 1.6) -> void:
	var tanhalf := tan(deg_to_rad(cam.fov * 0.5))
	var vpn := cam.get_viewport()
	var vp := vpn.get_visible_rect().size if vpn != null else Vector2.ZERO
	var aspect := (vp.x / vp.y) if vp.y > 1.0 else (16.0 / 9.0)
	var spread_w := PAGE_W * 2.0 + COVER_MARGIN * 2.0
	var view_w := 2.0 * dist * tanhalf * aspect
	position = Vector3(ndc.x * dist * tanhalf * aspect, ndc.y * dist * tanhalf, -dist)
	scale = Vector3.ONE * (fill * view_w / spread_w)
