extends SceneTree
## GraphicsSettings 数据层：默认全开、存取往返、缺项取默认、has_saved 判定。
## 备份并恢复真实档案（不污染开发机 user://profile.json）。
## 运行: godot --headless --path . --script res://test/test_graphics_settings.gd

func _init() -> void:
	var fails := 0
	var backup := PlayerProfile.load_profile()  # 备份，测完恢复

	PlayerProfile.clear()
	fails += _check("无存档 has_saved=false", GraphicsSettings.has_saved(), false)
	var d := GraphicsSettings.load_all()
	fails += _check("默认键数=6", d.size(), 6)
	var all_on := true
	for k in GraphicsSettings.KEYS:
		if not bool(d.get(k, false)):
			all_on = false
	fails += _check("默认全开", all_on, true)

	# 存取往返：关掉两项
	GraphicsSettings.save_all({
		"actor_shadows": false, "ground_shadows": true, "hi_res": false,
		"fog": true, "outline": true, "prop_anim": true,
	})
	fails += _check("存过 has_saved=true", GraphicsSettings.has_saved(), true)
	var r := GraphicsSettings.load_all()
	fails += _check("往返 actor_shadows=false", r["actor_shadows"], false)
	fails += _check("往返 hi_res=false", r["hi_res"], false)
	fails += _check("往返 ground_shadows=true", r["ground_shadows"], true)

	# 缺项取默认：只存一个键，其余补默认（true）
	GraphicsSettings.save_all({"fog": false})
	var r2 := GraphicsSettings.load_all()
	fails += _check("缺项补默认 outline=true", r2["outline"], true)
	fails += _check("显式项 fog=false", r2["fog"], false)

	# 不污染档案其余字段：graphics 与 name 共存
	PlayerProfile.save_profile({"name": "朵朵"})
	GraphicsSettings.save_all(GraphicsSettings.DEFAULTS)
	fails += _check("graphics 不冲掉 name", String(PlayerProfile.load_profile().get("name", "")), "朵朵")

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

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
