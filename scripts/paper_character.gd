class_name PaperCharacter
extends Sprite3D
## HD-2D 纸片角色：3D 世界里的 2D 立绘。不用 billboard——而是面向相机方向 +
## 固定小倾角（织梦岛/纸片马里奥式：站在地上、面向玩家，仍有立体感）。
## 倾角由 world.gd 随相机角度设置（rotation.x）。相机方位固定在 +Z，故默认朝向即正对相机。

var char_name: String = "小伙伴"

func setup(tex: Texture2D, color: Color, cname: String) -> void:
	texture = tex
	modulate = color
	char_name = cname
	billboard = BaseMaterial3D.BILLBOARD_DISABLED
	pixel_size = 0.02
	shaded = false
	double_sided = true
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	# 把锚点移到脚底：纹理高 160 → 上移半高，使底边落在节点原点（绕脚底倾斜）
	offset = Vector2(0.0, 80.0)
