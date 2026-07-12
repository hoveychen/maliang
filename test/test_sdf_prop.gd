extends SceneTree
## SdfSpec / SdfProp 的独立单测：spec 校验、骨架搭建、示例资产全量解析、uniform 打包。
## 运行: godot --headless --path . --script res://test/test_sdf_prop.gd

func _init() -> void:
	var fails := 0

	# ---- 所有随包示例 spec 必须解析通过且基本体不超上限 ----
	var dir := DirAccess.open("res://assets/sdf_props")
	fails += _check("spec dir exists", dir != null, true)
	var spec_count := 0
	if dir != null:
		for f in dir.get_files():
			if not f.ends_with(".json"):
				continue
			spec_count += 1
			var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/sdf_props/" + f))
			fails += _check("%s is dict" % f, data is Dictionary, true)
			var cfg := SdfSpec.parse(data)
			if not cfg.ok:
				printerr("  FAIL %s parse: %s" % [f, cfg.error])
				fails += 1
				continue
			var rig := SdfSpec.build_rig(cfg)
			fails += _check("%s prims within cap" % f, rig.prims.size() <= SdfSpec.MAX_PRIMS, true)
			fails += _check("%s prims nonempty" % f, rig.prims.size() > 0, true)
	fails += _check("bundled specs present", spec_count >= 5, true)

	# ---- 校验拒收：坏形状 / 坏颜色索引 / 超上限 / 坏腿数 ----
	var bad1 := SdfSpec.parse({"palette": ["#fff"], "parts": [{"shape": "torus"}]})
	fails += _check("reject unknown shape", bad1.ok, false)
	var bad2 := SdfSpec.parse({"palette": ["#fff"], "parts": [{"shape": "sphere", "color": 3}]})
	fails += _check("reject color index", bad2.ok, false)
	var bad3 := SdfSpec.parse({
		"palette": ["#fff"],
		"parts": [{"shape": "sphere"}],
		"locomotion": {"type": "walker", "legs": 5},
	})
	fails += _check("reject 5 legs", bad3.ok, false)
	var many_parts: Array = []
	for i in range(30):
		many_parts.append({"shape": "sphere", "pos": [i, 0, 0]})
	var bad4 := SdfSpec.parse({"palette": ["#fff"], "parts": many_parts})
	fails += _check("reject too many prims", bad4.ok, false)
	var bad5 := SdfSpec.parse({"palette": ["notacolor"], "parts": [{"shape": "sphere"}]})
	fails += _check("reject bad palette", bad5.ok, false)

	# ---- 骨架细节：4 腿 walker ----
	var hut_cfg := SdfSpec.parse(JSON.parse_string(
		FileAccess.get_file_as_string("res://assets/sdf_props/walking_hut.json")))
	var hut_rig := SdfSpec.build_rig(hut_cfg)
	var meta: Dictionary = hut_rig.meta
	fails += _check("hut 4 legs", meta.legs.size(), 4)
	fails += _check("hut body parts", meta.body.size(), 4)
	fails += _check("hut rope run", meta.ropes.size(), 1)
	fails += _check("hut prim total", hut_rig.prims.size(), 4 + 8 + 4)
	# 腿骨可达性：两段骨长之和 ≥ 髋到静止足距离（IK 有解）
	var bad_leg := 0
	for leg in meta.legs:
		if leg.seg_len * 2.0 < leg.hip.distance_to(leg.foot_rest) - 1e-4:
			bad_leg += 1
	fails += _check("legs reachable", bad_leg, 0)
	# 髋左右对称
	fails += _check("hips mirrored", absf(meta.legs[0].hip.x + meta.legs[1].hip.x) < 1e-4, true)

	# capsule_between/cone_between：端点球心处距离 = -半径
	var cb := SdfMath.capsule_between(Vector3(0, 1, 0), Vector3(1, 1, 0), 0.1)
	fails += _check("capsule_between end a", SdfMath.prim_dist(cb, Vector3(0, 1, 0)), -0.1)
	fails += _check("capsule_between end b", SdfMath.prim_dist(cb, Vector3(1, 1, 0)), -0.1)
	var cn := SdfMath.cone_between(Vector3.ZERO, Vector3(0, 1, 0), 0.2, 0.1)
	fails += _check("cone_between bottom", SdfMath.prim_dist(cn, Vector3.ZERO), -0.2)
	fails += _check("cone_between top", SdfMath.prim_dist(cn, Vector3(0, 1, 0)), -0.1)

	# ---- SdfProp 节点组装 ----
	var prop := SdfProp.from_json_file("res://assets/sdf_props/walking_hut.json")
	fails += _check("prop created", prop != null, true)
	if prop != null:
		fails += _check("prop mesh built", prop.mesh != null, true)
		fails += _check("prop single surface", prop.mesh.get_surface_count(), 1)
		var mat := prop.material_override as ShaderMaterial
		fails += _check("prop main material", mat != null, true)
		fails += _check("prop outline pass", (mat.next_pass as ShaderMaterial) != null, true)
		fails += _check("prop cull margin", prop.extra_cull_margin == BendMat.CULL_MARGIN, true)
		var pos: PackedVector4Array = mat.get_shader_parameter("prim_pos")
		fails += _check("uniform prim_pos size", pos.size(), prop.prims.size())
		var cnt: int = mat.get_shader_parameter("prim_count")
		fails += _check("uniform prim_count", cnt, prop.prims.size())
		var outline_mat := mat.next_pass as ShaderMaterial
		var opos: PackedVector4Array = outline_mat.get_shader_parameter("prim_pos")
		fails += _check("outline uniforms synced", opos.size(), prop.prims.size())
		# 形状编码进 prim_pos.w
		fails += _check("shape encoded", int(pos[0].w + 0.5), prop.prims[0].shape)
		prop.free()

	# 坏 spec 走 from_spec 返回 null 不炸
	var none := SdfProp.from_spec({"palette": ["#fff"], "parts": []})
	fails += _check("from_spec rejects", none == null, true)

	# ---- 体型档整体缩放（prop-size）：scale 乘几何量，rate/speed 不动 ----
	var base_spec := {
		"palette": ["#e8b04b"],
		"parts": [{"shape": "box", "pos": [0, 1.0, 0], "size": [1.0, 1.0, 1.0], "color": 0}],
		"locomotion": {"type": "hopper", "hop_h": 0.5, "rate": 1.4},
		"ropes": [],
	}
	var c1 := SdfSpec.parse(base_spec.duplicate(true))
	var scaled_spec := base_spec.duplicate(true)
	scaled_spec["scale"] = 1.4
	var c1_4 := SdfSpec.parse(scaled_spec)
	fails += _check("scale 缺省 1.0", is_equal_approx(float(c1.scale), 1.0), true)
	fails += _check("scale 读取 1.4", is_equal_approx(float(c1_4.scale), 1.4), true)
	# box size 半展 params：1.0×1.4×0.5=0.7 vs 0.5
	fails += _check("part.params ×scale", is_equal_approx(c1_4.parts[0].params.x, 0.7), true)
	fails += _check("part.pos ×scale", is_equal_approx(c1_4.parts[0].pos.y, 1.4), true)
	fails += _check("hop_h 振幅 ×scale", is_equal_approx(float(c1_4.locomotion.hop_h), 0.7), true)
	fails += _check("rate 频率不缩放", is_equal_approx(float(c1_4.locomotion.rate), 1.4), true)
	# AABB 随 scale 变大（1.4× 的包围盒明显大于 1.0×）
	var aabb1 := SdfMath.rest_aabb(SdfSpec.build_rig(c1).prims)
	var aabb14 := SdfMath.rest_aabb(SdfSpec.build_rig(c1_4).prims)
	fails += _check("AABB 随 scale 变大", aabb14.size.y > aabb1.size.y + 0.1, true)

	if fails == 0:
		print("sdf_prop tests PASS")
	else:
		printerr("sdf_prop tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT:
		if absf(got - want) < 1e-3:
			return 0
	elif got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
