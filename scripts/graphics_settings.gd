class_name GraphicsSettings
extends RefCounted
## 画质开关的键定义 + 默认值 + 持久化（user://profile.json 的 graphics 子字典，仿 play_budget）。
## 这里只管「数据」；「应用到场景」的幂等逻辑在 world.gd（_apply_graphics_key），因为要碰
## 太阳灯 / chunk_manager / 环境节点。默认全开 = 高画质档；移动端 AdaptiveQuality 会自动
## 降档，那是自适应的事，用户在设置页里的选择是显式 override（启动时在自适应定档之后应用）。
##
## 6 个键（对应设置页 6 个 toggle）：
##   actor_shadows  角色实时定向阴影（关则回脚下暗斑）
##   ground_shadows 地面斜阳椭圆贴片影（树/灌木/建筑）
##   hi_res         高清渲染（3D 原生分辨率 vs 0.7 降采样）
##   fog            深度雾
##   outline        SDF 物件描边 pass
##   prop_anim      会动的 SDF 物件（显/隐）

const KEYS := ["actor_shadows", "ground_shadows", "hi_res", "fog", "outline", "prop_anim"]
const DEFAULTS := {
	"actor_shadows": true,
	"ground_shadows": true,
	"hi_res": true,
	"fog": true,
	"outline": true,
	"prop_anim": true,
}

## 读全部画质开关（缺项/损坏取默认），返回 {key: bool}，只含 KEYS。
static func load_all() -> Dictionary:
	var g: Variant = PlayerProfile.load_profile().get("graphics", {})
	var src: Dictionary = g if typeof(g) == TYPE_DICTIONARY else {}
	var out := {}
	for k in KEYS:
		out[k] = bool(src.get(k, DEFAULTS[k]))
	return out

## 写全部画质开关（只落 KEYS 里的、规整成 bool），并入档案其余字段一起存。
static func save_all(settings: Dictionary) -> void:
	var p := PlayerProfile.load_profile()
	var g := {}
	for k in KEYS:
		g[k] = bool(settings.get(k, DEFAULTS[k]))
	p["graphics"] = g
	PlayerProfile.save_profile(p)

## 用户是否显式存过画质档：决定启动要不要 override 自适应定档（没存过就跟随 AdaptiveQuality）。
static func has_saved() -> bool:
	return PlayerProfile.load_profile().has("graphics")
