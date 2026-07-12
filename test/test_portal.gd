extends SceneTree
## 传送点纯函数 + 全场景连通图对拍（scene-portal-graph）。
## 1) World.parse_server_portals：服务端载荷 → 运行期结构，坏条目跳过不连坐。
## 2) World.portal_hit：半径判定走环面最短距离（跨接缝也认）。
## 3) 13 个场景 build_portal_json() 组成连通图：每条边两端互指、场景内 tile 不重、
##    落点在各自地形上站得住（非水面、非高墙），且 BFS 从 village 可达全部 13 个场景。
## 运行: godot --headless --path . --script res://test/test_portal.gd

## sceneId → 导出脚本路径。village/forest 用现成脚本，11 主题各自的 export_<t>.gd。
const SCENE_SCRIPTS := {
	"village": "res://tools/export_terrain.gd",
	"forest": "res://tools/export_forest.gd",
	"seafloor": "res://tools/export_seafloor.gd",
	"icesnow": "res://tools/export_icesnow.gd",
	"jurassic": "res://tools/export_jurassic.gd",
	"medieval": "res://tools/export_medieval.gd",
	"roman": "res://tools/export_roman.gd",
	"ancient_china": "res://tools/export_ancient_china.gd",
	"modern_city": "res://tools/export_modern_city.gd",
	"future_robot": "res://tools/export_future_robot.gd",
	"hospital": "res://tools/export_hospital.gd",
	"kitchen": "res://tools/export_kitchen.gd",
	"toy_room": "res://tools/export_toy_room.gd",
}

