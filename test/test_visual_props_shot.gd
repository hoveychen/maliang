extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：万物皆物品拾摆链路演练。
## 离线 demo 世界直驱内部接口并手工注入服务端广播：造物 item_created（发 item_place）→
## 注入 terrain_patch 落地（矩阵物品层渲染）→ 长按拾起（item_pickup）→ 注入 patch 清引用
## + bag_update 回背包 → 打开物品页 → 点 🎁 再摆出 → 注入 patch 第二次落地。
## 运行（带窗录像，勿改 root.size——会冻结截帧）:
##   MALIANG_API_BASE=http://127.0.0.1:1 godot --path . --write-movie <目录>/props.png \
##     --fixed-fps 8 --quit-after 240 --script res://test/test_visual_props_shot.gd

const SPEC := {
	"name": "小盒子", "palette": ["#e8b04b", "#f4ead4"], "blend": 0.25, "outline": 0.04,
	"parts": [
		{ "shape": "box", "pos": [0, 0.5, 0], "size": [0.7, 0.6, 0.6], "color": 0 },
		{ "shape": "sphere", "pos": [0, 1.0, 0.15], "r": 0.2, "color": 1, "blend": 0.15 },
	],
	"locomotion": { "type": "none" }, "ropes": [],
}
const ITEM := {
	"id": "p1", "worldId": "default", "name": "小盒子", "renderRef": "sdf_inline",
	"spec": SPEC, "footprintW": 1, "footprintH": 1, "blocking": true, "pathOk": true, "wander": 0.0,
}

var scene: Node
var frame := 0
var place_tile := Vector2i(-1, -1)

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _last_place_tile() -> Vector2i:
	return place_tile

func _apply_place_patch(tile: Vector2i) -> void:
	var pal := TerrainMap.palette()
	var ref := pal.find("p1") + 1
	var pal_add: Array = []
	if ref == 0:
		ref = pal.size() + 1
		pal_add = [{ "index": ref, "itemId": "p1" }]
	scene.call("_on_terrain_patch", {
		"sceneId": "village",
		"version": int(scene.get("_terrain_version")) + 1,
		"paletteAppend": pal_add, "items": [ITEM],
		"edits": [{ "x": tile.x, "y": tile.y, "item": [ref, 0] }],
	})

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		scene.set("online", true)
		(scene.get("backend") as Backend).sent.connect(func(m: Dictionary) -> void:
			if String(m.get("type", "")) == "item_place":
				place_tile = Vector2i(int(m.get("tileX", -1)), int(m.get("tileY", -1))))
		return
	match frame:
		20:
			scene.call("_on_item_created", { "item": ITEM, "bag": { "p1": 1 } })
			print("[qa] f20 造物请求落点 tile=", place_tile)
		30:
			_apply_place_patch(place_tile)
			scene.call("_on_bag_update", { "bag": {} })
			print("[qa] f30 落地 item=", TerrainMap.tile_item_id(place_tile))
		80:
			scene.set("_prop_press_tile", place_tile)
			scene.call("_step_prop_press", 0.7)
			print("[qa] f80 长按拾起请求已发")
		95:
			scene.call("_on_terrain_patch", {
				"sceneId": "village", "version": int(scene.get("_terrain_version")) + 1,
				"items": [], "edits": [{ "x": place_tile.x, "y": place_tile.y, "item": null }],
			})
			scene.call("_on_bag_update", { "bag": { "p1": 1 } })
			print("[qa] f95 拾进背包 item@tile=", TerrainMap.tile_item_id(place_tile))
		140:
			scene.call("_toggle_album")
			scene.call("_open_app", "items") # 手机物品 app
		180:
			scene.call("_place_bag_item", "p1")
			print("[qa] f180 再摆请求落点 tile=", place_tile)
		195:
			_apply_place_patch(place_tile)
			scene.call("_on_bag_update", { "bag": {} })
			print("[qa] f195 再摆落地 item=", TerrainMap.tile_item_id(place_tile))
