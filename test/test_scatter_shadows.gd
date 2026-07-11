extends SceneTree
## 散布贴片阴影单测：ChunkManager._flush_shadows 只给树/灌木铺一层合并 MultiMesh 暗斑
## （补回关实时阴影后散布平光的锚定感），石/草跳过；一次 draw call、不投实时阴影。
## 运行: godot --headless --quit-after 20 --script res://test/test_scatter_shadows.gd

var fails := 0

func _initialize() -> void:
	_test_shadow_xforms()
	_test_flush_shadows()
	_test_empty_when_no_trees()
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
		"tree_puff_a": [_xf(Vector3(1, 0, 1), 1.0), _xf(Vector3(3, 0, 2), 1.2)],
		"bush_puff": [_xf(Vector3(5, 0, 5), 1.0)],
		"rock_0": [_xf(Vector3(2, 0, 2), 1.0)],  # 石头太碎，应跳过
		"tuft_0": [_xf(Vector3(4, 0, 4), 1.0)],  # 草丛太矮，应跳过
	}
	var xforms := cm._shadow_xforms(batches)
	_check("影斑数=树+灌木(3)、不含石/草", xforms.size(), 3)
	if xforms.size() == 3:
		_check("影斑抬离地面（深度余量）", xforms[0].origin.y > 0.0, true)
		# tree0 缩放 1.2 的实例影斑应比缩放 1.0 的大（半径随散布缩放）
		_check("影斑半径随散布缩放变大",
			xforms[1].basis.get_scale().x > xforms[0].basis.get_scale().x, true)
	cm.free()

func _test_flush_shadows() -> void:
	var cm := ChunkManager.new()
	var parent := Node3D.new()
	var batches := {
		"tree_puff_a": [_xf(Vector3(1, 0, 1), 1.0), _xf(Vector3(3, 0, 2), 1.2)],
		"bush_puff": [_xf(Vector3(5, 0, 5), 1.0)],
		"rock_0": [_xf(Vector3(2, 0, 2), 1.0)],
		"tuft_0": [_xf(Vector3(4, 0, 4), 1.0)],
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

func _test_empty_when_no_trees() -> void:
	var cm := ChunkManager.new()
	var parent := Node3D.new()
	cm._flush_shadows(parent, {
		"rock_0": [_xf(Vector3.ZERO, 1.0)],
		"tuft_0": [_xf(Vector3.ZERO, 1.0)],
	})
	_check("无树/灌木时不建影节点", parent.get_node_or_null("ScatterShadows"), null)
	parent.free()
	cm.free()
