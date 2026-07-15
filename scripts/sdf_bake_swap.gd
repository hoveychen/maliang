class_name SdfBakeSwap
extends RefCounted
## 把一只「真静止」的 live SdfProp 异步烘焙成零成本静态 mesh 并原地替换。
##
## 动机：live SdfProp 每帧每顶点重算 SDF 场把壳吸附到表面（成本主轴，见 sdf_prop.gd），
## 即便造物一动不动（loco=none 且无 spin/head/ropes）也照付。SdfSpec.is_static 判出这类造物后，
## 把它烘焙成一份普通 ArrayMesh（SdfStaticBaker，树/灌木同款）——之后就是纯网格，每帧零成本。
##
## 时序（保留造物落地「变!」的仪式感）：
##   1. 造物瞬间照常显 live SdfProp（会呼吸、能立刻看见）。
##   2. WorkerThreadPool 后台线程跑 SdfStaticBaker.bake_config（逐顶点投影，"秒级"，纯 CPU；
##      ArrayMesh 走 Godot 4 的 RenderingServer 命令队列，属线程安全的后台网格生成范式）。
##   3. 烘焙完 call_deferred 回主线程：建 SdfStaticBaker.instance + 同款脚下 BlobShadow，
##      加到 live 同一个父节点、同一 transform，再 queue_free 掉 live SdfProp。
## 静态实例是普通 MeshInstance3D，不进 perf_props → 画质开关/逐帧成本都不再碰它。
##
## 只读 prop.config（parse 后即不可变；动画只改 prop.prims[i].xform，不碰 config），故后台读安全。

## 异步烘焙并替换 prop。非静止（会动）的 prop 原样保留 live，返回 false（调用方无需处理）。
## 返回 true 表示已排入后台烘焙队列；swap 在烘焙完成后自动发生。
static func bake_and_swap(prop: SdfProp) -> bool:
	if not _bakeable(prop):
		return false
	var cfg: Dictionary = prop.config
	WorkerThreadPool.add_task(func() -> void:
		var mesh := SdfStaticBaker.bake_config(cfg)
		_swap.bind(prop, mesh).call_deferred())
	return true

## 同步烘焙并替换（headless 单测/确定性用）：当帧完成 bake+swap，不经 WorkerThreadPool。
## 返回替换上的静态 MeshInstance3D；非静止或烘焙失败返回 null（prop 保持不变）。
static func bake_and_swap_sync(prop: SdfProp) -> MeshInstance3D:
	if not _bakeable(prop):
		return null
	var mesh := SdfStaticBaker.bake_config(prop.config)
	return _swap(prop, mesh)

static func _bakeable(prop: SdfProp) -> bool:
	return prop != null and prop.config.get("ok", false) and SdfSpec.is_static(prop.config)

## 主线程：静态实例上场、live 下场。live 可能在烘焙这段时间里被卸载（换场景/区块重铺），
## 故先验活性与在树；不在树就丢弃这次烘焙结果（下次重铺会再来一遍）。
static func _swap(prop: SdfProp, mesh: ArrayMesh) -> MeshInstance3D:
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
	return mi
