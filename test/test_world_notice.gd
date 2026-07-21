extends SceneTree
## 「主动看你」world 层断言(离线 demo 世界):
##  A) 纯判定 notice_ready:距离/走动/忙碌/冷却四门禁;
##  B) 集成:近身+站定+空闲的村民经 _update_npc_notice 被置 paper_action(挥手/点头)且转头朝玩家;
##  C) 远处不触发;走动中不触发(冷却保持到点等站定)。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_world_notice.gd

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	seed(12345)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
		return
	if (scene.get("player") as Dictionary).is_empty():
		return  # 等玩家就绪
	if frame < 4:
		return
	_run_checks()
	if fails == 0:
		print("world_notice PASS")
	else:
		printerr("world_notice FAILED: %d" % fails)
	quit(fails)

func _run_checks() -> void:
	# A) 纯判定
	_check("近身站定空闲冷却到点→触发", scene.call("notice_ready", 3.0, 0.0, false, 0.0), true)
	_check("冷却未到→不触发", scene.call("notice_ready", 3.0, 0.0, false, 1.0), false)
	_check("超出半径→不触发", scene.call("notice_ready", 20.0, 0.0, false, 0.0), false)
	_check("走动中→不触发", scene.call("notice_ready", 3.0, 0.5, false, 0.0), false)
	_check("忙碌(选中/聊天/动作中)→不触发", scene.call("notice_ready", 3.0, 0.0, true, 0.0), false)
	# 体型缩放注意半径（character-size）：基准 6.5m。大角色(1.4→9.1m)在 8m 处触发；小角色(0.7→4.55m)在 5m 处不触发。
	_check("大体型 8m→在放大半径内触发", scene.call("notice_ready", 8.0, 0.0, false, 0.0, 1.4), true)
	_check("默认体型 8m→超基准半径不触发", scene.call("notice_ready", 8.0, 0.0, false, 0.0, 1.0), false)
	_check("小体型 5m→缩小半径外不触发", scene.call("notice_ready", 5.0, 0.0, false, 0.0, 0.7), false)

	# 停掉所有执行器,免得 wander 在断言间挪动村民
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()
	var npcs: Array = scene.get("npcs")
	var npc := {}
	for n in npcs:
		if not n.get("is_fairy", false):
			npc = n
			break
	if npc.is_empty():
		_check("找到一个非仙子村民", false, true)
		return
	var pl: Vector2 = (scene.get("player") as Dictionary)["logical"]

	# B) 近身(玩家在村民右侧 3m)+站定+空闲+冷却到点 → 触发,转头朝右(face=0)
	npc["logical"] = WorldGrid.wrap_pos(pl + Vector2(-3.0, 0.0)) # 村民在玩家左边→村民朝右看玩家
	npc["paper_walk"] = 0.0
	npc["notice_cd"] = 0.0
	npc.erase("paper_action")
	scene.call("_update_npc_notice", 0.016)
	var act := String(npc.get("paper_action", ""))
	_check("近身空闲村民被置打招呼动作", act == "wave" or act == "nod", true)
	_check("转头朝玩家(玩家在右→face=0)", float(npc.get("paper_face", -1.0)), 0.0)
	_check("触发后冷却被重置为正", float(npc.get("notice_cd", 0.0)) > 0.0, true)
	var bub := npc.get("notice_bubble") as Sprite3D
	_check("头顶小表情气泡已弹出可见", bub != null and bub.visible, true)

	# C1) 远处(20m)→不触发
	npc["logical"] = WorldGrid.wrap_pos(pl + Vector2(20.0, 0.0))
	npc["paper_walk"] = 0.0
	npc["notice_cd"] = 0.0
	npc.erase("paper_action")
	scene.call("_update_npc_notice", 0.016)
	_check("远处村民不打招呼", npc.get("paper_action", ""), "")

	# C2) 近身但走动中→不触发,冷却保持到点(=0)等站定
	npc["logical"] = WorldGrid.wrap_pos(pl + Vector2(-3.0, 0.0))
	npc["paper_walk"] = 0.5
	npc["notice_cd"] = 0.0
	npc.erase("paper_action")
	scene.call("_update_npc_notice", 0.016)
	_check("走动中村民不打招呼", npc.get("paper_action", ""), "")
	_check("走动中冷却保持到点(0)等站定", float(npc.get("notice_cd", -1.0)), 0.0)

	# D) tap 即时反馈层(interaction-feedback P1):点中村民 → 头顶立即冒表情泡,不等走到、不等服务端。
	# 红/绿护栏:改动前 _tap_pick 命中 NPC 只 _approach_npc、不 pop 气泡,故清掉残留后应再冒出。
	var cam := scene.get("camera") as Camera3D
	var pnode := ((scene.get("player") as Dictionary).get("node")) as Node3D
	var nnode := npc.get("node") as Node3D
	if cam == null or pnode == null or nnode == null:
		_check("tap-feedback 前置:相机/玩家/村民节点就绪", false, true)
		return
	# 把村民摆到玩家跟前(必在相机视野内),清掉 B 段残留气泡,确认这次 pop 由本次 tap 触发。
	nnode.global_position = pnode.global_position + Vector3(1.5, 0.0, 0.0)
	var old_bub := npc.get("notice_bubble") as Sprite3D
	if old_bub != null:
		old_bub.visible = false
	var head := nnode.global_position + Vector3(0.0, 1.6, 0.0)
	_check("tap-feedback:村民头顶未被相机背面剔除", cam.is_position_behind(head), false)
	var screen: Vector2 = cam.unproject_position(head)
	_check("tap-feedback:点该屏幕点命中的正是该村民", scene.call("_pick_npc", screen) == nnode, true)
	scene.call("_tap_pick", screen)
	var bub2 := npc.get("notice_bubble") as Sprite3D
	_check("tap-feedback:点中村民后头顶表情泡立即弹出可见", bub2 != null and bub2.visible, true)

	# E) 点不可进建筑 → 点点飞过去解释,不走玩家(interaction-feedback B 档路由护栏)。
	var fairy: Dictionary = scene.call("_find_fairy")
	if fairy.is_empty():
		_check("explain-building 前置:离线世界有小仙子", false, true)
		return
	var htile := Vector2i(40, 40)
	var hground: Vector2 = WorldGrid.from_tile_center(htile)
	# 空静态层:任何空地都不该被点点接管——否则孩子永远走不动路(负面护栏)。
	OccupancyMap.clear()
	scene.set("_fairy_guide", {})
	scene.set("_fairy_poi", {})
	_check("explain-building:空地不接管(返回 false,照常走过去)", scene.call("_try_explain_building", hground), false)
	# 整层置静态 = 该 ground 落在建筑里;homes 内 → 家的台词。
	var sc := PackedByteArray(); sc.resize(OccupancyMap.CELLS * OccupancyMap.CELLS); sc.fill(1)
	OccupancyMap.load_static(sc)
	scene.set("_homes", { htile: "bear" })
	scene.set("_fairy_poi", {})
	_check("explain-building:点建筑被点点接管(返回 true)", scene.call("_try_explain_building", hground), true)
	var poi: Dictionary = scene.get("_fairy_poi")
	_check("explain-building:接管后 _fairy_poi 已设(点点将飞过去说)", not poi.is_empty(), true)
	_check("explain-building:homes 内建筑→说家的台词", String(poi.get("trigger", "")), "house_locked")
	# 不在 homes 的建筑 → 通用布景台词。
	scene.set("_homes", {})
	scene.set("_fairy_poi", {})
	scene.call("_try_explain_building", hground)
	_check("explain-building:非 homes 建筑→说布景台词", String((scene.get("_fairy_poi") as Dictionary).get("trigger", "")), "prop_scenery")
	# 引路中不接管:她一次只做一件事。
	scene.set("_fairy_guide", { "plan": {} })
	_check("explain-building:引路中不接管(返回 false)", scene.call("_try_explain_building", hground), false)
	scene.set("_fairy_guide", {})
	OccupancyMap.clear()

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [str(name), str(got), str(want)])
