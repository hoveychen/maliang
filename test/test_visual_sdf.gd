extends SceneTree
## SDF 可动物件世界回归：
## (1) 摆放——五只 SDF 物件全部落进世界（占地找位成功）；
## (2) 结构——单 surface 合并网格 + blend-shell 主材质 + 描边 next_pass + uniform 打包一致；
## (3) 活着——观察数秒：走兽/跳跳有位移（锚点游走），所有物件基本体姿态在变（动画在跑）；
## (4) 稳定——物理绳/IK 不发散（所有基本体 origin 有限且在物件局部 20m 内）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 130 --script res://test/test_visual_sdf.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

var scene: Node
var frame := 0
var fails := 0
var _props: Array = []
var _pos0: Dictionary = {}        ## name → 初始 position
var _prim0: Dictionary = {}       ## name → 第一个非 body 基本体的初始 origin
var _moved: Dictionary = {}       ## name → 是否观察到位移
var _animated: Dictionary = {}    ## name → 是否观察到基本体姿态变化

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	match true:
		_ when frame == 15:
			_collect()
			_structural()
		_ when frame > 15 and frame < 110:
			_observe()
		_ when frame == 110:
			_liveness()
			_finish()

func _collect() -> void:
	_props = root.find_children("*", "SdfProp", true, false)
	for p: SdfProp in _props:
		_pos0[p.name] = p.position
		_prim0[p.name] = (p.prims[p.prims.size() - 1] as SdfMath.Prim).xform.origin
		_moved[p.name] = false
		_animated[p.name] = false

func _structural() -> void:
	_check("五只 SDF 物件全部落进世界", _props.size(), 5)
	for p: SdfProp in _props:
		_check("%s 单 surface 网格" % p.name, p.mesh.get_surface_count(), 1)
		var mat := p.material_override as ShaderMaterial
		_check("%s 主材质是 blend-shell" % p.name,
			mat != null and mat.shader.resource_path.ends_with("sdf_blend_shell.gdshader"), true)
		_check("%s 挂了描边 next_pass" % p.name, (mat.next_pass as ShaderMaterial) != null, true)
		var pos: PackedVector4Array = mat.get_shader_parameter("prim_pos")
		_check("%s uniform 与基本体数一致" % p.name, pos.size(), p.prims.size())
		var arr := p.mesh.surface_get_arrays(0)
		var uv2: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
		_check("%s 顶点带基本体索引(UV2)" % p.name, uv2.size() > 0, true)

func _observe() -> void:
	for p: SdfProp in _props:
		if (p.position - (_pos0[p.name] as Vector3)).length() > 0.08:
			_moved[p.name] = true
		var last: SdfMath.Prim = p.prims[p.prims.size() - 1]
		if (last.xform.origin - (_prim0[p.name] as Vector3)).length() > 0.02:
			_animated[p.name] = true

func _liveness() -> void:
	var moved_count := 0
	var animated_count := 0
	var unstable := 0
	for p: SdfProp in _props:
		if _moved[p.name]:
			moved_count += 1
		if _animated[p.name]:
			animated_count += 1
		for pr: SdfMath.Prim in p.prims:
			var o := pr.xform.origin
			if not (is_finite(o.x) and is_finite(o.y) and is_finite(o.z)) or o.length() > 20.0:
				unstable += 1
	_check("所有物件动画都在跑（末位基本体动过）", animated_count, _props.size())
	_check("至少三只在游走（9.5s 观察窗）", moved_count >= 3, true)
	_check("IK/物理绳不发散（origin 有限且 <20m）", unstable, 0)

func _finish() -> void:
	if fails == 0:
		print("visual_sdf PASS")
	else:
		printerr("visual_sdf FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	fails += 1
