class_name GraphicsSettings
extends RefCounted
## 画质旋钮的键定义 + 级数 + 默认值 + 文案 + 持久化（user://profile.json 的 graphics 子字典）。
## 这里只管「数据」；「应用到场景」的幂等逻辑在 world.gd（_apply_graphics_key），因为要碰
## 太阳灯 / chunk_manager / 环境节点。
##
## 分级模型：每个旋钮是一个 level（0 = 最省，LEVELS[key] - 1 = 最高画质）。开/关型旋钮是
## 2 级的特例（0 = 关，1 = 开）；hi_res 有 3 级（0.6 / 0.7 / 原生），最弱的机器需要 0.6。
## 默认 = 全部最高画质；真正的定档由 benchmark（贪心求解）或 backend（按 GPU 下发）给出。
##
## 来源（source）决定谁能覆盖：
##   user    — 用户在设置页手动改过。永不被 backend/benchmark 覆盖（除非用户点「恢复自动」）。
##   bench   — 本机 benchmark 跑出来的最优集。
##   backend — 后端按 GPU 下发的众包结果。
## 无 graphics 键 = 从没定过档（新机器，待查 backend / 跑 benchmark）。

const PROFILE_KEY := "graphics"

## 移动端全局帧率上限（menu 入口设置，跨场景持久）。水彩世界大部分画面静止，60fps 满速
## 重绘是长期运行发热主因；30fps 单帧功耗近乎减半、观感损失极小。低处理器模式无效——
## 仙子/天空/水面永远在动，达不到「无重绘」条件，只能 cap。benchmark 也以此为达标线。
const FPS_CAP := 30
## 达标帧时：跑稳 30fps 即单帧 ≤ 33.3ms。benchmark 贪心的终止条件（看 p95，不是均值）。
const TARGET_FRAME_MS := 33.3

const KEYS := [
	"actor_shadows", "ground_shadows", "hi_res", "fog", "outline",
	"prop_anim", "prop_detail", "terrain_detail", "xray",
]

## 每个键的级数（≥ 2）。level 取值域 [0, LEVELS[key] - 1]。
const LEVELS := {
	"actor_shadows": 2,
	"ground_shadows": 2,
	"hi_res": 3,
	"fog": 2,
	"outline": 2,
	"prop_anim": 2,
	"prop_detail": 2,
	"terrain_detail": 2,
	"xray": 2,
}

## 默认 = 各键最高档（= LEVELS[key] - 1）。
const DEFAULTS := {
	"actor_shadows": 1,
	"ground_shadows": 1,
	"hi_res": 2,
	"fog": 1,
	"outline": 1,
	"prop_anim": 1,
	"prop_detail": 1,
	"terrain_detail": 1,
	"xray": 1,
}

## 设置页每行的标题。
const LABELS := {
	"actor_shadows": "角色阴影",
	"ground_shadows": "地面阴影",
	"hi_res": "画面清晰度",
	"fog": "远景雾",
	"outline": "物件描边",
	"prop_anim": "会动的物件",
	"prop_detail": "物件精细度",
	"terrain_detail": "地面细节",
	"xray": "穿透剪影",
}

## 设置页每行的副标题：说清楚这个旋钮到底控制了什么、调低会看到什么。
const SUBTITLES := {
	"actor_shadows": "角色在阳光下的真实影子。关掉后只剩脚下一团淡淡的暗斑。",
	"ground_shadows": "树、灌木、房子投在地上的斜阳影子。关掉后地面变干净。",
	"hi_res": "画面的渲染精度。越低越省电越流畅，但画面会稍微发糊。",
	"fog": "远处景色的朦胧感。关掉后远山和近处一样清楚。",
	"outline": "物件周围那圈黑边（绘本描边感）。关掉后画风更柔和，每个物件少画一遍。",
	"prop_anim": "会随风摇摆的花草和物件。关掉后它们静止不动。",
	"prop_detail": "物件边缘的锐利程度。调低后边角略微发圆，但省不少算力。",
	"terrain_detail": "小路、崖壁、水面上的第二层纹理。调低后地面纹理更简单。",
	"xray": "角色走到房子后面时仍能看见的半透明剪影。关掉后角色会被挡住。",
}

