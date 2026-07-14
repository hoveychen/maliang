extends SceneTree
## 纸艺风运行时切换（BendMat.set_papercraft）：活材质注册表让开关对「已出厂」的材质
## 也生效——材质被 _wrapped_cache/scatter 批长期持有，只对新建生效的开关等于没切。
## 前置：跑测试的环境不设 MALIANG_PAPERCRAFT（test-headless.sh 不设）。
## 运行: godot --headless --path . --script res://test/test_papercraft_toggle.gd

func _init() -> void:
	var fails := 0

	# 出厂默认：关（参数从未写过 = null，shader 默认 0 同义）
	var m1 := BendMat.make(Color.WHITE)
	var v: Variant = m1.get_shader_parameter("paper_facet")
	fails += _check("默认关(参数未写或为0)", v == null or float(v) == 0.0, true)

	# 运行时开：已出厂材质被补参数，新出厂材质带参数
	BendMat.set_papercraft(true)
	fails += _check("开后旧材质 facet=1", float(m1.get_shader_parameter("paper_facet")), 1.0)
	fails += _check("开后旧材质 tone=0.5", float(m1.get_shader_parameter("paper_tone")), 0.5)
	var m2 := BendMat.make_textured(PlaceholderTexture2D.new())
	fails += _check("开后新材质 bands=3", float(m2.get_shader_parameter("paper_bands")), 3.0)
	fails += _check("papercraft_on 反映开", BendMat.papercraft_on(), true)

	# 运行时关：新旧材质全部归零
	BendMat.set_papercraft(false)
	fails += _check("关后旧材质 facet=0", float(m1.get_shader_parameter("paper_facet")), 0.0)
	fails += _check("关后新材质 bands=0", float(m2.get_shader_parameter("paper_bands")), 0.0)
	fails += _check("papercraft_on 反映关", BendMat.papercraft_on(), false)

	# 全参数键覆盖：PAPER_PROPS 每个键都真的落到材质上
	BendMat.set_papercraft(true)
	var all_set := true
	for k: String in BendMat.PAPER_PROPS:
		if float(m1.get_shader_parameter(k)) != float(BendMat.PAPER_PROPS[k]):
			all_set = false
	fails += _check("PAPER_PROPS 全键落材质", all_set, true)
	BendMat.set_papercraft(false)

	if fails == 0:
		print("papercraft_toggle tests PASS")
	else:
		printerr("papercraft_toggle tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
