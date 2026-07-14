extends SceneTree
## 进度式加载 + 就绪才揭幕（消除玩家启动瞬移）的单元测试。
## 覆盖两件事：
##   1. 关窗不变量：api.get_world 的网络超时严格 < world 的就绪硬超时——保证「慢但成功」
##      的 get_world 必在 loading 揭幕前定音（成功走正常路径 / 超时走离线），从源头堵死
##      「揭幕后 get_world 才返回、把玩家硬拽到仙子旁」这一启动瞬移窗口。
##   2. chunk_manager.skinned_fraction()：loading 仙子飞行进度的地基信号。
## 运行: godot --headless --path . --script res://test/test_loading_progress.gd

func _init() -> void:
	var fails := 0

	# --- 关窗不变量：get_world 超时 < 就绪硬超时，且为正（有限）---
	# world.gd 无 class_name，取其常量映射读 READY_TIMEOUT_SEC。
	var world_consts: Dictionary = (load("res://scripts/world.gd") as GDScript).get_script_constant_map()
	var ready_timeout: float = world_consts["READY_TIMEOUT_SEC"]
	var net_timeout := Api.GET_WORLD_TIMEOUT_SEC
	fails += _check("get_world 超时为正（有限，非 0=永不超时）", net_timeout > 0.0, true)
	fails += _check("get_world 超时 < 就绪硬超时（关瞬移窗口）", net_timeout < ready_timeout, true)

	# --- skinned_fraction：空槽 0、混合按比例、全铺 1 ---
	var cm := ChunkManager.new()
	fails += _check("空槽 fraction=0", cm.skinned_fraction(), 0.0)
	cm._slots = [
		{ "skinned": true }, { "skinned": false },
		{ "skinned": false }, { "skinned": true },
	]
	fails += _check("2/4 已铺 fraction=0.5", cm.skinned_fraction(), 0.5)
	for s in cm._slots:
		s["skinned"] = true
	fails += _check("全铺 fraction=1", cm.skinned_fraction(), 1.0)
	fails += _check("全铺时 all_skinned 亦为真", cm.all_skinned(), true)
	cm.free()

	# --- ready_progress 细粒度：boot 段随 _boot_sub 单调推进，消除长尾停顿 ---
	# 裸实例（不入树，只读方法用到的 _boot_stage/_boot_sub/_boot_status + chunk_manager==null 走 0）。
	var w: Node = (load("res://scripts/world.gd") as GDScript).new()
	w.set("chunk_manager", null) # 显式：无 chunk 时 chunk_f=0，进度只看 boot 段
	w.set("_boot_stage", 0)
	var p0: float = w.call("ready_progress")
	w.set("_boot_stage", 1); w.set("_boot_sub", 0.0)
	var p1a: float = w.call("ready_progress")
	w.set("_boot_sub", 0.5)
	var p1b: float = w.call("ready_progress")
	w.set("_boot_sub", 1.0)
	var p1c: float = w.call("ready_progress")
	w.set("_boot_stage", 2)
	var p2: float = w.call("ready_progress")
	fails += _check("stage0 起点=0.08", is_equal_approx(p0, 0.08), true)
	fails += _check("stage1 子进度单调推进（0<0.5<1）", p1a < p1b and p1b < p1c, true)
	fails += _check("stage1 sub=0 = 0.08+0.46*0.4", is_equal_approx(p1a, 0.08 + 0.46 * 0.4), true)
	fails += _check("stage1 sub=1 与 stage2 连续（无跳变）", is_equal_approx(p1c, p2), true)
	fails += _check("进度全程封顶 0.95", p2 <= 0.95, true)

	# --- ready_status：有文案返回文案；无文案回落铺设百分比 ---
	w.set("_boot_status", "")
	fails += _check("空文案回落铺草地", String(w.call("ready_status")).begins_with("铺草地"), true)
	w.set("_boot_status", "唤醒村民 2/3")
	fails += _check("有文案原样返回", String(w.call("ready_status")), "唤醒村民 2/3")
	w.free()

	# --- 慢网停滞检测：真进度只慢爬(非跟进)累计 >0.5s 才算停滞；恢复推进立刻解除 ---
	# 停滞是「笔尖蹭飞白 + 墨珠将滴未滴」的唯一触发信号(loading.gd _layout_trail/_layout_ink_drop)。
	var L: Node = (load("res://scripts/loading.gd") as GDScript).new()
	var sw := StubWorld.new()
	L.set("_world", sw)
	# 跟进分支：真进度领先 → _prog 追、停滞清零
	sw.p = 0.5; L.set("_prog", 0.0)
	L.call("_advance_progress", 0.1)
	fails += _check("真进度推进时不停滞", L.get("_stalled"), false)
	# 慢爬分支：真进度落在 _prog 后 → 累计 0.7s
	sw.p = 0.0; L.set("_prog", 0.6)
	for _i in 7:
		L.call("_advance_progress", 0.1)
	fails += _check("慢爬 >0.5s → 判定停滞", L.get("_stalled"), true)
	# 恢复：真进度跳到前面 → 停滞立刻解除、计时清零
	sw.p = 0.95
	L.call("_advance_progress", 0.1)
	fails += _check("真进度恢复 → 解除停滞", L.get("_stalled"), false)
	fails += _check("解除时停滞计时清零", is_equal_approx(L.get("_stall_t"), 0.0), true)
	# 落地/转场期不停滞（即便真进度停）
	sw.p = 0.0; L.set("_prog", 0.6); L.set("_landing", true)
	for _i in 7:
		L.call("_advance_progress", 0.1)
	fails += _check("落地期不判停滞（别在揭幕时蹭飞白）", L.get("_stalled"), false)
	sw.free()
	L.free()

	print("test_loading_progress: %d fail(s)" % fails)
	quit(fails)

## 桩世界：只提供 ready_progress()，喂给 loading._advance_progress 驱动停滞状态机。
## 必须 extends Node——loading.gd 的 _world 是强类型 Node，set() 一个 RefCounted 会被静默拒绝(留 null)。
class StubWorld extends Node:
	var p := 0.0
	func ready_progress() -> float:
		return p

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
