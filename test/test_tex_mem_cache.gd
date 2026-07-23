extends SceneTree
## api.fetch_texture 的 cache_in_mem 开关（角色动画 LOD 的 24fps hi 图集靠它受显存限）。
## 走磁盘缓存命中分支（不触网络）：先把字节写盘，再 fetch_texture 读回解码。
##   cache_in_mem=true  → 解码后进 _tex_mem（永不驱逐，默认行为）
##   cache_in_mem=false → 不进 _tex_mem（hi 图集走这条，跌出最近 N 丢引用即回收显存）
## 运行: godot --headless --path . --script res://test/test_tex_mem_cache.gd

func _init() -> void:
	var fails := 0
	var api := Api.new()
	get_root().add_child(api)
	await process_frame  # 让节点真正进树（_decode_image_async 内部 get_tree().process_frame 要求 api 在树里）

	# 造一张真 PNG 字节，写进两个唯一 hash 的磁盘缓存（内容寻址键，避免撞真实缓存）。
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.3, 0.7, 0.5, 1.0))
	var png := img.save_png_to_buffer()
	var t := Time.get_ticks_usec()
	var h_cached := "unittest_texmem_cached_%d" % t
	var h_uncached := "unittest_texmem_uncached_%d" % t
	api._cache_write(h_cached, png)
	api._cache_write(h_uncached, png)

	# cache_in_mem=false：解码出纹理，但不进 _tex_mem
	var tex_u := await api.fetch_texture(h_uncached, false, false)
	fails += _check("非缓存拉取仍解码出纹理", tex_u != null, true)
	fails += _check("非缓存拉取不进 _tex_mem", api._tex_mem.has(h_uncached), false)

	# 再拉一次（模拟重入最近 N）：磁盘字节仍在，仍能解码出纹理，仍不进 _tex_mem
	var tex_u2 := await api.fetch_texture(h_uncached, false, false)
	fails += _check("重入非缓存仍解码出纹理", tex_u2 != null, true)
	fails += _check("重入非缓存仍不进 _tex_mem", api._tex_mem.has(h_uncached), false)

	# cache_in_mem=true（默认）：解码后进 _tex_mem，第二次命中内存直接返回
	var tex_c := await api.fetch_texture(h_cached, false, true)
	fails += _check("缓存拉取解码出纹理", tex_c != null, true)
	fails += _check("缓存拉取进 _tex_mem", api._tex_mem.has(h_cached), true)
	var tex_c2 := await api.fetch_texture(h_cached, false, true)
	fails += _check("内存命中返回同一纹理实例", tex_c2 == tex_c, true)

	# 清理测试落盘文件
	for h in [h_cached, h_uncached]:
		var p := api._cache_path(h)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	api.free()

	print("test_tex_mem_cache: %d fail(s)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
