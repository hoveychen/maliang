extends SceneTree
## 传送点端到端冲烟（scene-portal P6）：踏进半径 → 黑幕淡入 → 全黑才发 enter_scene →
## 喂 scene_entered 卸旧载新 → 落到传送点出口 → 区块铺完淡出 → 站在返回传送点上不反弹 →
## 走出去再回来能二次传送。
## 离线世界 + 合成 portals（scene.terrainAsset 留空，绕开地形网络拉取）；出站消息经 Backend.sent 观测。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 90 --script res://test/test_visual_portal.gd

const V_PORTAL := Vector2i(18, 52)  ## 村庄侧传送点（tools/export_terrain.gd）
const F_PORTAL := Vector2i(20, 18)  ## 森林侧传送点（tools/export_forest.gd）
const FAR_TILE := Vector2i(50, 8)   ## 离两个传送点都远，用来「走出半径」重新武装

var scene: Node
var frame := 0
var fails := 0
var sent: Array = []

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
		10:
			# 村庄场景的传送点就位；玩家先待在远处，让 _step_portal 把触发器武装起来
			var portals: Array = scene.call("parse_server_portals", [
				{ "tile": [V_PORTAL.x, V_PORTAL.y], "radius": 3.0, "toScene": "forest",
					"toTile": [F_PORTAL.x, F_PORTAL.y] }])
			_check("portals 解析出 1 个", portals.size(), 1)
			scene.set("_portals", portals)
			_place_player(FAR_TILE)
		12:
			_check("远离传送点后触发器已武装", scene.get("_portal_armed"), true)
			_check("尚未开始过场", scene.get("_transitioning"), false)
			_place_player(V_PORTAL) # 踏进传送点
		14:
			# 触发即刻：过场已开始，但黑幕还没全黑，报文必须还没发出去
			_check("踏进传送点 → 过场开始", scene.get("_transitioning"), true)
			_check("黑幕未全黑时不发报文", _count("enter_scene"), 0)
			_check("黑幕正在淡入", float(scene.get("_fade_a")) > 0.0, true)
		20:
			# FADE_TIME=0.35s @10fps → 4 帧内全黑，报文随即发出
			_check("全黑后发出 enter_scene", _count("enter_scene"), 1)
			_check("enter_scene 目标是 forest", String(_last_of("enter_scene").get("sceneId", "")), "forest")
			_check("黑幕全黑", is_equal_approx(float(scene.get("_fade_a")), 1.0), true)
		22:
			# 服务端回包：森林场景（带回程传送点），没有 playerPos——落点应取 portal 出口
			scene.call("_on_scene_entered", {
				"sceneId": "forest",
				"scene": {
					"sceneId": "forest", "terrainAsset": "", "pois": [],
					"portals": [{ "tile": [F_PORTAL.x, F_PORTAL.y], "radius": 3.0,
						"toScene": "village", "toTile": [V_PORTAL.x, V_PORTAL.y] }],
				},
				"characters": [], "props": [],
			})
		30:
			_check("_scene_id 切到 forest", String(scene.get("_scene_id")), "forest")
			_check("玩家落在传送点出口", _player_dist(F_PORTAL) <= 3, true)
			var portals: Array = scene.get("_portals")
			_check("换上森林的回程传送点", portals.size(), 1)
			_check("回程通往 village", String((portals[0] as Dictionary)["to_scene"]), "village")
			# 站在回程传送点上不该被立刻弹回去（走出半径才重新武装）
			_check("落地站在回程传送点上，未再次触发", _count("enter_scene"), 1)
			_check("触发器仍未武装", scene.get("_portal_armed"), false)
			# 区块铺完后黑幕撤走
			_check("过场已收尾", scene.get("_transitioning"), false)
			_check("黑幕已淡出", is_equal_approx(float(scene.get("_fade_a")), 0.0), true)
		34:
			_place_player(FAR_TILE) # 走出半径
		36:
			_check("走出半径后重新武装", scene.get("_portal_armed"), true)
			_place_player(F_PORTAL) # 再踏进回程传送点
		44:
			_check("二次传送发出 enter_scene", _count("enter_scene"), 2)
			_check("这次目标是 village", String(_last_of("enter_scene").get("sceneId", "")), "village")
			if fails == 0:
				print("visual_portal PASS")
			else:
				printerr("visual_portal FAILED: %d" % fails)
			quit(fails)

func _place_player(tile: Vector2i) -> void:
	var p: Dictionary = scene.get("player")
	if p.is_empty():
		printerr("  FAIL 没有玩家节点")
		fails += 1
		return
	p["logical"] = WorldGrid.from_tile_center(tile)

func _player_dist(tile: Vector2i) -> int:
	var pt := WorldGrid.to_tile((scene.get("player") as Dictionary)["logical"])
	var n := WorldGrid.GRID_TILES
	var dx := absi(pt.x - tile.x)
	var dy := absi(pt.y - tile.y)
	return maxi(mini(dx, n - dx), mini(dy, n - dy))

func _count(type: String) -> int:
	var c := 0
	for m in sent:
		if String((m as Dictionary).get("type", "")) == type:
			c += 1
	return c

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
