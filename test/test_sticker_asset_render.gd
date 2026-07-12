extends SceneTree
## 造贴纸的资产哈希渲染（fairy-stickers P3）：ChunkManager 按 renderRef 'sticker:@<hash>' 从
## 网络资产缓存取贴图，未预热用透明占位、不崩；预热后失效散布种类逼真图重建。
## 锁死客户端渲染缺口的两点：① _scatter_kind 认得 @ 前缀不崩；② 缓存 API 语义正确。
## 运行: godot --headless --path . --script res://test/test_sticker_asset_render.gd

func _init() -> void:
	var fails := 0
	var H := "deadbeefcafe0001" # 测试用假资产哈希（唯一，避免与其它测试串缓存）
	var KEY := "sticker:@" + H

	# 未预热：has=false、get=null
	fails += _check("未预热 has_sticker_asset=false", 1 if not ChunkManager.has_sticker_asset(H) else 0, 1)
	fails += _check("未预热 get_sticker_asset=null", 1 if ChunkManager.get_sticker_asset(H) == null else 0, 1)

	# _scatter_kind 认 @ 前缀：即使没缓存也建出 QuadMesh + 材质（用透明占位），绝不崩
	var cm := ChunkManager.new()
	var info: Dictionary = cm._scatter_kind(KEY)
	fails += _check("_scatter_kind(@hash) 返回 mesh", 1 if info.get("mesh") is QuadMesh else 0, 1)
	fails += _check("_scatter_kind(@hash) 返回 material", 1 if info.get("mat") is ShaderMaterial else 0, 1)
	var placeholder_tex: Texture2D = (info["mat"] as ShaderMaterial).get_shader_parameter("albedo_tex")
	fails += _check("未预热用占位贴图(非空)", 1 if placeholder_tex != null else 0, 1)

	# 预热：灌入真贴图 → get 拿到、has=true、散布种类被失效（下次 rebuild 重建）
	var img := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	var real_tex := ImageTexture.create_from_image(img)
	ChunkManager.cache_sticker_asset(H, real_tex)
	fails += _check("预热后 has_sticker_asset=true", 1 if ChunkManager.has_sticker_asset(H) else 0, 1)
	fails += _check("预热后 get_sticker_asset 拿到真图", 1 if ChunkManager.get_sticker_asset(H) == real_tex else 0, 1)

	# 失效后重建：_scatter_kind 用真图（8×4 → 宽高比 2:1），且贴图是刚灌的那张
	var info2: Dictionary = cm._scatter_kind(KEY)
	var got_tex: Texture2D = (info2["mat"] as ShaderMaterial).get_shader_parameter("albedo_tex")
	fails += _check("重建后用真图", 1 if got_tex == real_tex else 0, 1)
	var q := info2["mesh"] as QuadMesh
	fails += _check("重建后宽按贴图比例(2:1)", 1 if abs(q.size.x - q.size.y * 2.0) < 0.01 else 0, 1)

	# cache 空贴图 no-op（不覆盖真图、不崩）
	ChunkManager.cache_sticker_asset(H, null)
	fails += _check("cache null 不覆盖真图", 1 if ChunkManager.get_sticker_asset(H) == real_tex else 0, 1)

	cm.free()
	if fails == 0:
		print("test_sticker_asset_render: 全部通过")
	quit(fails)

func _check(name: String, got: int, want: int) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %d want %d" % [name, got, want])
	return 1
