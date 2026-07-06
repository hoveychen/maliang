class_name UiAssets
extends RefCounted
## AIGC UI 素材加载器：assets/ui/ 下的贴纸图标/插画统一从这里取，替代 emoji 文字占位。
## 素材由 server/tools/gen_ui_assets.mjs 生成（贴纸=透明底白边黑框，插画=全幅水彩），
## 人工挑选裁剪后落盘；命名与 server/tools/ui_assets.manifest.json 的 id 一致。

const DIR := "res://assets/ui"

## 贴纸奖励 id → 图标（与 server/src/types.ts STICKERS / world.gd STICKER_ORDER 对齐）。
const STICKER_ICONS := {
	"flower": "st_flower", "apple": "st_apple", "star": "st_star", "shell": "st_shell",
	"ladybug": "st_ladybug", "candy": "st_candy", "clover": "st_clover", "gem": "st_gem",
}

## 情绪 → 图标（world.gd _show_emotion；缺省音符）。
const EMOTION_ICONS := { "happy": "em_happy", "think": "em_think", "wave": "em_wave", "sad": "em_sad" }

static func tex(name: String) -> Texture2D:
	var path := "%s/%s.png" % [DIR, name]
	if not ResourceLoader.exists(path):
		push_warning("UiAssets: 缺素材 %s" % path)
		return null
	return load(path)

static func sticker_tex(sticker_id: String) -> Texture2D:
	return tex(String(STICKER_ICONS.get(sticker_id, "st_star")))

static func emotion_tex(emotion: String) -> Texture2D:
	return tex(String(EMOTION_ICONS.get(emotion, "ic_note")))

## 图标 TextureRect：等比缩放居中，锁正方形外框。
static func icon_rect(name: String, side: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex(name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(side, side)
	r.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return r

## 图标按钮：透明底纯图标（贴纸自带白边黑框，无需再画底色）。
static func icon_button(name: String, side: float) -> Button:
	var b := Button.new()
	b.flat = true
	b.icon = tex(name)
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.custom_minimum_size = Vector2(side, side)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b

## 头顶气泡 Sprite3D（billboard，替代 Label3D emoji）：height_m 为渲染高度（米）。
static func bubble_sprite(name: String, height_m: float) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = tex(name)
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.shaded = false
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	if s.texture != null:
		s.pixel_size = height_m / float(s.texture.get_height())
	s.visible = false
	return s
