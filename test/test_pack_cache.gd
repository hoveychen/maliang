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
	pm.free()

	print("test_pack_cache: %d fail(s)" % _fails)
	quit(_fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		return
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	_fails += 1
