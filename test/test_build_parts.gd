extends SceneTree
## 积木式造物 B1 零件真图（P3）落盘校验：
## - build_parts pack 注册进 index.json，32 个零件键全部能加载成真 Texture2D（不是占位色块）。
## - ComposedProp 拿到的是 PackRegistry 的真图（同一对象），不再回落 48px 占位。
## 运行: godot --headless --script res://test/test_build_parts.gd

var fails := 0

func _init() -> void:
	# build_parts pack 已注册且键数正确
	var keys: Array = PackRegistry.keys_in_pack("build_parts")
	_check("build_parts pack 有 60 个键(原32+蛋糕/花/冰淇淋28)", keys.size(), 60)

	# 每个零件键都能加载成真 Texture2D（宽高 > 占位 48px，证明是生成图不是占位色块）
	var loaded_ok := 0
	var too_small := []
	for key in keys:
		var res := PackRegistry.load_resource(String(key))
		if res is Texture2D and (res as Texture2D).get_width() > 48 and (res as Texture2D).get_height() > 48:
			loaded_ok += 1
		else:
			too_small.append(key)
	_check("全部零件键加载成真图(>48px)", loaded_ok, keys.size())
	if not too_small.is_empty():
		printerr("  未加载/过小: %s" % str(too_small))

	# ComposedProp 用的是真图：wheel_round 的子 quad 贴图 == PackRegistry 加载的同一对象（非占位）
	var real := PackRegistry.load_resource("wheel_round") as Texture2D
	_check("wheel_round 真图存在", real != null, true)
	var spec := {
		"blueprintId": "car",
		"parts": [{ "slotId": "wheel_back", "partId": "wheel_round", "partRenderRef": "part:wheel_round" }],
	}
	var cp := ComposedProp.from_spec(spec)
	root.add_child(cp)
	var holder: Node3D = cp._part_holders.get("wheel_back")
	_check("wheel_back holder 存在", holder != null, true)
	if holder != null:
		# 三明治双片，任一片的 QuadMesh 贴图应是真图对象（非 48px 占位）
		var used_real := false
		for c in holder.get_children():
			var mi := c as MeshInstance3D
			if mi != null and mi.mesh is QuadMesh:
				var mat := (mi.mesh as QuadMesh).material as StandardMaterial3D
				if mat != null and mat.albedo_texture == real:
					used_real = true
		_check("ComposedProp 用真图(非占位色块)", used_real, true)

	print("== test_build_parts: %d 失败 ==" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		return
	fails += 1
	printerr("  ✗ %s: got=%s want=%s" % [name, str(got), str(want)])
