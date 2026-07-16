extends SceneTree
## 跨场景引路（fairy-guide P3）：她把小朋友带到【门口】，他自己走进去（既有 _step_portal 触发，
## 没有任何传送下行报文），到了那边她接着领向最终目标。
##
## 验三件事：
##   ① 有 portal 段时，她领向的是【那道门】而不是最终目标（最终目标还在另一个场景，直着飞过去是错的）
##   ② 引路活过 _on_scene_entered（_unload_scene 不该把它清掉），落地后段号推进
##   ③ 走进计划外的门 → 引路作废（在错的场景里继续领只会把他带得更偏）
## 运行：scripts/test-headless.sh

const V_PORTAL := Vector2i(18, 52)   ## 村庄侧传送点（tools/export_terrain.gd）
const F_PORTAL := Vector2i(20, 18)   ## 森林侧传送点（tools/export_forest.gd）
const FAR_TILE := Vector2i(50, 8)    ## 离传送点远，用来武装触发器
const GOAL_TILE := Vector2i(60, 60)  ## 森林里的最终目标

var scene: Node
var frame := 0
var fails := 0
var lead_dot_portal := -1.0  ## 有 portal 段时，她领的方向与「玩家→门」的点积（应接近 1）

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _plan() -> Dictionary:
	return {
		"targetKind": "location",
		"targetName": "森林深处",
		"targetScene": "forest",
		"targetTile": { "tileX": GOAL_TILE.x, "tileY": GOAL_TILE.y },
		"legs": [{
			"sceneId": "village",
			"portalTile": { "tileX": V_PORTAL.x, "tileY": V_PORTAL.y },
			"toScene": "forest",
		}],
	}

func _place_player(tile: Vector2i) -> void:
	var player: Dictionary = scene.get("player")
	player["logical"] = TerrainMap.tile_center(tile)

## 把仙子摆到玩家身边（贴她的随身轨道）。否则她得先从老远飞回来，中途方向是反的，
## 领飞方向的断言会读到追赶途中的姿态而不是领路姿态。
func _park_fairy_near_player() -> void:
	var fairy: Dictionary = scene.call("_find_fairy")
	var player: Dictionary = scene.get("player")
	if fairy.is_empty() or player.is_empty():
		return
	fairy["logical"] = WorldGrid.wrap_pos(player["logical"] + Vector2(2.6, 1.8))

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
		scene.set("online", true)
		scene.set("_fairy_greeted", true)
		scene.set("_fairy_chat_t", 9999.0)
		scene.set("_poi_check_t", 9999.0)
		return

	match frame:
		10:
			var portals: Array = scene.call("parse_server_portals", [
				{ "tile": [V_PORTAL.x, V_PORTAL.y], "radius": 3.0, "toScene": "forest",
					"toTile": [F_PORTAL.x, F_PORTAL.y] }])
			scene.set("_portals", portals)
			_place_player(FAR_TILE)
			_park_fairy_near_player()
			scene.call("start_guide", _plan())
		22:
			# ① 目标在森林，但她该领向【村庄这边的门】——直着朝目标飞是错的
			var fairy: Dictionary = scene.call("_find_fairy")
			var player: Dictionary = scene.get("player")
			var to_fairy := WorldGrid.shortest_delta(player["logical"], fairy["logical"])
			var to_portal := WorldGrid.shortest_delta(player["logical"], TerrainMap.tile_center(V_PORTAL))
			if to_fairy.length() > 1.0:
				lead_dot_portal = to_fairy.normalized().dot(to_portal.normalized())
			_check("有 portal 段时领向那道门（dot=%.2f）" % lead_dot_portal, lead_dot_portal > 0.8, true)
			_check("引路仍在进行", not (scene.get("_fairy_guide") as Dictionary).is_empty(), true)
			_check("段号还在第 0 段", int((scene.get("_fairy_guide") as Dictionary).get("leg", -1)), 0)
			# 小朋友自己走进门（引路不碰他的 avatar）
			_place_player(V_PORTAL)
		26:
			# ② 服务端回包：到森林了。characters 传空——线上仙子会随 scene_entered 重新降生
			# （persistence.listCharacters 对仙子跨场景恒返回），这里离线，下面手动把她重建出来。
			scene.call("_on_scene_entered", {
				"sceneId": "forest",
				"scene": {
					"sceneId": "forest", "terrainAsset": "", "pois": [],
					"portals": [{ "tile": [F_PORTAL.x, F_PORTAL.y], "radius": 3.0,
						"toScene": "village", "toTile": [V_PORTAL.x, V_PORTAL.y] }],
				},
				"characters": [], "props": [],
			})
		36:
			var guide: Dictionary = scene.get("_fairy_guide")
			_check("引路活过换场景（_unload_scene 没把它清掉）", not guide.is_empty(), true)
			_check("落地后段号推进到 1", int(guide.get("leg", -1)), 1)
			# 换场景清空了 npcs：把离线仙子重建出来（线上她随 scene_entered 的 characters 回来）
			scene.call("_setup_fairy_offline")
			_place_player(FAR_TILE)
			_park_fairy_near_player()
		48:
			# 没有 portal 段了 → 她该领向最终目标
			var fairy2: Dictionary = scene.call("_find_fairy")
			var player2: Dictionary = scene.get("player")
			_check("换场景后仙子在场（否则下面的方向断言无意义）", not fairy2.is_empty(), true)
			var tf := WorldGrid.shortest_delta(player2["logical"], fairy2["logical"])
			var tg := WorldGrid.shortest_delta(player2["logical"], TerrainMap.tile_center(GOAL_TILE))
			var dot := -1.0
			if tf.length() > 1.0:
				dot = tf.normalized().dot(tg.normalized())
			_check("过门后改领向最终目标（dot=%.2f）" % dot, dot > 0.8, true)
			# ③ 走进计划外的门：引路该作废
			scene.call("_on_scene_entered", {
				"sceneId": "cave",  # 计划里没有的场景
				"scene": { "sceneId": "cave", "terrainAsset": "", "pois": [], "portals": [] },
				"characters": [], "props": [],
			})
		58:
			_check("走进计划外的门 → 引路作废", (scene.get("_fairy_guide") as Dictionary).is_empty(), true)
			var btn: Button = scene.get("guide_stop_button")
			_check("作废后按钮收起", btn == null or not btn.visible, true)
			if fails == 0:
				print("fairy_guide_portal PASS")
			else:
				printerr("fairy_guide_portal FAILED: %d" % fails)
			quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
