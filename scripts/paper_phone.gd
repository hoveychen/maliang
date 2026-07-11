class_name PaperPhone
extends Node3D
## 3D 纸糊双折叠手机（设计: docs/paper-phone-design.md）。
## 一张对折的"卡纸"：两块带厚度的面板 A/B，铰链在 A 左缘。
##   合拢态(FRONT)  = B 叠在 A 背后，A 外面就是手机正面（屏幕+贴纸图标）。
##   展开态(SPREAD) = 整机绕 Y 翻 180° 同时铰链摊平，两个内面变成双倍宽跨页。
## 本类只管 3D 载体：几何/状态机/动画/射线拾取，不懂任何业务（app 内容由
## SubViewport 贴上来，见 phone_ui.gd）。挂为 Camera3D 子节点，fit_to_camera 定位。
##
## 几何约定（本地单位，机身高恒为 1，整体大小由 fit_to_camera 的 scale 控制）：
##   面板 A 占 x∈[-W/2, W/2]，铰链在 (x=-W/2, z=-T/2)（背面边缘，纸板对折的真实轴）。
##   折叠角 fold: 180°=合拢（B 贴在 A 背后）、0°=摊平成跨页（B 占 x∈[-3W/2,-W/2]）。
##   整机 yaw: 0°=正面朝相机、180°=背面（跨页）朝相机。两者同 tween 并行播放。
##   跨页态 A 内面=左页、B 内面=右页（翻转后镜像正好左右各半）。

signal state_changed(new_state: int)

enum State { STOWED, FRONT, SPREAD }

const PANEL_ASPECT := 2.10        ## 机身高:宽 ≈ iPhone 直板比例
const PANEL_H := 1.0              ## 面板高（本地基准，勿改：fit 按此反算 scale）
const PANEL_W := PANEL_H / PANEL_ASPECT
const PANEL_T := 0.02             ## 纸板厚度（厚一点才有"纸糊玩具"的憨感）
const FACE_EPS := 0.002           ## 贴面浮出板面的间隙（防 z-fighting）
const FLIP_DUR := 0.45            ## 翻转+展开动画时长
const STOW_DUR := 0.28            ## 掏出/收起动画时长

## 贴面 id（射线拾取返回、set_face_texture 寻址）
const FACE_FRONT := "front"        ## A 外面：手机正面壳
const FACE_BACK := "back"          ## B 外面：手机背面壳（三摄岛）
const FACE_SPREAD_L := "spread_l"  ## A 内面：跨页左页
const FACE_SPREAD_R := "spread_r"  ## B 内面：跨页右页

var state: int = State.STOWED

var _pivot: Node3D                 ## 整机翻转（yaw）+ 跨页居中平移
var _hinge: Node3D                 ## 铰链（fold）
var _faces := {}                   ## face id → { mesh: MeshInstance3D, size: Vector2 }
var _fold_deg := 180.0
var _yaw_deg := 0.0
var _tween: Tween
var _fit_scale := 1.0              ## fit_to_camera 算出的整体 scale（stow 动画要用）

# 在 _init 建几何而非 _ready：headless 测试在 SceneTree._initialize 阶段节点尚未进树、
# _ready 会延迟到首帧，_init 保证 new() 出来即可用（show_front/pick 不依赖树状态）。
func _init() -> void:
	_build()
	visible = false
	_apply_pose(180.0, 0.0)

## ── 几何 ────────────────────────────────────────────────────────────────────

func _build() -> void:
	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)
	# 面板 A（固定）：薄纸板 + 外面(正面壳)/内面(跨页左页)两片贴面
	var panel_a := Node3D.new()
	panel_a.name = "PanelA"
	_pivot.add_child(panel_a)
	panel_a.add_child(_make_slab())
	_add_face(FACE_FRONT, panel_a, Vector3(0.0, 0.0, PANEL_T * 0.5 + FACE_EPS), false)
	_add_face(FACE_SPREAD_L, panel_a, Vector3(0.0, 0.0, -PANEL_T * 0.5 - FACE_EPS), true)
	# 铰链在 A 左缘的背面边（纸板对折的真实轴）：绕 Y 转 180° 正好把 B 叠到 A 背后
	_hinge = Node3D.new()
	_hinge.name = "Hinge"
	_hinge.position = Vector3(-PANEL_W * 0.5, 0.0, -PANEL_T * 0.5)
	_pivot.add_child(_hinge)
	# 面板 B（挂铰链）：摊平时占铰链系 x∈[-W,0]、z∈[0,T]（背面与 A 背面共面）
	var panel_b := Node3D.new()
	panel_b.name = "PanelB"
	panel_b.position = Vector3(-PANEL_W * 0.5, 0.0, PANEL_T * 0.5)
	_hinge.add_child(panel_b)
	panel_b.add_child(_make_slab())
	_add_face(FACE_BACK, panel_b, Vector3(0.0, 0.0, PANEL_T * 0.5 + FACE_EPS), false)
	_add_face(FACE_SPREAD_R, panel_b, Vector3(0.0, 0.0, -PANEL_T * 0.5 - FACE_EPS), true)

