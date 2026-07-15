extends SceneTree
## SdfBakeSwap 单测：真静止造物烘焙后应从 perf_props 逐帧成本里彻底消失——换成普通静态
## MeshInstance3D（不在 perf_props）、带脚下 BlobShadow、live SdfProp 被回收；会动的造物则原样
## 保留 live、不烘焙。
##   - 同步路径（bake_and_swap_sync）：当帧断言，确定性。
##   - 异步路径（bake_and_swap → WorkerThreadPool + call_deferred）：跨帧等真正完成后断言，
##     验证线程化烘焙+主线程 swap 不炸、结果一致（真机渲染在 P4 目视验）。
##
## 断言在 _process（而非 _init）跑：SdfProp 靠 _enter_tree 加入 perf_props，需节点真正入树；
## _init 阶段 root Window 尚未入树。运行: godot --headless --quit-after 600 --script res://test/test_sdf_bake_swap.gd

var fails := 0
var _phase := 0
var _async_prop: SdfProp = null
var _async_baked: MeshInstance3D = null
var _waited := 0

const STATIC_SPEC := {
	"name": "quiet_rock",
	"palette": ["#e8b04b"],
	"parts": [
		{"shape": "box", "pos": [0, 0.5, 0], "size": [1.0, 1.0, 1.0], "color": 0},
		{"shape": "sphere", "pos": [0, 1.1, 0], "r": 0.4, "color": 0},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}

const SPIN_SPEC := {
	"name": "windmill",
	"palette": ["#e8b04b"],
	"parts": [
		{"shape": "box", "pos": [0, 1.0, 0], "size": [0.8, 0.1, 0.1], "color": 0, "spin": 1.5},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}

func _process(_dt: float) -> bool:
	match _phase:
		0:
			_test_static_prop_swapped()
			_test_animated_prop_kept_live()
			_start_async()
			_phase = 1
			return false
		1:
			_waited += 1
			# on_swapped 回调把 baked 实例塞进 _async_baked = WorkerThreadPool 烘焙完 + 主线程 swap 已发生
			if _async_baked != null:
				_finish_async()
				return _report()
			if _waited > 500:
				_check("异步 swap 在合理帧内完成", true, false)
				return _report()
			return false
	return true

func _report() -> bool:
	if fails == 0:
		print("sdf_bake_swap tests PASS")
	else:
		printerr("sdf_bake_swap FAILED: %d" % fails)
	quit(fails)
	return true

func _baker() -> Node:
	return root.get_node(^"SdfBakeSwap")

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1

func _test_static_prop_swapped() -> void:
	var prop := SdfProp.from_spec(STATIC_SPEC)
	_check("静物 prop 建成", prop != null, true)
	if prop == null:
		return
	root.add_child(prop)
	_check("live 进 perf_props", prop.is_in_group("perf_props"), true)

	var mi: MeshInstance3D = _baker().bake_and_swap_sync(prop)
	_check("swap 返回静态实例", mi != null, true)
	if mi == null:
		return
	# 静态实例：普通 MeshInstance3D、有网格、绝不在 perf_props（逐帧成本清零的关键断言）
	_check("静态实例不在 perf_props", mi.is_in_group("perf_props"), false)
	_check("静态实例有网格", mi.mesh != null and mi.mesh.get_surface_count() > 0, true)
	_check("烘焙网格有顶点", mi.mesh.get_faces().size() > 0, true)
	_check("静态实例带 BlobShadow", mi.get_node_or_null("BlobShadow") != null, true)
	_check("挂到 live 同一父节点", mi.get_parent() == root, true)
	_check("live SdfProp 已回收", prop.is_queued_for_deletion(), true)
	mi.queue_free()

func _test_animated_prop_kept_live() -> void:
	var prop := SdfProp.from_spec(SPIN_SPEC)
	_check("风车 prop 建成", prop != null, true)
	if prop == null:
		return
	root.add_child(prop)
	var mi: MeshInstance3D = _baker().bake_and_swap_sync(prop)
	_check("会动造物不烘焙(返回 null)", mi == null, true)
	_check("会动造物保持 live 在 perf_props", prop.is_in_group("perf_props"), true)
	_check("会动 live 未被回收", prop.is_queued_for_deletion(), false)
	prop.queue_free()

func _start_async() -> void:
	_async_prop = SdfProp.from_spec(STATIC_SPEC)
	_check("异步:静物 prop 建成", _async_prop != null, true)
	if _async_prop == null:
		return
	root.add_child(_async_prop)
	# on_swapped 回调捕获 baked 实例（避免按名查找——同名节点会被 Godot 改名+净化，脆弱）
	var queued: bool = _baker().bake_and_swap(_async_prop, func(mi: MeshInstance3D) -> void:
		_async_baked = mi)
	_check("异步:已排入烘焙队列", queued, true)

func _finish_async() -> void:
	# 线程化烘焙+主线程 swap 完成后：on_swapped 回来的静态实例应是 MeshInstance3D、不在 perf_props、有网格
	_check("异步:静态实例是 MeshInstance3D", _async_baked is MeshInstance3D, true)
	_check("异步:静态实例不在 perf_props", _async_baked.is_in_group("perf_props"), false)
	_check("异步:静态实例有网格", (_async_baked as MeshInstance3D).mesh != null, true)
	_check("异步:live SdfProp 已回收", not is_instance_valid(_async_prop) or _async_prop.is_queued_for_deletion(), true)
	_async_baked.queue_free()
