extends SceneTree
## 换场景 world 层集成断言（scene-portal P4）：_on_scene_entered 卸旧场景、载新场景。
## 离线 demo 世界（村庄占位角色 + 一个语音物件），喂一条合成的 scene_entered（目标 forest，
## scene=null 免地形网络拉取）→ 断言：旧角色/语音物件清空、新角色降生、world_props 清空、
## 运行期 _scene_id 切到 forest、玩家按 playerPos 落位、出站 world_info 带新 sceneId。
## 出站消息经 Backend.sent 捕获（与 test_visual_props 同路）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_visual_scene_switch.gd

const SPEC := {
	"name": "小盒子", "palette": ["#e8b04b"], "blend": 0.25, "outline": 0.04,
	"parts": [{ "shape": "box", "pos": [0, 0.5, 0], "size": [0.6, 0.6, 0.6], "color": 0 }],
	"locomotion": { "type": "none" }, "ropes": [],
}

var scene: Node
var frame := 0
var fails := 0
var sent: Array = []
var dp_tile := Vector2i(-1, -1)
var old_ids: Array = []
var target_tile := Vector2i(-1, -1)

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
		10:
			# 基线：村庄占位角色在场、_scene_id=village；埋一个语音物件验证换场景会清掉
			var npcs: Array = scene.get("npcs")
			_check("换场景前有占位角色", npcs.size() > 0, true)
			_check("初始 _scene_id=village", String(scene.get("_scene_id")), "village")
			for n in npcs:
				if not bool(n.get("is_fairy", false)):
					old_ids.append(String(n.get("id", "")))
			dp_tile = _free_tile_near(Vector2i(40, 20))
			cm.add_dynamic_prop(SPEC, dp_tile, 0.0, 0.0, "dp1")
			_check("语音物件已落位", cm.dynamic_prop_at(dp_tile), "dp1")
			(scene.get("world_props") as Dictionary)["dp1"] = { "spec": SPEC, "state": "placed", "tile": [dp_tile.x, dp_tile.y] }
			target_tile = _free_tile_near(Vector2i(18, 58))
		12:
			# 换场景：目标 forest，两个新角色，scene=null（不拉地形，避开网络），玩家落到 target_tile
			scene.call("_on_scene_entered", {
				"sceneId": "forest",
				"scene": null,
				"characters": [
					{ "id": "tree-1", "name": "松松", "appearance": {} },
					{ "id": "tree-2", "name": "杉杉", "appearance": {} },
				],
				"props": [],
				"playerPos": { "tileX": target_tile.x, "tileY": target_tile.y },
			})
		16:
			# 卸旧载新落定
			_check("_scene_id 切到 forest", String(scene.get("_scene_id")), "forest")
			var npcs: Array = scene.get("npcs")
			var ids: Array = []
			for n in npcs:
				ids.append(String(n.get("id", "")))
			_check("新场景角色 tree-1 在场", ids.has("tree-1"), true)
			_check("新场景角色 tree-2 在场", ids.has("tree-2"), true)
			var old_gone := true
			for oid in old_ids:
				if ids.has(oid):
					old_gone = false
			_check("旧场景角色全部卸载", old_gone, true)
			_check("旧语音物件已清（换场景不带入新场景）", cm.dynamic_prop_at(dp_tile), "")
			_check("world_props 已清空", (scene.get("world_props") as Dictionary).is_empty(), true)
			# 玩家按 playerPos 落位（就近找空位，目标本身空则原位）
			var ptile: Vector2i = WorldGrid.to_tile((scene.get("player") as Dictionary)["logical"])
			_check("玩家落到 playerPos 附近", _tile_dist(ptile, target_tile) <= 3, true)
			# 换场景后向服务端重报 world_info，带新 sceneId
			var wi := _last_of("world_info")
			_check("重报 world_info 带新 sceneId", String(wi.get("sceneId", "")), "forest")
		20:
			if fails == 0:
				print("visual_scene_switch PASS")
			else:
				printerr("visual_scene_switch FAILED: %d" % fails)
			quit(fails)

func _tile_dist(a: Vector2i, b: Vector2i) -> int:
	var n := WorldGrid.GRID_TILES
	var dx := absi(a.x - b.x)
	var dy := absi(a.y - b.y)
	return maxi(mini(dx, n - dx), mini(dy, n - dy))

func _free_tile_near(want: Vector2i) -> Vector2i:
	var n := WorldGrid.GRID_TILES
	for r in range(10):
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

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % what)
	else:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1
