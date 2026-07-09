extends SceneTree
## 物品摆放+背包 world 层集成断言：语音造物落位 → 长按拾起（占地释放）→ 拖拽落地
## （prop_move 同步/占位目标弹回不发消息）→ 拖到收集册收纳（prop_store+物品页上架）
## → 物品页点击摆出（prop_take）→ 服务端 props 重载恢复（placed 落世界/bagged 留背包）。
## 离线 demo 世界，出站消息经 Backend.sent 信号捕获（与 test_visual_rewards 同路）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 120 --script res://test/test_visual_props.gd

## 静态小盒子 spec（locomotion none → wander 0，tile 不漂移，断言稳定）
const SPEC := {
	"name": "小盒子", "palette": ["#e8b04b"], "blend": 0.25, "outline": 0.04,
	"parts": [{ "shape": "box", "pos": [0, 0.5, 0], "size": [0.6, 0.6, 0.6], "color": 0 }],
	"locomotion": { "type": "none" }, "ropes": [],
}

var scene: Node
var frame := 0
var fails := 0
var sent: Array = []
var origin := Vector2i(-1, -1)  ## p1 造物落位 tile
var moved := Vector2i(-1, -1)   ## p1 拖拽后的 tile
var restore_tile := Vector2i(-1, -1)

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
		(scene.get("backend") as Backend).sent.connect(func(m: Dictionary) -> void: sent.append(m))
		scene.set("online", true) # 离线世界里放行 send_*（经 sent 信号观测）
		return
	var cm: ChunkManager = scene.get("chunk_manager")
	match frame:
		3:
			# 语音造物：玩家旁就近落位 + prop_place 回报 + world_props 登记
			scene.call("_on_prop_created", { "prop": { "id": "p1", "spec": SPEC } })
			var pl := _last_of("prop_place")
			_check("prop_place reported", String(pl.get("propId", "")), "p1")
			origin = Vector2i(int(pl.get("tileX", -1)), int(pl.get("tileY", -1)))
			_check("prop findable at tile", cm.dynamic_prop_at(origin), "p1")
			var wp: Dictionary = (scene.get("world_props") as Dictionary).get("p1", {})
			_check("world_props placed", String(wp.get("state", "")), "placed")
		5:
			# 长按拾起：候选到阈值转拖拽，占地释放、清单摘除
			scene.set("_prop_press_id", "p1")
			scene.call("_step_prop_press", 0.7)
			_check("drag begins on long press", (scene.get("_prop_drag") as Dictionary).is_empty(), false)
			_check("occupancy freed on pickup", OccupancyMap.prop_area_ok(origin, 1, 1), true)
			_check("picked prop off the list", cm.dynamic_prop_at(origin), "")
		7:
			# 拖拽落地：目标 tile 精确吸附 + prop_move 同步
			moved = _free_tile_near(origin + Vector2i(4, 0))
			var drag: Dictionary = scene.get("_prop_drag")
			drag["tile"] = moved
			scene.call("_end_prop_drag", Vector2(640, 60)) # 远离左下收集册按钮
			var mv := _last_of("prop_move")
			_check("prop_move sent", Vector2i(int(mv.get("tileX", -1)), int(mv.get("tileY", -1))), moved)
			_check("prop at new tile", cm.dynamic_prop_at(moved), "p1")
			_check("new tile occupied", OccupancyMap.prop_area_ok(moved, 1, 1), false)
		9:
			# 无位弹回：目标被占 → 回原位、不发 prop_move、横幅提示
			var before := _count_of("prop_move")
			scene.set("_prop_press_id", "p1")
			scene.call("_step_prop_press", 0.7)
			var blocked := _free_tile_near(moved + Vector2i(4, 4))
			OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(blocked), 2, 2)
			var drag: Dictionary = scene.get("_prop_drag")
			drag["tile"] = blocked
			scene.call("_end_prop_drag", Vector2(640, 60))
			_check("bounced back to origin", cm.dynamic_prop_at(moved), "p1")
			_check("no prop_move on bounce", _count_of("prop_move"), before)
			_check("banner explains no room", (scene.get("banner") as Label).text.contains("放不下"), true)
		11:
			# 收纳：拖到收集册按钮上松手 → prop_store + bagged + 从世界消失
			scene.set("_prop_press_id", "p1")
			scene.call("_step_prop_press", 0.7)
			var btn := scene.get("album_button") as Button
			scene.call("_end_prop_drag", btn.get_global_rect().get_center())
			_check("prop_store sent", String(_last_of("prop_store").get("propId", "")), "p1")
			var wp: Dictionary = (scene.get("world_props") as Dictionary).get("p1", {})
			_check("world_props bagged", String(wp.get("state", "")), "bagged")
			_check("prop gone from world", cm.dynamic_prop_at(moved), "")
			scene.call("_refresh_items_page")
		13:
			_check("items page lists bagged prop", (scene.get("_items_grid") as GridContainer).get_child_count(), 1)
			# 物品页摆出：prop_take + placed 回世界
			scene.call("_take_prop_out", "p1")
			var tk := _last_of("prop_take")
			_check("prop_take sent", String(tk.get("propId", "")), "p1")
			var back := Vector2i(int(tk.get("tileX", -1)), int(tk.get("tileY", -1)))
			_check("prop back in world", cm.dynamic_prop_at(back), "p1")
		15:
			# 重载恢复：placed 落世界原位，bagged 留背包不进世界
			restore_tile = _free_tile_near(origin + Vector2i(-5, -5))
			scene.call("_restore_world_props", [
				{ "id": "r1", "spec": SPEC, "state": "placed", "tile": [restore_tile.x, restore_tile.y] },
				{ "id": "r2", "spec": SPEC, "state": "bagged", "tile": null },
			])
			_check("restored placed prop in world", cm.dynamic_prop_at(restore_tile), "r1")
			var wps: Dictionary = scene.get("world_props")
			_check("restored bagged stays in bag", String((wps.get("r2", {}) as Dictionary).get("state", "")), "bagged")
			scene.call("_refresh_items_page")
		17:
			# 上一帧 queue_free 的旧格子已清，物品页应只剩 r2（p1 已摆出）
			_check("items page shows restored bagged", (scene.get("_items_grid") as GridContainer).get_child_count(), 1)
		20:
			if fails == 0:
				print("visual_props PASS")
			else:
				printerr("visual_props FAILED: %d" % fails)
			quit(fails)

## origin 附近找一个空闲 tile（螺旋外扩），断言用（保证目标本身可摆）。
func _free_tile_near(want: Vector2i) -> Vector2i:
	var n := WorldGrid.GRID_TILES
	for r in range(8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var t := Vector2i(posmod(want.x + dx, n), posmod(want.y + dy, n))
				if OccupancyMap.prop_area_ok(t, 1, 1):
					return t
	return want

func _last_of(type: String) -> Dictionary:
	for i in range(sent.size() - 1, -1, -1):
		if String((sent[i] as Dictionary).get("type", "")) == type:
			return sent[i]
	return {}

func _count_of(type: String) -> int:
	var c := 0
	for m in sent:
		if String((m as Dictionary).get("type", "")) == type:
			c += 1
	return c

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % what)
	else:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1