## 每一级在 UI 上的名字（下标 = level）。2 级旋钮统一「关 / 开」语义。
const LEVEL_NAMES := {
	"actor_shadows": ["关", "开"],
	"ground_shadows": ["关", "开"],
	"hi_res": ["省电", "标准", "高清"],
	"fog": ["关", "开"],
	"outline": ["关", "开"],
	"prop_anim": ["关", "开"],
	"prop_detail": ["粗略", "精细"],
	"terrain_detail": ["简单", "细致"],
	"xray": ["关", "开"],
}

## 该键的最高档 level。
static func max_level(key: String) -> int:
	return int(LEVELS.get(key, 2)) - 1

## 把任意输入夹进 [0, max_level]。
static func clamp_level(key: String, lv: int) -> int:
	return clampi(lv, 0, max_level(key))

## 全部最高档（benchmark 贪心的起点、「恢复自动」前的兜底）。
static func all_max() -> Dictionary:
	var out := {}
	for k: String in KEYS:
		out[k] = max_level(k)
	return out

## 读全部画质档（缺项/损坏取默认），返回 {key: int level}，只含 KEYS。
## 兼容旧档：graphics 曾是 {key: bool} 平铺，true → 最高档、false → 0 档。
static func load_all() -> Dictionary:
	var raw := _raw()
	var src: Dictionary = raw.get("levels", {}) if raw.has("levels") else raw
	var out := {}
	for k: String in KEYS:
		var v: Variant = src.get(k, DEFAULTS[k])
		var lv: int = (max_level(k) if bool(v) else 0) if typeof(v) == TYPE_BOOL else int(v)
		out[k] = clamp_level(k, lv)
	return out

## 写全部画质档（只落 KEYS 里的、夹进合法域），并入档案其余字段一起存。
## source 记录谁定的档（见文件头）；meta 是可选附加信息（gpu / bench_version / fps）。
static func save_all(levels: Dictionary, source: String = "user", meta: Dictionary = {}) -> void:
	var lv := {}
	for k: String in KEYS:
		lv[k] = clamp_level(k, int(levels.get(k, DEFAULTS[k])))
	var g := {"levels": lv, "source": source}
	for mk: String in meta:
		g[mk] = meta[mk]
	var p := PlayerProfile.load_profile()
	p[PROFILE_KEY] = g
	PlayerProfile.save_profile(p)

## 是否已经定过档（任何来源）。没定过 = 新机器，该查 backend / 跑 benchmark。
static func has_saved() -> bool:
	return not _raw().is_empty()

## 谁定的档：user / bench / backend；没定过返回空串。
## 旧档（平铺 bool、无 source 键）是用户在设置页手动存的，一律视作 user。
static func source() -> String:
	var raw := _raw()
	if raw.is_empty():
		return ""
	return String(raw.get("source", "user"))

## 用户是否手动接管过：user override 永不被 backend / benchmark 覆盖。
static func is_user_override() -> bool:
	return source() == "user"

## 清掉画质档（设置页「恢复自动」）：下次启动重新查 backend / 跑 benchmark。
static func clear() -> void:
	var p := PlayerProfile.load_profile()
	if p.erase(PROFILE_KEY):
		PlayerProfile.save_profile(p)

## profile 里的 graphics 原始子字典（新格式 {levels, source, ...} 或旧格式平铺 bool）。
static func _raw() -> Dictionary:
	var g: Variant = PlayerProfile.load_profile().get(PROFILE_KEY, {})
	return g if typeof(g) == TYPE_DICTIONARY else {}
