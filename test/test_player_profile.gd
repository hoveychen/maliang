extends SceneTree
## PlayerProfile 存取：save/load 往返、缺失返回空、损坏返回空、clear 删除。
## 运行: godot --headless --path . --script res://test/test_player_profile.gd

func _init() -> void:
	var fails := 0

	PlayerProfile.clear()
	fails += _check("missing -> not exists", PlayerProfile.exists(), false)
	fails += _check("missing -> empty", PlayerProfile.load_profile().is_empty(), true)

	var p := {
		"name": "朵朵", "nickname": "朵朵", "gender": "girl", "color": "粉色",
		"likes": "小兔子", "interest": "画画", "intro": "我叫朵朵",
		"sprite_asset": "abc123", "created_at": "2026-07-03T00:00:00",
	}
	PlayerProfile.save_profile(p)
	fails += _check("saved -> exists", PlayerProfile.exists(), true)
	var got := PlayerProfile.load_profile()
	fails += _check("roundtrip name", got.get("name", ""), "朵朵")
	fails += _check("roundtrip sprite", got.get("sprite_asset", ""), "abc123")

	# 损坏文件：非 JSON → 空字典
	var f := FileAccess.open(PlayerProfile.PATH, FileAccess.WRITE)
	f.store_string("not json {{{")
	f = null
	fails += _check("corrupt -> empty", PlayerProfile.load_profile().is_empty(), true)

	PlayerProfile.clear()
	fails += _check("clear -> gone", PlayerProfile.exists(), false)

	# 撕裂写恢复：save_profile 曾是截断式非原子写——并发读改写（游戏+巡检/测试同时在跑）里
	# 读者撞上半截 JSON → load 得 {} → 下一次 read-modify-write 把 name/sprite 整档冲掉
	# （开发机档案被抹三次的根因）。契约：主档存在但坏 → 从上一版备份恢复，绝不让 {} 流出去。
	PlayerProfile.clear()
	PlayerProfile.save_profile({"name": "朵朵", "sprite_asset": "abc"})
	PlayerProfile.save_profile({"name": "朵朵", "sprite_asset": "abc", "intro_seen": true})
	var fc := FileAccess.open(PlayerProfile.PATH, FileAccess.WRITE)
	fc.store_string('{"name": "朵')  # 模拟撕裂：半个 JSON
	fc = null
	fails += _check("撕裂主档→从备份恢复 name", String(PlayerProfile.load_profile().get("name", "")), "朵朵")
	PlayerProfile.save_play_budget(1.0, 0.0, 0.0)
	fails += _check("损坏后一次保存不抹 name", String(PlayerProfile.load_profile().get("name", "")), "朵朵")
	var pb_after: Variant = PlayerProfile.load_profile().get("play_budget", {})
	fails += _check("损坏后保存带上 budget", float((pb_after as Dictionary).get("used_sec", 0.0)), 1.0)
	# clear 必须连备份一起删：否则删档后 load 从 .bak 还魂
	PlayerProfile.clear()
	fails += _check("clear 后无还魂", PlayerProfile.load_profile().is_empty(), true)

	# ensure_player_id：首次生成并写盘，二次调用稳定不变（设备端稳定 UUID）
	PlayerProfile.clear()
	var pid1 := PlayerProfile.ensure_player_id()
	fails += _check("ensure_player_id 非空", pid1.is_empty(), false)
	fails += _check("ensure_player_id 写盘可见", String(PlayerProfile.load_profile().get("player_id", "")), pid1)
	fails += _check("ensure_player_id 幂等稳定", PlayerProfile.ensure_player_id(), pid1)

	# upload_dict：键名对齐 server types.Player 驼峰（sprite_asset → spriteAsset，无下划线键）
	PlayerProfile.save_profile({
		"name": "朵朵", "nickname": "多多", "gender": "girl", "color": "粉色",
		"sprite_asset": "h9", "created_at": "2026-07-08T00:00:00",
	})
	var up := PlayerProfile.upload_dict()
	fails += _check("upload_dict spriteAsset 驼峰", up.get("spriteAsset", ""), "h9")
	fails += _check("upload_dict nickname", up.get("nickname", ""), "多多")
	fails += _check("upload_dict 无下划线键", up.has("sprite_asset"), false)

	# device_dict：activity 记录用的设备块，键名对齐 server DeviceReport；机型/系统非空、分辨率成串
	fails += _check("upload_dict 带 device 块", up.has("device"), true)
	var dev: Dictionary = up.get("device", {})
	fails += _check("device 有 os", String(dev.get("os", "")).is_empty(), false)
	fails += _check("device 有 model 键", dev.has("model"), true)
	fails += _check("device screen 成 WxH 串", String(dev.get("screen", "")).contains("x"), true)
	fails += _check("device godot 版本非空", String(dev.get("godot", "")).is_empty(), false)
	# device 块不含任何可定位/隐私字段（IP 由服务端从连接层取，客户端绝不上报）
	fails += _check("device 不含 ip", dev.has("ip"), false)
	PlayerProfile.clear()

	if fails == 0:
		print("player_profile tests PASS")
	else:
		printerr("player_profile tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
