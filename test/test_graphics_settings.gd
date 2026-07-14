extends SceneTree
## GraphicsSettings 数据层（分级模型）：默认全最高档、存取往返、缺项取默认、越界夹取、
## 旧 bool 档迁移、source 语义（user override 与 bench/backend 之分）、clear。
## 备份并恢复真实档案（不污染开发机 user://profile.json）。
## 运行: godot --headless --path . --script res://test/test_graphics_settings.gd

func _init() -> void:
	var fails := 0
	var backup := PlayerProfile.load_profile()  # 备份，测完恢复

	PlayerProfile.clear()
	fails += _check("无存档 has_saved=false", GraphicsSettings.has_saved(), false)
	fails += _check("无存档 source 空", GraphicsSettings.source(), "")
	fails += _check("无存档 is_user_override=false", GraphicsSettings.is_user_override(), false)
	var d := GraphicsSettings.load_all()
	fails += _check("默认键数=全键数", d.size(), GraphicsSettings.all_keys().size())
	var all_max := true
	for k: String in GraphicsSettings.KEYS:
		if int(d[k]) != GraphicsSettings.max_level(k):
			all_max = false
	fails += _check("性能键默认全最高档", all_max, true)
	fails += _check("hi_res 三级", GraphicsSettings.LEVELS["hi_res"], 3)
	fails += _check("hi_res 最高档=2", GraphicsSettings.max_level("hi_res"), 2)
	fails += _check("每键都有 subtitle", GraphicsSettings.SUBTITLES.size(), GraphicsSettings.all_keys().size())
	fails += _check("每键的级名数=级数", _level_names_match(), true)

	# 样式键（papercraft）：默认关、不进 benchmark 贪心的键集/起点
	fails += _check("样式键默认关", d["papercraft"], 0)
	fails += _check("样式键不在 KEYS", "papercraft" in GraphicsSettings.KEYS, false)
	fails += _check("样式键在 all_keys", "papercraft" in GraphicsSettings.all_keys(), true)
	fails += _check("all_max 不含样式键", GraphicsSettings.all_max().has("papercraft"), false)

	# 越界夹取
	fails += _check("clamp 上越界", GraphicsSettings.clamp_level("hi_res", 9), 2)
	fails += _check("clamp 下越界", GraphicsSettings.clamp_level("fog", -3), 0)

	# 存取往返：hi_res 落到最省档、关掉两项
	var want := GraphicsSettings.all_max()
	want["hi_res"] = 0
	want["actor_shadows"] = 0
	want["xray"] = 0
	GraphicsSettings.save_all(want, "bench", {"gpu": "Mali-G57"})
	fails += _check("存过 has_saved=true", GraphicsSettings.has_saved(), true)
	var r := GraphicsSettings.load_all()
	fails += _check("往返 hi_res=0", r["hi_res"], 0)
	fails += _check("往返 actor_shadows=0", r["actor_shadows"], 0)
	fails += _check("往返 xray=0", r["xray"], 0)
	fails += _check("未动项仍最高 outline=1", r["outline"], 1)
	fails += _check("source=bench", GraphicsSettings.source(), "bench")
	fails += _check("bench 档不是 user override", GraphicsSettings.is_user_override(), false)
	var meta: Dictionary = PlayerProfile.load_profile()["graphics"]
	fails += _check("meta 里带 gpu", String(meta.get("gpu", "")), "Mali-G57")

	# 越界值写进去也被夹住
	GraphicsSettings.save_all({"hi_res": 99, "fog": -1}, "backend")
	var r2 := GraphicsSettings.load_all()
	fails += _check("存越界被夹 hi_res=2", r2["hi_res"], 2)
	fails += _check("存越界被夹 fog=0", r2["fog"], 0)
	fails += _check("缺项补默认 outline=1", r2["outline"], 1)
	fails += _check("source=backend 不是 user", GraphicsSettings.is_user_override(), false)

	# 样式键存取往返 + 保留语义：用户开了纸艺风后，benchmark 只传性能键重定档不得冲掉
	var style := GraphicsSettings.load_all()
	style["papercraft"] = 1
	GraphicsSettings.save_all(style, "user")
	fails += _check("样式键往返 papercraft=1", GraphicsSettings.load_all()["papercraft"], 1)
	GraphicsSettings.save_all(GraphicsSettings.all_max(), "bench", {"gpu": "Mali-G76"})
	fails += _check("bench 重定档保留画风", GraphicsSettings.load_all()["papercraft"], 1)
	fails += _check("bench 重定档性能键生效", GraphicsSettings.load_all()["hi_res"], 2)

	# 旧档迁移：graphics 曾是平铺 bool，true→最高档 false→0；且无 source 键 → 视作 user
	PlayerProfile.save_profile({"graphics": {
		"actor_shadows": false, "ground_shadows": true, "hi_res": false,
		"fog": true, "outline": true, "prop_anim": true,
	}})
	var old := GraphicsSettings.load_all()
	fails += _check("旧档 false→0", old["actor_shadows"], 0)
	fails += _check("旧档 true→最高", old["ground_shadows"], 1)
	fails += _check("旧档 hi_res false→0（最省）", old["hi_res"], 0)
	fails += _check("旧档没有的新键取默认 xray=1", old["xray"], 1)
	fails += _check("旧档视作 user override", GraphicsSettings.is_user_override(), true)

	# clear：恢复自动 → 回到未定档
	GraphicsSettings.clear()
	fails += _check("clear 后 has_saved=false", GraphicsSettings.has_saved(), false)
	fails += _check("clear 后回默认全最高", GraphicsSettings.load_all()["hi_res"], 2)

	# 不污染档案其余字段：graphics 与 name 共存
	PlayerProfile.save_profile({"name": "朵朵"})
	GraphicsSettings.save_all(GraphicsSettings.all_max(), "user")
	fails += _check("graphics 不冲掉 name", String(PlayerProfile.load_profile().get("name", "")), "朵朵")
	fails += _check("手动存 = user override", GraphicsSettings.is_user_override(), true)
	GraphicsSettings.clear()
	fails += _check("clear 不冲掉 name", String(PlayerProfile.load_profile().get("name", "")), "朵朵")

	# 恢复
	if backup.is_empty():
		PlayerProfile.clear()
	else:
		PlayerProfile.save_profile(backup)

	if fails == 0:
		print("graphics_settings tests PASS")
	else:
		printerr("graphics_settings tests FAILED: %d" % fails)
	quit(fails)

func _level_names_match() -> bool:
	for k: String in GraphicsSettings.all_keys():
		var names: Array = GraphicsSettings.LEVEL_NAMES[k]
		if names.size() != int(GraphicsSettings.LEVELS[k]):
			return false
	return true

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
