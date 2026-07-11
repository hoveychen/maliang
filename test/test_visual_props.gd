extends SceneTree
## 万物皆物品的拾摆链路 world 层集成断言（scene-items P5b）：
## 造物 item_created（实体入目录+背包+就地发 item_place）→ 模拟服务端 terrain_patch
## 落地（矩阵挂引用+派生占用+区块重铺）→ 长按拾起发 item_pickup → patch 清引用 +
## bag_update 回背包（物品页上架）→ 物品页点击再摆出 → 再次 patch 落地。
## 另验：内置物品（矩阵里的树）不可拾起、空 tile 不可拾起。
## 离线 demo 世界，出站消息经 Backend.sent 信号捕获，服务端行为用 _on_terrain_patch /
## _on_bag_update 手工注入（与真实广播同形）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 120 --script res://test/test_visual_props.gd

## 静态小盒子 spec（locomotion none → wander 0，tile 不漂移，断言稳定）
const SPEC := {
	"name": "小盒子", "palette": ["#e8b04b"], "blend": 0.25, "outline": 0.04,
	"parts": [{ "shape": "box", "pos": [0, 0.5, 0], "size": [0.6, 0.6, 0.6], "color": 0 }],
	"locomotion": { "type": "none" }, "ropes": [],
}

## 造物实体行（服务端 creationItemDef 同形）
const ITEM := {
	"id": "i1", "worldId": "default", "name": "小盒子", "renderRef": "sdf_inline",
	"spec": SPEC, "footprintW": 1, "footprintH": 1, "blocking": true, "pathOk": true, "wander": 0.0,
}

var scene: Node
var frame := 0
var fails := 0
var sent: Array = []
var place_tile := Vector2i(-1, -1)  ## 第一次摆放的 tile（item_place 请求携带）
var second_tile := Vector2i(-1, -1) ## 物品页再摆的 tile

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
	match frame:
		3:
			# 造物完成：实体入目录 + 背包一份 + 玩家旁找位发 item_place
			scene.call("_on_item_created", { "item": ITEM, "bag": { "i1": 1 } })
			_check("实体定义入目录", ItemCatalog.has_def("i1"), true)
			_check("背包同步一份", int((scene.get("bag") as Dictionary).get("i1", 0)), 1)
			var pl := _last_of("item_place")
			_check("item_place 已发出", String(pl.get("itemId", "")), "i1")
			place_tile = Vector2i(int(pl.get("tileX", -1)), int(pl.get("tileY", -1)))
			_check("落点可摆（本地预判过）", OccupancyMap.prop_area_ok(place_tile, 1, 1, true), true)
		5:
			# 模拟服务端确认：terrain_patch 挂引用 + bag_update 扣背包
			_apply_place_patch(place_tile)
			scene.call("_on_bag_update", { "bag": {} })
			_check("矩阵 tile 挂上实体引用", TerrainMap.tile_item_id(place_tile), "i1")
			_check("派生占用已登记", OccupancyMap.prop_area_ok(place_tile, 1, 1, true), false)
			_check("背包已扣空", int((scene.get("bag") as Dictionary).get("i1", 0)), 0)
		7:
			# 长按拾起：候选到阈值发 item_pickup（渲染等广播，本地不先动手）
			scene.set("_prop_press_tile", place_tile)
			scene.call("_step_prop_press", 0.7)
			var pk := _last_of("item_pickup")
			_check("item_pickup 已发出", Vector2i(int(pk.get("tileX", -1)), int(pk.get("tileY", -1))), place_tile)
			_check("矩阵未先斩后奏（等广播）", TerrainMap.tile_item_id(place_tile), "i1")
		9:
			# 模拟服务端确认：patch 清引用 + bag_update 回背包（收进册子横幅）
			_apply_pickup_patch(place_tile)
			scene.call("_on_bag_update", { "bag": { "i1": 1 } })
			_check("矩阵引用已清", TerrainMap.tile_item_id(place_tile), "")
			_check("占用已释放", OccupancyMap.prop_area_ok(place_tile, 1, 1, true), true)
			_check("背包回一份", int((scene.get("bag") as Dictionary).get("i1", 0)), 1)
			_check("横幅提示收进册子", (scene.get("banner") as Label).text.contains("收进"), true)
		11:
			_check("物品页上架背包物品", (scene.get("_items_grid") as GridContainer).get_child_count(), 1)
			# 物品页点击再摆出（克隆语义：同实体反复引用）
			scene.call("_place_bag_item", "i1")
			var pl := _last_of("item_place")
			second_tile = Vector2i(int(pl.get("tileX", -1)), int(pl.get("tileY", -1)))
			_check("再摆请求已发出", String(pl.get("itemId", "")), "i1")
			_check("再摆落点合法", second_tile.x >= 0, true)
		13:
			# 模拟服务端确认：第二次摆放落地（palette 已有 i1，不再扩）
			_apply_place_patch(second_tile)
			scene.call("_on_bag_update", { "bag": {} })
			_check("再摆落地", TerrainMap.tile_item_id(second_tile), "i1")
		15:
			# 上一帧 queue_free 的旧格子已清，此时才好数物品页
			_check("物品页清空", (scene.get("_items_grid") as GridContainer).get_child_count(), 0)
			# 拾起判定负例：内置物品（矩阵里的树/石）与空 tile 都不可拾
			var builtin_tile := _find_builtin_tile()
			if builtin_tile.x >= 0:
				_check("内置物品不可拾起", scene.call("_is_pickable_item", builtin_tile), false)
			else:
				_fail("打包矩阵里找不到内置物品（village.mltr 缺散布？）")
			var empty_tile := _free_tile_near(Vector2i(37, 37))
			_check("空 tile 不可拾起", scene.call("_is_pickable_item", empty_tile), false)
			_check("造物 tile 可拾起", scene.call("_is_pickable_item", second_tile), true)
		20:
			if fails == 0:
				print("visual_props PASS")
			else:
				printerr("visual_props FAILED: %d" % fails)
			quit(fails)

