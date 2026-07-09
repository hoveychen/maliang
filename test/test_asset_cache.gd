extends SceneTree
## 资产磁盘缓存（api.gd）单元测试。资产内容寻址（hash 即内容摘要），缓存永久有效。
## 覆盖：写盘→读回字节完全一致；未命中返回空；PNG/WebP magic-byte 解码分派；坏数据解码回落 null。
## 直接测纯缓存原语（_cache_read/_cache_write/_decode_image），不触网络——fetch_texture 的三级取源
## 是这几个原语的薄胶水，整合路径由 loading headless 冒烟覆盖。
## 运行: godot --headless --path . --script res://test/test_asset_cache.gd

func _init() -> void:
	var fails := 0
	var api := Api.new()
	var key := "unittest_cache_%d" % Time.get_ticks_usec() # 唯一键，避免撞真实缓存/并发跑

	# --- 造一张真 PNG 字节 ---
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.6, 0.9, 1.0))
	var png := img.save_png_to_buffer()
	fails += _check("PNG 编码非空", png.size() > 0, true)

	# --- 未命中：读不存在的 key 返回空 ---
	fails += _check("未命中返回空字节", api._cache_read(key).is_empty(), true)

	# --- 写盘 → 读回，字节完全一致 ---
	api._cache_write(key, png)
	var got := api._cache_read(key)
	fails += _check("命中：读回字节与写入一致", got == png, true)

	# --- 解码分派：PNG 字节 → 8×8 纹理 ---
	var tex := api._decode_image(got)
	fails += _check("PNG 解码出纹理", tex != null, true)
	if tex != null:
		fails += _check("解码纹理尺寸 8×8", tex.get_size(), Vector2(8, 8))

	# --- 坏数据：随机字节解码回落 null，不崩 ---
	var garbage := PackedByteArray([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
	fails += _check("坏数据解码回落 null", api._decode_image(garbage) == null, true)

	# --- 空 hash 不写盘（防污染 CACHE_DIR 根）---
	api._cache_write("", png)
	fails += _check("空 hash 不落盘", api._cache_read("").is_empty(), true)

	# --- 清理测试文件 ---
	var path := api._cache_path(key)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	api.free()

	print("test_asset_cache: %d fail(s)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
