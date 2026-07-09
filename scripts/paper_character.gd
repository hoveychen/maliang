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

var texture: Texture2D = null:
	set(v):
		texture = v
		_mat.set_shader_parameter("albedo_tex", v)
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
## idle 动画图集 meta（空=静态整图）；非空时几何按单格 cellW×cellH 算、shader 分格播放。
var _sheet: Dictionary = {}

func _init() -> void:
	if _shader == null:
		_shader = load("res://shaders/paper_character.gdshader")
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	var q := QuadMesh.new()
	q.subdivide_width = SUBDIV_W
	q.subdivide_depth = SUBDIV_H
	mesh = q
	material_override = _mat

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

## 纸片演出参数（world.gd 每帧驱动）：走路飘动幅度 / 待机呼吸卷曲，单位米。
func set_paper_motion(flutter_amp: float, curl: float) -> void:
	_mat.set_shader_parameter("flutter_amp", flutter_amp)
	_mat.set_shader_parameter("curl", curl)

## 从静态立绘切到 idle 动画图集。meta 为服务端 SpriteSheetMeta（cols/rows/frameCount/fps/cellW/cellH）。
## world_height：期望世界高度（米），与切换前静态立绘保持一致，观感不跳。phase：相位偏移（秒）。
func play_idle(atlas: Texture2D, meta: Dictionary, world_height: float, phase := 0.0) -> void:
	var ch := float(meta.get("cellH", 0))
	var cw := float(meta.get("cellW", 0))
	if atlas == null or ch <= 0.0 or cw <= 0.0:
		return
	_sheet = meta
	_mat.set_shader_parameter("sheet_cols", int(meta.get("cols", 1)))
	_mat.set_shader_parameter("sheet_rows", int(meta.get("rows", 1)))
	_mat.set_shader_parameter("sheet_frames", int(meta.get("frameCount", 0)))
	_mat.set_shader_parameter("sheet_fps", float(meta.get("fps", 8)))
	_mat.set_shader_parameter("sheet_phase", phase)
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