func _init() -> void:
	var fails := 0
	var w: GDScript = load("res://scripts/world.gd")

	# ── parse_server_portals ─────────────────────────────────────────────
	var parsed: Array = w.parse_server_portals([
		{ "tile": [18, 52], "radius": 3.0, "toScene": "forest", "toTile": [20, 18] },
		{ "tile": [1, 1], "radius": 3.0, "toScene": "", "toTile": [2, 2] },      # 没目标场景
		{ "tile": [1, 1], "radius": 0.0, "toScene": "x", "toTile": [2, 2] },     # 半径非正
		{ "tile": [1], "radius": 3.0, "toScene": "x", "toTile": [2, 2] },        # tile 不是二元组
		{ "tile": [1, 1], "radius": 3.0, "toScene": "x", "toTile": [99, 2] },    # 落点越界
		"垃圾条目",
	])
	fails += _check("只留下唯一合法条目", parsed.size(), 1)
	if parsed.size() == 1:
		var p: Dictionary = parsed[0]
		fails += _check("tile 转 Vector2i", p["tile"], Vector2i(18, 52))
		fails += _check("to_tile 转 Vector2i", p["to_tile"], Vector2i(20, 18))
		fails += _check("to_scene", p["to_scene"], "forest")
		fails += _check("radius", p["radius"], 3.0)
	fails += _check("非数组载荷 → 空", (w.parse_server_portals("nope") as Array).size(), 0)
	fails += _check("缺 portals 字段 → 空", (w.parse_server_portals(null) as Array).size(), 0)

	# ── portal_hit：半径内命中，半径外落空 ────────────────────────────────
	var center := WorldGrid.from_tile_center(Vector2i(18, 52))
	fails += _check("站在中心命中", (w.portal_hit(parsed, center) as Dictionary).is_empty(), false)
	fails += _check("半径内命中", (w.portal_hit(parsed, center + Vector2(2.9, 0.0)) as Dictionary).is_empty(), false)
	fails += _check("半径外落空", (w.portal_hit(parsed, center + Vector2(3.2, 0.0)) as Dictionary).is_empty(), true)
	fails += _check("空表落空", (w.portal_hit([], center) as Dictionary).is_empty(), true)
	# 环面：传送点贴着接缝时，另一侧的玩家也应命中（shortest_delta 绕回）
	var seam: Array = w.parse_server_portals([
		{ "tile": [0, 0], "radius": 3.0, "toScene": "forest", "toTile": [20, 18] }])
	var across := WorldGrid.wrap_pos(WorldGrid.from_tile_center(Vector2i(0, 0)) - Vector2(2.0, 0.0))
	fails += _check("跨接缝仍命中", (w.portal_hit(seam, across) as Dictionary).is_empty(), false)

	# ── 收集全部 13 个场景的传送点 ────────────────────────────────────────
	var portals := {}  # sceneId → Array[Dictionary]
	for sid in SCENE_SCRIPTS.keys():
		var gd: GDScript = load(SCENE_SCRIPTS[sid])
		portals[sid] = gd.build_portal_json()

	# ── 每个场景 ~3 个 portal（toy_room 末梢 2 个）────────────────────────
	for sid in portals.keys():
		var m: int = (portals[sid] as Array).size()
		if sid == "toy_room":
			fails += _check("%s 传送点数 == 2" % sid, m, 2)
		else:
			fails += _check("%s 传送点数 >= 3" % sid, m >= 3, true)

	# ── 场景内 tile 互不重复（半径不重叠）────────────────────────────────
	for sid in portals.keys():
		var seen := {}
		for q in portals[sid]:
			var key := "%d,%d" % [int(q["tile"][0]), int(q["tile"][1])]
			fails += _check("%s tile %s 不重复" % [sid, key], seen.has(key), false)
			seen[key] = true

	# ── 每条边两端互指：S 的 portal→(T,toTile) 必有 T 的 portal{tile==toTile, toScene==S, toTile==本tile} ──
	for sid in portals.keys():
		for q in portals[sid]:
			var to_scene: String = String(q["toScene"])
			var to_tile := _tile(q["toTile"])
			var my_tile := _tile(q["tile"])
			fails += _check("%s→%s 目标场景存在" % [sid, to_scene], portals.has(to_scene), true)
			if not portals.has(to_scene):
				continue
			var matched := false
			for r in portals[to_scene]:
				if _tile(r["tile"]) == to_tile and String(r["toScene"]) == sid and _tile(r["toTile"]) == my_tile:
					matched = true
					break
			fails += _check("%s@%s→%s@%s 有反向互指" % [sid, my_tile, to_scene, to_tile], matched, true)

	# ── BFS 从 village 可达全部 13 个场景 ────────────────────────────────
	var reached := {"village": true}
	var queue := ["village"]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for q in portals[cur]:
			var nxt: String = String(q["toScene"])
			if portals.has(nxt) and not reached.has(nxt):
				reached[nxt] = true
				queue.append(nxt)
	fails += _check("BFS 从 village 可达场景数 == 13", reached.size(), portals.size())
	for sid in portals.keys():
		fails += _check("%s 从 village 可达" % sid, reached.has(sid), true)

	# ── 落点站得住：每个 portal tile 在其所在场景既非水面又非高墙（height<=2）──
	## height<=2 放行森林 knoll（顶面 h2），但拦下室内围墙(h3)/mound 峰顶(h3)——传送到墙上会卡死。
	for sid in portals.keys():
		_load_scene_terrain(sid)
		for q in portals[sid]:
			var t := _tile(q["tile"])
			fails += _check("%s 传送点 %s 不在水里" % [sid, t], _dry(t), true)
			fails += _check("%s 传送点 %s 不在高墙上(h<=2)" % [sid, t], TerrainMap.tile_height(t) <= 2, true)
	TerrainMap.reset()

	print("test_portal: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## 把指定场景的地形灌进 TerrainMap（village 用客户端确定性生成，其余用各自 build_terrain_bytes）。
func _load_scene_terrain(sid: String) -> void:
	if sid == "village":
		TerrainMap.reset()  # 客户端确定性村庄地形（== export_terrain 产出）
		return
	var gd: GDScript = load(SCENE_SCRIPTS[sid])
	var r: Dictionary = TerrainMap.load_from_bytes(gd.build_terrain_bytes())
	assert(r["ok"], "%s 地形载入失败: %s" % [sid, r.get("error", "")])

static func _tile(raw: Variant) -> Vector2i:
	var a: Array = raw
	return Vector2i(int(a[0]), int(a[1]))

## 该 tile 及其一圈邻居都不是水面（玩家落位会就近避让，但落点本身得是干地）
static func _dry(t: Vector2i) -> bool:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if TerrainMap.tile_type(t + Vector2i(dx, dz)) == TerrainMap.T_WATER:
				return false
	return true

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
