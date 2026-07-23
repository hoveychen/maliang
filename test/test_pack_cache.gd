extends SceneTree
## 内容包(.pck)客户端预热器单元测试（content-pck-distribution P3）。
## 直接测纯原语，不触真网：manifest/缓存路径拼接、fetch_pack 缓存命中免下载、PackMounter 缺文件不崩。
## 真下载 + load_resource_pack 挂载的整合路径由 game-pilot 眼验（缺包→下载→挂载→prop 出现闭环）。
## 运行: godot --headless --path . --script res://test/test_pack_cache.gd

var _fails := 0

func _initialize() -> void:
	# --- 纯函数：manifest 路径（含 uri_encode）---
	_check("manifest_path 基本", Api.manifest_path("w1", "village"), "/worlds/w1/scenes/village/manifest")
	_check("manifest_path 编码特殊字符", Api.manifest_path("w a", "s/b"), "/worlds/w%20a/scenes/s%2Fb/manifest")

	# --- 纯函数：pack 缓存路径 ---
	_check("pack_cache_path", Api.pack_cache_path("deadbeef"), "user://packs/deadbeef.pck")

	# --- fetch_pack：缓存命中免下载（预写文件 → 返回本地路径，不发网络）---
	var api := Api.new()
	get_root().add_child(api) # fetch_pack 会 add_child(HTTPRequest)，需在树内
	var h := "unittest_pack_%d" % Time.get_ticks_usec()
	var path := Api.pack_cache_path(h)
	if not DirAccess.dir_exists_absolute(Api.PACKS_DIR):
		DirAccess.make_dir_recursive_absolute(Api.PACKS_DIR)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([1, 2, 3, 4]))
	f.close()
	var got: String = await api.fetch_pack(h)
	_check("fetch_pack 缓存命中返回本地路径", got, path)

	# --- fetch_pack：空 hash → 空串 ---
	var empty: String = await api.fetch_pack("")
	_check("fetch_pack 空 hash 返回空串", empty, "")

	# 清理
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	api.queue_free()

	# --- PackMounter：缺文件/空 hash 不崩、返回 false（优雅缺失）---
	var pm: Node = load("res://scripts/pack_mounter.gd").new()
	_check("PackMounter 未挂载默认 false", pm.is_mounted("nope_%d" % Time.get_ticks_usec()), false)
	_check("PackMounter 缺文件 ensure_mounted 返回 false", pm.ensure_mounted("missing_%d" % Time.get_ticks_usec()), false)
	_check("PackMounter 空 hash ensure_mounted 返回 false", pm.ensure_mounted(""), false)

	# --- PackMounter 按名挂载记账（content-pck 守卫的地基：守卫按包名判「能否安全 load」）---
	# 缺文件挂载失败 → 不记名（离线时守卫仍应回 false，不误放行去碰 ResourceLoader 污染缓存）。
	pm.ensure_mounted("missing_named_%d" % Time.get_ticks_usec(), "ghost_pack")
	_check("挂载失败不记名 → is_pack_mounted false", pm.is_pack_mounted("ghost_pack"), false)
	# note_mounted_name：把包名记进账（hash 已挂但当时没带名字的补记路径）。
	pm.note_mounted_name("toyroom")
	_check("note_mounted_name 后 is_pack_mounted true", pm.is_pack_mounted("toyroom"), true)
	_check("未记名的包 is_pack_mounted false", pm.is_pack_mounted("winter"), false)
	# 空名 no-op（不污染名字账；is_pack_mounted("") 恒 false）。
	pm.note_mounted_name("")
	_check("空名 note_mounted_name no-op", pm.is_pack_mounted(""), false)
	# pack_available：编辑器/headless（从项目目录跑，本测试即是）恒 true——保证 headless 回测不被挂载守卫误跳。
	_check("headless 下 pack_available 恒 true（未挂的包也是）", pm.pack_available("winter"), true)
	pm.free()

	# --- PackRegistry.pack_of：渲染键 → 所属包名（守卫据此分辨 base 主包 vs 内容包）---
	_check("pack_of 未注册键返回空", PackRegistry.pack_of("__no_such_key__"), "")
	var keys := PackRegistry.all_keys()
	if keys.is_empty():
		printerr("  FAIL pack_of 有注册键: all_keys 为空（index.json 未载入?）")
		_fails += 1
	else:
		var sample := String(keys[0])
		if String(PackRegistry.pack_of(sample)).is_empty():
			printerr("  FAIL pack_of 已注册键 %s 应返回非空 pack 名" % sample)
			_fails += 1

	print("test_pack_cache: %d fail(s)" % _fails)
	quit(_fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		return
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	_fails += 1
