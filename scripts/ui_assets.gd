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
## jump/spin/nod/heart 是玩家互动表情盘补的动作贴纸（与 em_* 同一 manifest 管线画风）。
const EMOTION_ICONS := {
	"happy": "em_happy", "think": "em_think", "wave": "em_wave", "sad": "em_sad",
	"jump": "em_jump", "spin": "em_spin", "nod": "em_nod", "heart": "em_heart",
}

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

## —— Pokopia 式奶油卡片风（HUD 统一）：奶油白圆角 + 暖沙描边 + 柔和投影 ——
const CARD_BG := Color(1.0, 0.976, 0.93)        ## 奶油白底
const CARD_BORDER := Color(0.92, 0.85, 0.70)    ## 暖沙描边
const CARD_TEXT := Color(0.42, 0.30, 0.18)      ## 暖棕文字（奶油底上可读）
const CARD_ACCENT := Color(1.0, 0.89, 0.62)     ## 选中/按下的暖黄

static func card_style(radius := 26.0, alpha := 0.97) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(CARD_BG.r, CARD_BG.g, CARD_BG.b, alpha)
	s.set_corner_radius_all(int(radius))
	s.set_border_width_all(3)
	s.border_color = CARD_BORDER
	s.shadow_color = Color(0.35, 0.24, 0.10, 0.28)
	s.shadow_size = 12
	s.shadow_offset = Vector2(0.0, 5.0)
	return s

## 把按钮统一成奶油圆角卡片（normal/hover 奶油白、按下/选中暖黄；toggle 复用 pressed）。
static func style_card_button(b: Button, radius := 20.0) -> void:
	var normal := card_style(radius, 0.95)
	normal.shadow_size = 6
	normal.shadow_offset = Vector2(0.0, 3.0)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(1.0, 0.95, 0.85, 0.97)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = CARD_ACCENT
	pressed.border_color = Color(0.87, 0.72, 0.45)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(state, CARD_TEXT)

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
