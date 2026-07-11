extends SceneTree
## 散布贴片阴影单测：ChunkManager._flush_shadows 只给树/灌木铺一层合并 MultiMesh 暗斑
## （补回关实时阴影后散布平光的锚定感），石/草跳过；一次 draw call、不投实时阴影。
## 运行: godot --headless --quit-after 20 --script res://test/test_scatter_shadows.gd

var fails := 0

func _initialize() -> void:
	_test_shadow_xforms()
	_test_flush_shadows()
	_test_empty_when_no_trees()
	_test_building_shadows()
	if fails == 0:
		print("scatter_shadows tests PASS")
	else:
		printerr("scatter_shadows FAILED: %d" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1

## 散布批次里的一条实例变换：基本体只关心落点与缩放（yaw 对圆形影斑无意义）。
func _xf(pos: Vector3, scale_f: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, 0.3).scaled(Vector3.ONE * scale_f), pos)

## 几何断言走纯函数（CPU 侧）：headless 下 MultiMesh 的 transform 由 RenderingServer
## dummy 后端管理、set 后 get 读不回单位矩阵，所以只能在装配前的 Array[Transform3D] 上验。
func _test_shadow_xforms() -> void:
	var cm := ChunkManager.new()
	var batches := {
		"tree0": [_xf(Vector3(1, 0, 1), 1.0), _xf(Vector3(3, 0, 2), 1.2)],
		"bush": [_xf(Vector3(5, 0, 5), 1.0)],
		"rock0": [_xf(Vector3(2, 0, 2), 1.0)],  # 石头太碎，应跳过
		"tuft0": [_xf(Vector3(4, 0, 4), 1.0)],  # 草丛太矮，应跳过
	}
	# 固定太阳方向（不依赖 world 启动），断言才确定：太阳偏左近侧、影朝右远拖
	BlobShadow.sun_ground_dir = Vector3(0.643, 0.0, -0.766)
	var xforms := cm._shadow_xforms(batches)
	_check("影斑数=树+灌木(3)、不含石/草", xforms.size(), 3)
	if xforms.size() == 3:
		_check("影斑抬离地面（深度余量）", xforms[0].origin.y > 0.0, true)
		# 影心朝太阳照射(背光)方向偏移：水平位移与 sun_ground_dir 同向
		var horiz := xforms[0].origin - Vector3(1, 0, 1)  # 减 tree0 首个落点
		horiz.y = 0.0
		_check("影心朝光方向偏移（拖出树冠外）",
			horiz.length() > 0.01 and horiz.normalized().dot(BlobShadow.sun_ground_dir) > 0.99, true)
		# 椭圆：长轴（沿光方向）明显大于短轴，模拟斜阳
		var sc: Vector3 = xforms[0].basis.get_scale()
		_check("影斑是椭圆（长轴>短轴）", maxf(sc.x, sc.z) > minf(sc.x, sc.z) * 1.3, true)
		# tree0 缩放 1.2 的实例影斑应比缩放 1.0 的大（随散布缩放）
		_check("影斑随散布缩放变大",
			xforms[1].basis.get_scale().length() > xforms[0].basis.get_scale().length(), true)
	cm.free()

func _test_flush_shadows() -> void:
	var cm := ChunkManager.new()
	var parent := Node3D.new()
	var batches := {
		"tree0": [_xf(Vector3(1, 0, 1), 1.0), _xf(Vector3(3, 0, 2), 1.2)],
		"bush": [_xf(Vector3(5, 0, 5), 1.0)],
		"rock0": [_xf(Vector3(2, 0, 2), 1.0)],
		"tuft0": [_xf(Vector3(4, 0, 4), 1.0)],
	}
	cm._flush_shadows(parent, batches)
	var mmi := parent.get_node_or_null("ScatterShadows")
	_check("建了 ScatterShadows 节点", mmi != null, true)
	if mmi != null:
		_check("是 MultiMeshInstance3D", mmi is MultiMeshInstance3D, true)
		_check("实例数=树+灌木(3)、不含石/草", mmi.multimesh.instance_count, 3)
		_check("不投实时阴影", mmi.cast_shadow,
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	parent.free()
	cm.free()

## 地标建筑影：_visual_short_r 随缩放变大；_flush_building_shadows 建 BuildingShadows
## 合并 MultiMesh、不投实时阴影（椭圆/偏移复用 _shadow_xform，已由 _test_shadow_xforms 覆盖）。
func _test_building_shadows() -> void:
	var cm := ChunkManager.new()
	var parent := Node3D.new()
	var b := Node3D.new()  # 假建筑：一个 4×3×4 的 box mesh
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(4, 3, 4)
	mi.mesh = bm; b.add_child(mi)
	var ext := cm._visual_extent(b, 1.0)   # (short_r, height)
	var ext2 := cm._visual_extent(b, 2.0)
	_check("建筑影短半径 > 0", ext.x > 0.0, true)
	_check("建筑高度 > 0（斜阳投影靠它拖长）", ext.y > 0.0, true)
	_check("建筑影随实例缩放变大", ext2.x > ext.x, true)
	cm._flush_building_shadows(parent, [[Vector3(1, 0, 1), ext.x, ext.y], [Vector3(5, 0, 5), ext.x, ext.y]])
	var mmi := parent.get_node_or_null("BuildingShadows")
	_check("建了 BuildingShadows 节点", mmi != null, true)
	if mmi != null:
		_check("建筑影实例数=2", mmi.multimesh.instance_count, 2)
		_check("建筑影不投实时阴影", mmi.cast_shadow,
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	b.free()
	parent.free()
	cm.free()

func _test_empty_when_no_trees() -> void:
	var cm := ChunkManager.new()
	var parent := Node3D.new()
	cm._flush_shadows(parent, {
		"rock0": [_xf(Vector3.ZERO, 1.0)],
		"tuft0": [_xf(Vector3.ZERO, 1.0)],
	})
	_check("无树/灌木时不建影节点", parent.get_node_or_null("ScatterShadows"), null)
	parent.free()
	cm.free()
