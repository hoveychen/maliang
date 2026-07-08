class_name PlayerProfile
extends RefCounted
## 玩家档案（user://profile.json）。onboarding 写入，菜单/世界读取。
## 字段：name(名字) nickname(称呼) gender(boy/girl) color(喜欢的颜色名)
##       likes(喜欢的东西) interest(兴趣) intro(自我介绍原文)
##       sprite_asset(服务端形象资产 hash) created_at(ISO 时间)
## 档案是设备本地的：形象资产内容寻址存服务端，名字等只进本机——不建服务端玩家实体。

const PATH := "user://profile.json"

static func exists() -> bool:
	return FileAccess.file_exists(PATH)

## 读档案；缺失/损坏返回空字典。
static func load_profile() -> Dictionary:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return data

static func save_profile(p: Dictionary) -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("玩家档案写入失败: %s" % PATH)
		return
	f.store_string(JSON.stringify(p, "  "))

static func clear() -> void:
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))

## 档案答案 → 形象描述（onboarding 生成与设置页「换形象」共用，防两处文案漂移；
## 风格/朝向后缀由服务端生图管线统一拼接）。字段缺失时用兜底词，旧档案也能拼。
static func avatar_description(p: Dictionary) -> String:
	var who := "小男孩" if String(p.get("gender", "")) == "boy" else "小女孩"
	return "一个可爱的%s形象，穿着%s的衣服，抱着一只%s玩偶，一看就很喜欢%s" % [
		who, String(p.get("color", "彩色")),
		String(p.get("likes", "小兔子")), String(p.get("interest", "玩耍"))]
