extends SceneTree
## SdfStaticBaker 单测：烘焙网格顶点必须真的吸附在 smooth-min 融合面上、
## 法线单位化、颜色软混进顶点色；随包提交的 baked/*.res 与 spec 同步（防改 spec 忘重烘）。
## 运行: godot --headless --quit-after 20 --script res://test/test_sdf_static_baker.gd

var fails := 0

func _initialize() -> void:
	_test_bake_snaps_to_surface()
	_test_baked_assets_fresh()
	if fails == 0:
		print("sdf_static_baker tests PASS")
	else:
		printerr("sdf_static_baker FAILED: %d" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1

func _test_bake_snaps_to_surface() -> void:
	var spec := {
		"name": "two_blob",
		"palette": ["#ff0000", "#00ff00"],
		"blend": 0.4,
		"outline": 0.0,
		"color_k": 0.5,
		"parts": [
			{"shape": "sphere", "pos": [0, 0.5, 0], "r": 0.5, "color": 0},
			{"shape": "sphere", "pos": [0.6, 0.9, 0], "r": 0.35, "color": 1},
		],
		"locomotion": {"type": "none"},
		"ropes": [],
	}
	var mesh := SdfStaticBaker.bake_spec(spec)
	_check("烘焙返回网格", mesh != null, true)
	if mesh == null:
		return
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	_check("有顶点", verts.size() > 0, true)
	_check("顶点色数量一致", cols.size(), verts.size())
	var cfg := SdfSpec.parse(spec)
	var prims: Array = SdfSpec.build_rig(cfg).prims
	var worst := 0.0
	var worst_n := 0.0
	for i in range(0, verts.size(), 7):
		worst = maxf(worst, absf(SdfMath.eval(prims, verts[i], 0.4)))
		worst_n = maxf(worst_n, absf(norms[i].length() - 1.0))
	_check("顶点吸附在融合面上（|SDF|<2cm）", worst < 0.02, true)
	_check("法线单位化", worst_n < 0.01, true)
	# 两球异色 + color_k 软混：靠红球处偏红、靠绿球处偏绿，且存在中间过渡
	var reddest := cols[0]
	var greenest := cols[0]
	for c in cols:
		if c.r - c.g > reddest.r - reddest.g:
			reddest = c
		if c.g - c.r > greenest.g - greenest.r:
			greenest = c
	_check("红端顶点色以红为主", reddest.r > 0.6 and reddest.g < 0.4, true)
	_check("绿端顶点色以绿为主", greenest.g > 0.6 and greenest.r < 0.4, true)

## baked/*.res 必须与 spec 烘焙结果同步（顶点数一致即认为未过期）。
func _test_baked_assets_fresh() -> void:
	for base in ["tree_puff_a", "tree_puff_b", "tree_puff_c", "bush_puff"]:
		var res_path := "res://assets/sdf_props/baked/%s.res" % base
		_check("%s.res 存在" % base, ResourceLoader.exists(res_path), true)
		if not ResourceLoader.exists(res_path):
			continue
		var baked: ArrayMesh = load(res_path)
		var fresh := SdfStaticBaker.bake_json_file("res://assets/sdf_props/%s.json" % base)
		_check("%s 顶点色通道在" % base,
			baked.surface_get_arrays(0)[Mesh.ARRAY_COLOR] != null, true)
		_check("%s .res 与 spec 同步（重跑 tools/bake_sdf_deco.gd）" % base,
			baked.surface_get_array_len(0), fresh.surface_get_array_len(0))
