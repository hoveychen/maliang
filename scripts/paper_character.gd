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

## X 光穿透剪影开关（AdaptiveQuality 档位驱动，同 SdfProp._snap_iters 模式）：
## 该 pass 每角色每帧多画一个全 quad 透明面并逐像素采样深度图，老 Mali 上深度采样
## 打断 tiled 渲染快路径。默认全平台开——角色走到房子/树后面仍见剪影是体验的一部分
## （老板拍板 T1 保留），只有 T2 最弱档由 AdaptiveQuality 摘除。
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

func _enter_tree() -> void:
	add_to_group("paper_chars")  # set_xray_enabled 换档批量寻址用

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
	BlobShadow.attach(self, clampf(float(tex.get_width()) * pixel_size * 0.38, 0.4, 1.4))

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
	BlobShadow.attach(self, clampf(cw * pixel_size * 0.38, 0.4, 1.4))

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
