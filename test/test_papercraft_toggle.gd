extends SceneTree
## 纸艺风运行时切换：BendMat 活材质注册表 + SdfProp 静态开关（perf_props 组遍历）。
## 开关必须对「已出厂」的材质/物件也生效——材质被缓存/组持有，只对新建生效等于没切。
## SdfProp 的组注册在 _enter_tree，所以节点断言走 _initialize+逐帧 tick
## （照 test_graphics_toggles 先例；_init 里挂节点组遍历摸不到）。
## 前置：跑测试的环境不设 MALIANG_PAPERCRAFT（test-headless.sh 不设）。
## 运行: godot --headless --path . --script res://test/test_papercraft_toggle.gd

var fails := 0
var frame := 0
var m1: ShaderMaterial
var m2: ShaderMaterial
var prop: SdfProp
var prop2: SdfProp

## null 安全取参：参数从未写过返回 -1.0（与合法值 0/正数区分开），绝不喂 float(null)。
func _pf(m: ShaderMaterial, k: String) -> float:
	var v: Variant = m.get_shader_parameter(k)
	return -1.0 if v == null else float(v)

func _initialize() -> void:
	# —— BendMat 段（纯材质，无需场景树）——
	m1 = BendMat.make(Color.WHITE)
	var v := _pf(m1, "paper_facet")
	_check("默认关(参数未写或为0)", v == -1.0 or v == 0.0, true)

	BendMat.set_papercraft(true)
	_check("开后旧材质 facet=1", _pf(m1, "paper_facet"), 1.0)
	_check("开后旧材质 tone=0.5", _pf(m1, "paper_tone"), 0.5)
	m2 = BendMat.make_textured(PlaceholderTexture2D.new())
	_check("开后新材质 bands=3", _pf(m2, "paper_bands"), 3.0)
	_check("papercraft_on 反映开", BendMat.papercraft_on(), true)

	BendMat.set_papercraft(false)
	_check("关后旧材质 facet=0", _pf(m1, "paper_facet"), 0.0)
	_check("关后新材质 bands=0", _pf(m2, "paper_bands"), 0.0)
	_check("papercraft_on 反映关", BendMat.papercraft_on(), false)

	BendMat.set_papercraft(true)
	var all_set := true
	for k: String in BendMat.PAPER_PROPS:
		if _pf(m1, k) != float(BendMat.PAPER_PROPS[k]):
			all_set = false
	_check("PAPER_PROPS 全键落材质", all_set, true)
	BendMat.set_papercraft(false)

	# —— SdfProp 段：挂树后 _enter_tree 才入 perf_props 组，断言推迟到帧 tick ——
	prop = SdfProp.from_spec({"palette": ["#cc6644"], "parts": [{"shape": "sphere"}]})
	if prop == null:
		printerr("  FAIL SdfProp.from_spec 返回 null")
		quit(fails + 1)
		return
	root.add_child(prop)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	match frame:
		1:
			var sv := _pf(prop._mats[0], "paper_facet")
			_check("SDF 默认关(参数未写或为0)", sv == -1.0 or sv == 0.0, true)
			SdfProp.set_papercraft(true, self)
			_check("SDF 开后 facet=1", _pf(prop._mats[0], "paper_facet"), 1.0)
			_check("SDF 开后 edge=0.55", _pf(prop._mats[0], "paper_edge"), 0.55)
			prop2 = SdfProp.from_spec({"palette": ["#44aa66"], "parts": [{"shape": "sphere"}]})
			if prop2 == null:
				printerr("  FAIL SdfProp.from_spec(prop2) 返回 null")
				quit(fails + 1)
				return
			root.add_child(prop2)
			_check("SDF 开后新建也带参数", _pf(prop2._mats[0], "paper_facet"), 1.0)
		2:
			SdfProp.set_papercraft(false, self)
			_check("SDF 关后归零", _pf(prop._mats[0], "paper_facet"), 0.0)
			_check("SDF 关后新旧同步(prop2)", _pf(prop2._mats[0], "paper_facet"), 0.0)
			if fails == 0:
				print("papercraft_toggle tests PASS")
			else:
				printerr("papercraft_toggle tests FAILED: %d" % fails)
			quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