## 纸板芯：面板的厚度体（侧面即纸边）。贴面用独立 quad 盖在两大面上。
func _make_slab() -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3(PANEL_W, PANEL_H, PANEL_T)
	var mi := MeshInstance3D.new()
	mi.name = "Slab"
	mi.mesh = box
	mi.material_override = _paper_mat(Color(0.93, 0.90, 0.83)) # 纸板切边米白
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

## 贴面 quad：flip=true 时绕 Y 转 180°（面朝 -Z 且从该侧看贴图左右不镜像）。
func _add_face(id: String, parent: Node3D, pos: Vector3, flip: bool) -> void:
	var q := QuadMesh.new()
	q.size = Vector2(PANEL_W, PANEL_H)
	var mi := MeshInstance3D.new()
	mi.name = "Face_" + id
	mi.mesh = q
	mi.position = pos
	if flip:
		mi.rotation.y = PI
	mi.material_override = _paper_mat(Color(0.98, 0.96, 0.90)) # 白卡纸占位
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_faces[id] = { "mesh": mi, "size": Vector2(PANEL_W, PANEL_H) }

## 纸面材质：unshaded 保证纸面亮度稳定（不吃场景光/world-bend），有贴图时走贴图。
static func _paper_mat(albedo: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = albedo
	return m

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

## ── 状态机 ──────────────────────────────────────────────────────────────────

func show_front(animate := true) -> void:
	if state == State.FRONT:
		return
	var from_stow := state == State.STOWED
	_set_state(State.FRONT)
	visible = true
	if not animate:
		scale = Vector3.ONE * _fit_scale
		_apply_pose(180.0, 0.0)
		return
	if from_stow:
		_apply_pose(180.0, 0.0)
		_animate_stow(true)
	else:
		_animate_flip(180.0, 0.0)

func show_spread(animate := true) -> void:
	if state == State.SPREAD:
		return
	_set_state(State.SPREAD)
	visible = true
	if not animate:
		scale = Vector3.ONE * _fit_scale
		_apply_pose(0.0, 180.0)
		return
	_animate_flip(0.0, 180.0)

func stow(animate := true) -> void:
	if state == State.STOWED:
		return
	_set_state(State.STOWED)
	if not animate:
		visible = false
		return
	_animate_stow(false)

func _set_state(s: int) -> void:
	state = s
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

func _animate_flip(fold_to: float, yaw_to: float) -> void:
	_kill_tween()
	scale = Vector3.ONE * _fit_scale
	var fold_from := _fold_deg
	var yaw_from := _yaw_deg
	_tween = create_tween()
	_tween.tween_method(func(t: float) -> void:
		_apply_pose(lerpf(fold_from, fold_to, t), lerpf(yaw_from, yaw_to, t)),
		0.0, 1.0, FLIP_DUR).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## 掏出/收起：整体缩放弹入/弹出（收起完把节点藏掉，SubViewport 才好停更新）。
func _animate_stow(appearing: bool) -> void:
	_kill_tween()
	_tween = create_tween()
	if appearing:
		scale = Vector3.ONE * _fit_scale * 0.05
		_tween.tween_property(self, "scale", Vector3.ONE * _fit_scale, STOW_DUR) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		_tween.tween_property(self, "scale", Vector3.ONE * _fit_scale * 0.05, STOW_DUR) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_tween.tween_callback(func() -> void: visible = false)

func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()

## ── 相机贴合 ────────────────────────────────────────────────────────────────

## 挂相机子节点后按竖直 FOV 反算大小/位置：机身高占屏 fill，中心落在 NDC(ndc.x, ndc.y)。
## dist 取小（默认 0.42）让手机比一切世界物件都近，天然不被树/山挡（近平面 0.05 仍有余量：
## 翻转扫掠半径 ~PANEL_W*scale < dist-near）。
func fit_to_camera(cam: Camera3D, fill: float, ndc: Vector2, dist := 0.42) -> void:
	var tanhalf := tan(deg_to_rad(cam.fov * 0.5))
	var vpn := cam.get_viewport()
	var vp := vpn.get_visible_rect().size if vpn != null else Vector2.ZERO
	var aspect := (vp.x / vp.y) if vp.y > 1.0 else (16.0 / 9.0)
	_fit_scale = fill * 2.0 * dist * tanhalf / PANEL_H
	scale = Vector3.ONE * _fit_scale
	position = Vector3(ndc.x * dist * tanhalf * aspect, ndc.y * dist * tanhalf, -dist)

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
			return [FACE_FRONT]
		State.SPREAD:
			return [FACE_SPREAD_L, FACE_SPREAD_R]
	return []

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

## 贴面全局变换（测试/调试用）
func face_transform(id: String) -> Transform3D:
	var f: Dictionary = _faces.get(id, {})
	if f.is_empty():
		return Transform3D.IDENTITY
	return (f["mesh"] as MeshInstance3D).global_transform
