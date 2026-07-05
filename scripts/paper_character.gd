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

## 纸片演出参数（world.gd 每帧驱动）：走路飘动幅度 / 待机呼吸卷曲，单位米。
func set_paper_motion(flutter_amp: float, curl: float) -> void:
	_mat.set_shader_parameter("flutter_amp", flutter_amp)
	_mat.set_shader_parameter("curl", curl)

func _refresh_geometry() -> void:
	if texture == null:
		return
	var w := float(texture.get_width()) * pixel_size
	var h := float(texture.get_height()) * pixel_size
	var q := mesh as QuadMesh
	q.size = Vector2(w, h)
	q.center_offset = Vector3(offset.x * pixel_size, offset.y * pixel_size, 0.0)
	_mat.set_shader_parameter("quad_size", Vector2(w, h))
