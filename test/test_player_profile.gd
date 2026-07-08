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
