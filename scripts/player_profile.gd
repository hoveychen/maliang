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

## 可玩时间预算持久化（跨会话强制冷却用）：
##   used_sec       — 本轮已累计的活跃游玩秒数（到 45min 触发冷却）
##   cooldown_until — 冷却结束的 unix 时间戳（>0 且 now< 它 = 冷却中，跨会话/关 App 照样倒计时）
##   last_active    — 上次活跃的 unix 时间戳（离开够久＝自然休息，下次进世界刷新预算）
static func load_play_budget() -> Dictionary:
	var p := load_profile()
	var pb: Variant = p.get("play_budget", {})
	if typeof(pb) != TYPE_DICTIONARY:
		return { "used_sec": 0.0, "cooldown_until": 0.0, "last_active": 0.0 }
	return {
		"used_sec": float(pb.get("used_sec", 0.0)),
		"cooldown_until": float(pb.get("cooldown_until", 0.0)),
		"last_active": float(pb.get("last_active", 0.0)),
	}

static func save_play_budget(used_sec: float, cooldown_until: float, last_active: float) -> void:
	var p := load_profile()
	p["play_budget"] = { "used_sec": used_sec, "cooldown_until": cooldown_until, "last_active": last_active }
	save_profile(p)

## 「建造小世界」前置演出是否已看过（首次进世界的教学段据此只演一次）。
## 存本机档案；缺失/离线（无档案）视为未看过 → 首启进 intro。见 world._need_intro。
static func intro_seen() -> bool:
	return bool(load_profile().get("intro_seen", false))

## 标记 intro 已看过（转正后调用）。档案不存在则新建只含此标志的档案（离线首启也能记住）。
static func mark_intro_seen() -> void:
	var p := load_profile()
	p["intro_seen"] = true
	save_profile(p)

## 确保档案里有稳定玩家 id：设备端「开始新游戏」时生成的 UUID（面向未来 MMO / QR 换机迁移）。
## 首次调用生成并写盘；已有则原样返回。无鉴权——这个 UUID 就是玩家唯一身份。
static func ensure_player_id() -> String:
	var p := load_profile()
	var pid := String(p.get("player_id", ""))
	if pid.is_empty():
		pid = Crypto.new().generate_random_bytes(16).hex_encode()
		p["player_id"] = pid
		save_profile(p)
	return pid

## 上报给服务端 world_info 的玩家档案子集（首见建档用；键名对齐 server types.Player 的驼峰口径）。
static func upload_dict() -> Dictionary:
	var p := load_profile()
	return {
		"name": String(p.get("name", "")),
		"nickname": String(p.get("nickname", "")),
		"gender": String(p.get("gender", "")),
		"color": String(p.get("color", "")),
		"spriteAsset": String(p.get("sprite_asset", "")),
		"createdAt": String(p.get("created_at", "")),
		"device": device_dict(), # activity 记录：机型/系统/分辨率（IP/UA 服务端另补）
	}

## 设备信息块（world_info.profile.device）：给后台 activity 记录看"用什么设备来玩的"。
## 只报能稳定拿到的静态信息，不含任何可定位/隐私字段（IP 由服务端从连接层取）。
static func device_dict() -> Dictionary:
	var scr := DisplayServer.window_get_size()
	var v := Engine.get_version_info()
	return {
		"model": OS.get_model_name(),   # 真机型号（桌面多为 "GenericDevice"）
		"os": OS.get_name(),            # Android / macOS / Windows / Linux
		"osVersion": OS.get_version(),  # 系统版本串
		"screen": "%dx%d" % [scr.x, scr.y],
		"godot": "%d.%d.%d" % [v.get("major", 0), v.get("minor", 0), v.get("patch", 0)],
	}
