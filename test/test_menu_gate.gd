extends SceneTree
## 菜单入口分流：只有「建过真角色」(name 或 sprite_asset 非空) 才直接进世界，
## 否则走童话书 onboarding。profile.json 是共享袋子——device_id / graphics / play_budget /
## intro_seen 都往里写，任一非创建路径落盘都会让文件存在。历史 bug:menu 用 exists()(文件是否
## 存在) 当「已建角色」信号，于是画质档/设备档一落盘就永久跳过创建，小朋友被无档丢进世界，
## 后台留下一堆「无立绘」空玩家。此测试锁死：设备档-only 的 profile 必须回 onboarding。
## 运行: godot --headless --path . --script res://test/test_menu_gate.gd

const Menu := preload("res://scripts/menu.gd")

func _init() -> void:
	var fails := 0

	# 无档案 → onboarding
	PlayerProfile.clear()
	fails += _check("无档 → onboarding", Menu.target_scene(), "res://onboarding.tscn")

	# 只有设备档/画质档、没建角色（无 name 无 sprite_asset）→ 仍走 onboarding（核心回归）
	PlayerProfile.save_profile({
		"device_id": "abcd1234",
		"graphics": { "levels": {}, "source": "bench" },
		"player_id": "deadbeef",
	})
	fails += _check("设备档-only → onboarding", Menu.target_scene(), "res://onboarding.tscn")
	fails += _check("has_character 设备档-only=false", PlayerProfile.has_character(), false)

	# 有名字 → 进世界
	PlayerProfile.save_profile({ "name": "朵朵", "device_id": "abcd1234" })
	fails += _check("有名字 → main", Menu.target_scene(), "res://main.tscn")
	fails += _check("has_character 有名字=true", PlayerProfile.has_character(), true)

	# 只有立绘、暂无名字 → 也算真角色 → 进世界
	PlayerProfile.save_profile({ "sprite_asset": "cafe", "device_id": "abcd1234" })
	fails += _check("有立绘 → main", Menu.target_scene(), "res://main.tscn")
	fails += _check("has_character 有立绘=true", PlayerProfile.has_character(), true)

	PlayerProfile.clear()
	if fails == 0:
		print("menu_gate tests PASS")
	else:
		printerr("menu_gate tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
