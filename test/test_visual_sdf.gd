extends SceneTree
## SDF 可动物件世界回归：
## (1) 摆放——七只 SDF 物件全部落进世界（两只会动的+五只安静物品，占地找位成功）；
## (2) 结构——单 surface 合并网格 + blend-shell 主材质 + 描边 next_pass + uniform 打包一致；
## (3) 活着——观察数秒：走兽/跳跳有位移（锚点游走），所有物件基本体姿态在变（动画在跑）；
## (4) 稳定——物理绳/IK 不发散（所有基本体 origin 有限且在物件局部 20m 内）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 140 --script res://test/test_visual_sdf.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

var scene: Node
var frame := 0
var fails := 0
var _props: Array = []
var _pos0: Dictionary = {}        ## name → 初始 position
var _prim0: Dictionary = {}       ## name → 第一个非 body 基本体的初始 origin
var _moved: Dictionary = {}       ## name → 是否观察到位移
var _animated: Dictionary = {}    ## name → 是否观察到基本体姿态变化
var _dyn_return := Vector2.ZERO   ## 动态物件测试：玩家跨区前的原位

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
		_ when frame == 112:
			_dynamic_add()
		_ when frame == 114:
			_check("动态物件出现在树里", _find_dynamic() != null, true)
			# 玩家跨半个世界：3×3 区块池全部换皮（动态物件所在区块必被重刷）
			var player: Dictionary = scene.get("player")
			_dyn_return = player["logical"]
			player["logical"] = WorldGrid.wrap_pos((_dyn_return as Vector2) + Vector2(70.0, 0.0))
		_ when frame == 120:
			var player2: Dictionary = scene.get("player")
			player2["logical"] = _dyn_return
		_ when frame == 126:
			_check("区块重刷后动态物件原位重生成", _find_dynamic() != null, true)
			_finish()

func _collect() -> void:
	_props = root.find_children("*", "SdfProp", true, false)
	for p: SdfProp in _props:
		_pos0[p.name] = p.position
		_prim0[p.name] = (p.prims[p.prims.size() - 1] as SdfMath.Prim).xform.origin
		_moved[p.name] = false
		_animated[p.name] = false

func _structural() -> void:
	_check("七只 SDF 物件全部落进世界", _props.size(), 7)
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
	# 循环变量不带 SdfProp 类型标注：静止造物被 chunk_manager 烘焙成静态网格后 queue_free（预期），
	# _props 留悬垂引用；带类型 for 对已释放元素做类型化赋值即报「freed instance」（早于循环体 guard），
	# 故去类型 + is_instance_valid 跳过。其 _animated/_moved 在释放前已按 name 记录，判定不受影响。
	for p in _props:
		if not is_instance_valid(p):
			continue
		var sp := p as SdfProp
		if (sp.position - (_pos0[sp.name] as Vector3)).length() > 0.08:
			_moved[sp.name] = true
		var last: SdfMath.Prim = sp.prims[sp.prims.size() - 1]
		# 阈值 0.01：安静物品（纸/蜡笔）只有待机呼吸（±0.02 的 y 起伏）也要能判活
		if (last.xform.origin - (_prim0[sp.name] as Vector3)).length() > 0.01:
			_animated[sp.name] = true

func _liveness() -> void:
	var moved_count := 0
	var animated_count := 0
	var unstable := 0
	# 计数按 name 查字典（_collect 建键），不碰节点：已烘焙释放的 prop 也算数（动画在释放前已记录）。
	for nm in _animated.keys():
		if _moved[nm]:
			moved_count += 1
		if _animated[nm]:
			animated_count += 1
	# 稳定性检查要读 prims，去类型 + 跳过已释放节点（同 _observe）。
	for p in _props:
		if not is_instance_valid(p):
			continue
		for pr: SdfMath.Prim in (p as SdfProp).prims:
			var o := pr.xform.origin
			if not (is_finite(o.x) and is_finite(o.y) and is_finite(o.z)) or o.length() > 20.0:
				unstable += 1
	_check("所有物件动画都在跑（末位基本体动过）", animated_count, _props.size())
	_check("两只带 locomotion 的在游走（9.5s 观察窗）", moved_count >= 2, true)
	_check("IK/物理绳不发散（origin 有限且 <20m）", unstable, 0)

## 语音造物路径（离线直调）：add_dynamic_prop 就近落位并登记运行时清单。
func _dynamic_add() -> void:
	var spec := {
		"name": "test_dyn_prop",
		"palette": ["#e8574b"],
		"parts": [{ "shape": "sphere", "pos": [0, 0.3, 0], "r": 0.25 }],
		"locomotion": { "type": "none" },
	}
	var player: Dictionary = scene.get("player")
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos((player["logical"] as Vector2) + Vector2(3.0, 2.0)))
	var cm: ChunkManager = scene.get("chunk_manager")
	var placed: Vector2i = cm.add_dynamic_prop(spec, want, 45.0, 0.0)
	_check("动态物件成功落位", placed.x >= 0, true)

func _find_dynamic() -> SdfProp:
	for p: SdfProp in root.find_children("*", "SdfProp", true, false):
		if String(p.config.get("name", "")) == "test_dyn_prop":
			return p
	return null

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
