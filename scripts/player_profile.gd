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
