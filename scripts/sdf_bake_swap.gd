extends Node
## 把「真静止」的 live SdfProp 异步烘焙成零成本静态 mesh 并原地替换。
## autoload 单例（名 SdfBakeSwap，见 project.godot）：自带 _process 轮询在途烘焙、_exit_tree 排干，
## 无 class_name（避免与 autoload 全局名冲突，照 HarnessCmd/DebugCmdServer 先例）。
##
## 动机：live SdfProp 每帧每顶点重算 SDF 场把壳吸附到表面（成本主轴，见 sdf_prop.gd），
## 即便造物一动不动（loco=none 且无 spin/head/ropes）也照付。SdfSpec.is_static 判出这类造物后，
## 烘焙成一份普通 ArrayMesh（SdfStaticBaker，树/灌木同款）——之后就是纯网格，每帧零成本、
## 且不进 perf_props（不再被「会动的物件」画质开关波及，如烘焙树般恒显）。
##
## 时序（保留造物落地「变!」的仪式感）：
##   1. 造物瞬间照常显 live SdfProp（会呼吸、能立刻看见）。
##   2. WorkerThreadPool 后台线程跑 SdfStaticBaker.bake_config（逐顶点投影，"秒级"，纯 CPU；
##      只读不可变 cfg、结果写 holder，主线程在 is_task_completed 为真后读=内存屏障，happens-after 安全）。
##   3. _process 轮询到完成 → 主线程 swap：建 SdfStaticBaker.instance + 同款脚下 BlobShadow，
##      加到 live 同一父节点、同一 transform，再 queue_free 掉 live SdfProp。
##
## 线程范式照搬 behavior_executor 的异步寻路：绑定方法（非 lambda，静态上下文 lambda 无 self 会崩）、
## is_task_completed 内存屏障、关停阻塞排干（引擎销毁在途任务的绑定 Callable 会 exit 134）。

## 在途烘焙任务：[{ tid:int, prop:SdfProp, holder:{mesh}, on_swapped:Callable }]
var _pending: Array = []

func _process(_dt: float) -> void:
	if _pending.is_empty():
		return
	for i in range(_pending.size() - 1, -1, -1):
		var e: Dictionary = _pending[i]
		if not WorkerThreadPool.is_task_completed(e["tid"]):
			continue
		WorkerThreadPool.wait_for_task_completion(e["tid"])  # 完成后仍需 wait 回收任务句柄
		_pending.remove_at(i)
		_swap(e["prop"], e["holder"]["mesh"], e["on_swapped"])

## 异步烘焙并替换 prop。非静止（会动）的原样保留 live，返回 false（调用方无需处理）。
## 返回 true = 已排入后台烘焙队列；swap 在烘焙完成后由 _process 自动发生。
## on_swapped（可选）：swap 完成后以新静态实例回调（如更新外部持有的节点引用）。
func bake_and_swap(prop: SdfProp, on_swapped := Callable()) -> bool:
	if not _bakeable(prop):
		return false
	var holder := {"mesh": null}
	var tid := WorkerThreadPool.add_task(_bake_task.bind(prop.config, holder), true, "sdf_bake")
	_pending.append({"tid": tid, "prop": prop, "holder": holder, "on_swapped": on_swapped})
	return true

## worker 线程体：只读不可变 cfg 烘焙，结果写 holder。绝不碰节点/SceneTree（swap 留主线程）。
func _bake_task(cfg: Dictionary, holder: Dictionary) -> void:
	holder["mesh"] = SdfStaticBaker.bake_config(cfg)

## 同步烘焙并替换（headless 单测/确定性用）：当帧完成 bake+swap，不经 WorkerThreadPool。
## 返回替换上的静态 MeshInstance3D；非静止或烘焙失败返回 null（prop 保持不变）。
func bake_and_swap_sync(prop: SdfProp) -> MeshInstance3D:
	if not _bakeable(prop):
		return null
	return _swap(prop, SdfStaticBaker.bake_config(prop.config), Callable())

func _bakeable(prop: SdfProp) -> bool:
	return prop != null and prop.config.get("ok", false) and SdfSpec.is_static(prop.config)

## 主线程：静态实例上场、live 下场。live 可能在烘焙这段时间里被卸载（换场景/区块重铺），
## 故先验活性与在树；不在树就丢弃这次烘焙结果（下次重铺会再来一遍）。
func _swap(prop: SdfProp, mesh: ArrayMesh, on_swapped: Callable) -> MeshInstance3D:
	if mesh == null or not is_instance_valid(prop) or not prop.is_inside_tree():
		return null
	var parent := prop.get_parent()
	var mi := SdfStaticBaker.instance(mesh)
	mi.name = str(prop.name) + "_baked"
	mi.transform = prop.transform
	parent.add_child(mi)
	# 脚下暗斑：对齐 SdfProp._setup 的半径公式（水平最大展 ×0.4，夹 [0.4,2.2]），bend=true。
	var aabb := mesh.get_aabb()
	BlobShadow.attach(mi, clampf(maxf(aabb.size.x, aabb.size.z) * 0.4, 0.4, 2.2), true)
	prop.queue_free()
	if on_swapped.is_valid():
		on_swapped.call(mi)
	return mi

## 关停排干：引擎销毁在途任务残留的绑定 Callable（引用 GDScript 对象/cfg）时，若任务仍在途会崩
## （退出 exit 134）。autoload _exit_tree 在场景清理阶段跑、早于 WorkerThreadPool 析构，安全。
func _exit_tree() -> void:
	for e in _pending:
		WorkerThreadPool.wait_for_task_completion(e["tid"])
	_pending.clear()
