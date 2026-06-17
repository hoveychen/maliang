class_name PaperCharacter
extends Sprite3D
## HD-2D 纸片角色：3D 世界里的 2D 立绘，绕 Y 轴朝向相机。

var char_name: String = "小伙伴"

func setup(tex: Texture2D, color: Color, cname: String) -> void:
	texture = tex
	modulate = color
	char_name = cname
	billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	pixel_size = 0.02
	shaded = false
	double_sided = true
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	# 把锚点移到脚底：纹理高 160 → 上移半高，使底边落在节点原点
	offset = Vector2(0.0, 80.0)