## 模拟服务端摆放广播：palette 无 i1 则 append，edits 挂引用；version 严格 +1。
func _apply_place_patch(tile: Vector2i) -> void:
	var pal := TerrainMap.palette()
	var ref := pal.find("i1") + 1
	var pal_add: Array = []
	if ref == 0:
		ref = pal.size() + 1
		pal_add = [{ "index": ref, "itemId": "i1" }]
	scene.call("_on_terrain_patch", {
		"sceneId": "village",
		"version": int(scene.get("_terrain_version")) + 1,
		"paletteAppend": pal_add,
		"items": [ITEM],
		"edits": [{ "x": tile.x, "y": tile.y, "item": [ref, 0] }],
	})

## 模拟服务端拾起广播：清 tile 引用。
func _apply_pickup_patch(tile: Vector2i) -> void:
	scene.call("_on_terrain_patch", {
		"sceneId": "village",
		"version": int(scene.get("_terrain_version")) + 1,
		"items": [],
		"edits": [{ "x": tile.x, "y": tile.y, "item": null }],
	})

## 打包矩阵里找一个挂着内置物品的 tile（worldId=null 的实体）。
func _find_builtin_tile() -> Vector2i:
	var n := WorldGrid.GRID_TILES
	for y in range(n):
		for x in range(n):
			var t := Vector2i(x, y)
			var id := TerrainMap.tile_item_id(t)
			if id.is_empty():
				continue
			var def := ItemCatalog.get_def(id)
			if not def.is_empty() and def.get("worldId") == null:
				return t
	return Vector2i(-1, -1)

## want 附近找一个空闲 tile（螺旋外扩），断言用。
func _free_tile_near(want: Vector2i) -> Vector2i:
	var n := WorldGrid.GRID_TILES
	for r in range(8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var t := Vector2i(posmod(want.x + dx, n), posmod(want.y + dy, n))
				if TerrainMap.tile_item_id(t).is_empty() and OccupancyMap.prop_area_ok(t, 1, 1):
					return t
	return want

func _last_of(type: String) -> Dictionary:
	for i in range(sent.size() - 1, -1, -1):
		if String((sent[i] as Dictionary).get("type", "")) == type:
			return sent[i]
	return {}

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % what)
	else:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1

func _fail(msg: String) -> void:
	printerr("  FAIL %s" % msg)
	fails += 1
