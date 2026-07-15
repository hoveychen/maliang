extends SceneTree
## 放置模式 world 层断言（placement-p1，docs/placement-interaction-design.md §3.1/§3.2）：
##  A) 纯判定：_yaw_to_arg 四档、_nearest_edge 就近吸边、_placement_legal 合法/占用/朝向;
##  B) 状态机：_begin_placement 进模式(幽灵+HUD)、_rotate_placement 转朝向(贴纸不转)、
##     _end_placement 退模式藏幽灵;
##  C) footprint 旋转：90/270 时 W/H 互换 → 合法性随朝向变。
## 不打网络（_confirm_placement 的 send_item_place 是 4 行胶水，靠读验证），只测新逻辑。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_placement.gd

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
	print("test_placement: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _run_checks() -> void:
	ItemCatalog.ensure_builtin()
	# 停执行器免得 wander 挪玩家、影响 _begin_placement 的默认落点
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()

	# ── A) 纯判定：_yaw_to_arg 四档（与服务端 yawToArg 同口径）─────────────────
	_check("yaw 0→arg 0", scene.call("_yaw_to_arg", 0.0), 0)
	_check("yaw 90→arg 64", scene.call("_yaw_to_arg", 90.0), 64)
	_check("yaw 180→arg 128", scene.call("_yaw_to_arg", 180.0), 128)
	_check("yaw 270→arg 192", scene.call("_yaw_to_arg", 270.0), 192)

	# ── A) _nearest_edge：点落在 tile 的哪个象限就吸哪条边（+x 东 +y 南）──────────
	scene.set("_place_tile", Vector2i(30, 30))
	var ts := WorldGrid.TILE_SIZE
	# tile(30,30) 中心 = (61, 61)；往东偏 → E，往北偏 → N
	_check("点偏东→吸 E 边", scene.call("_nearest_edge", Vector2(30.0 * ts + 1.9, 30.0 * ts + 1.0)), TerrainMap.EDGE_E)
	_check("点偏北→吸 N 边", scene.call("_nearest_edge", Vector2(30.0 * ts + 1.0, 30.0 * ts + 0.1)), TerrainMap.EDGE_N)
	_check("点偏南→吸 S 边", scene.call("_nearest_edge", Vector2(30.0 * ts + 1.0, 30.0 * ts + 1.9)), TerrainMap.EDGE_S)

	# ── 找一个非水陆地 tile 作合法性测试基准 ────────────────────────────────────
	var land := Vector2i(-1, -1)
	for y in range(20, 55):
		for x in range(20, 55):
			var t := Vector2i(x, y)
			if TerrainMap.tile_type(t) != TerrainMap.T_WATER and TerrainMap.tile_item_id(t).is_empty():
				land = t
				break
		if land.x >= 0:
			break
	_check("找到一块空陆地 tile", land.x >= 0, true)

	# ── B) 进入放置模式（贴纸）：幽灵与 HUD 亮起 ────────────────────────────────
	scene.set("online", true)
	scene.set("bag", { "sticker_sun": 1 })
	scene.call("_begin_placement", "sticker_sun")
	_check("进入放置模式", scene.get("_placing"), true)
	_check("识别为贴纸(edge)", scene.get("_place_is_edge"), true)
	_check("幽灵已建", scene.get("_place_ghost") != null, true)
	_check("HUD 亮起", (scene.get("_place_view") as Control).visible, true)

	# 贴纸转朝向无效（朝向由边法线定）
	scene.call("_rotate_placement")
	_check("贴纸「转一转」不改 yaw", scene.get("_place_yaw"), 0.0)

	# 贴纸合法性：空边合法，占用后非法
	scene.set("_place_tile", land)
	scene.set("_place_edge", TerrainMap.EDGE_S)
	scene.call("_refresh_place_ghost")
	_check("空边贴纸合法", scene.get("_place_legal"), true)
	var next := TerrainMap.palette().size() + 1 # 活世界 palette 已有条目，取下一个衔接 index
	_check("占边 patch 应用 ok", TerrainMap.apply_patch({
		"paletteAppend": [{ "index": next, "itemId": "sticker_sun" }],
		"edits": [{ "x": land.x, "y": land.y, "edge": [TerrainMap.EDGE_S, next] }],
	})["ok"], true)
	scene.call("_refresh_place_ghost")
	_check("同边已占→非法", scene.get("_place_legal"), false)

	scene.call("_end_placement")
	_check("退出放置模式", scene.get("_placing"), false)
	_check("退出后幽灵隐藏", (scene.get("_place_ghost") as MeshInstance3D).visible, false)

	# ── C) tile 物品 footprint 旋转：找一个非 1×1 内置物验证 W/H 互换 ────────────
	var wide_id := ""
	for id in _tile_item_ids():
		var fp: Vector2i = ItemCatalog.footprint(id, 0)
		if fp.x != fp.y:
			wide_id = id
			break
	if wide_id != "":
		var base: Vector2i = ItemCatalog.footprint(wide_id, scene.call("_yaw_to_arg", 0.0))
		var rot: Vector2i = ItemCatalog.footprint(wide_id, scene.call("_yaw_to_arg", 90.0))
		_check("footprint 90° 时 W/H 互换", rot, Vector2i(base.y, base.x))
	else:
		print("  (跳过 footprint 旋转：内置无非方形物)")

	# ── tile 物品合法性：占用 tile → 非法 ──────────────────────────────────────
	var one_id := _first_1x1_tile_item()
	if one_id != "":
		scene.set("bag", { one_id: 1 })
		scene.call("_begin_placement", one_id)
		_check("tile 物品进入放置模式", scene.get("_placing"), true)
		_check("识别为 tile 物品", scene.get("_place_is_edge"), false)
		# 找一块空陆地 → 合法
		var land2 := _find_empty_land()
		scene.set("_place_tile", land2)
		scene.set("_place_yaw", 0.0)
		scene.call("_refresh_place_ghost")
		_check("空陆地 tile 物品合法", scene.get("_place_legal"), true)
		# tile 物品「转一转」改 yaw
		scene.call("_rotate_placement")
		_check("tile 物品「转一转」yaw→90", scene.get("_place_yaw"), 90.0)
		# 占用该 tile → 非法
		var next2 := TerrainMap.palette().size() + 1
		_check("占 tile patch 应用 ok", TerrainMap.apply_patch({
			"paletteAppend": [{ "index": next2, "itemId": one_id }],
			"edits": [{ "x": land2.x, "y": land2.y, "item": [next2, 0] }],
		})["ok"], true)
		scene.set("_place_yaw", 0.0)
		scene.call("_refresh_place_ghost")
		_check("tile 已占→非法", scene.get("_place_legal"), false)
		scene.call("_end_placement")
	else:
		print("  (跳过 tile 物品合法性：内置无 1×1 物)")

	# ── D) 扔掉（背包重做 §5）：就近落地复用 item_place，捕获出站消息断言落点合法 ──────────
	# _throw_item 只发消息不打网（_send 在 ws 未连时仅 emit sent 信号），故连 backend.sent 捕获。
	var thrown: Array = []
	var cap := func(obj: Dictionary) -> void: thrown.append(obj)
	var be: Node = scene.get("backend")
	be.sent.connect(cap)

	# 空背包 → 不扔（无出站，物品留背包语义靠服务端，客户端此处直接早返回）
	scene.set("online", true)
	scene.set("bag", {})
	scene.call("_throw_item", "sticker_sun")
	_check("空背包扔掉=无出站", thrown.size(), 0)

	# 离线 → 不扔
	scene.set("online", false)
	scene.set("bag", { "sticker_sun": 1 })
	scene.call("_throw_item", "sticker_sun")
	_check("离线扔掉=无出站", thrown.size(), 0)

	# tile 物品：有货 + online → 发 item_place 到就近空 tile，无 edgeSide
	var throw_id := _first_1x1_tile_item()
	if throw_id != "":
		scene.set("online", true)
		scene.set("bag", { throw_id: 1 })
		thrown.clear()
		scene.call("_throw_item", throw_id)
		_check("扔 tile 物品=发 1 条", thrown.size(), 1)
		if thrown.size() == 1:
			var m: Dictionary = thrown[0]
			_check("消息类型 item_place", m.get("type"), "item_place")
			_check("扔的是该物品", m.get("itemId"), throw_id)
			_check("tile 物品无 edgeSide", m.has("edgeSide"), false)
			var t := Vector2i(int(m.get("tileX")), int(m.get("tileY")))
			_check("落点 tile 为空（可落地）", TerrainMap.tile_item_id(t).is_empty(), true)
	else:
		print("  (跳过扔 tile 物品：内置无 1×1 物)")

	# 贴纸：发 item_place 带 edgeSide（走边缘落地）
	thrown.clear()
	scene.set("bag", { "sticker_sun": 1 })
	scene.call("_throw_item", "sticker_sun")
	_check("扔贴纸=发 1 条", thrown.size(), 1)
	if thrown.size() == 1:
		var ms: Dictionary = thrown[0]
		_check("贴纸走 item_place", ms.get("type"), "item_place")
		_check("贴纸带 edgeSide", ms.has("edgeSide"), true)

	be.sent.disconnect(cap)

func _tile_item_ids() -> Array:
	var out := []
	ItemCatalog.ensure_builtin()
	for id in ItemCatalog._defs:
		if String((ItemCatalog._defs[id] as Dictionary).get("mount", "tile")) != "edge":
			out.append(String(id))
	out.sort()
	return out

func _first_1x1_tile_item() -> String:
	for id in _tile_item_ids():
		var fp: Vector2i = ItemCatalog.footprint(id, 0)
		var d: Dictionary = ItemCatalog.get_def(id)
		if fp == Vector2i(1, 1) and bool(d.get("blocking", true)):
			return id
	return ""

func _find_empty_land() -> Vector2i:
	for y in range(20, 55):
		for x in range(20, 55):
			var t := Vector2i(x, y)
			if TerrainMap.tile_type(t) != TerrainMap.T_WATER and TerrainMap.tile_item_id(t).is_empty():
				if OccupancyMap.prop_area_ok(t, 1, 1, false):
					return t
	return Vector2i(30, 30)

func _check(what: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	print("  FAIL %s: got %s want %s" % [what, str(got), str(want)])
	fails += 1
	return 1
