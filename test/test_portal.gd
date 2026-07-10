extends SceneTree
## 传送点纯函数 + 两张地图的传送点数据对拍（scene-portal P6）。
## 1) World.parse_server_portals：服务端载荷 → 运行期结构，坏条目跳过不连坐。
## 2) World.portal_hit：半径判定走环面最短距离（跨接缝也认）。
## 3) village ↔ forest 的 build_portal_json() 必须互指，且落点在各自地形上站得住（非水面）。
## 运行: godot --headless --path . --script res://test/test_portal.gd

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

	# ── 两张图的传送点必须互指 ────────────────────────────────────────────
	var village: GDScript = load("res://tools/export_terrain.gd")
	var forest: GDScript = load("res://tools/export_forest.gd")
	var vp: Array = village.build_portal_json()
	var fp: Array = forest.build_portal_json()
	fails += _check("村庄一个传送点", vp.size(), 1)
	fails += _check("森林一个传送点", fp.size(), 1)
	var v: Dictionary = vp[0]
	var f: Dictionary = fp[0]
	fails += _check("村庄传送点通往 forest", v["toScene"], "forest")
	fails += _check("森林传送点通往 village", f["toScene"], "village")
	fails += _check("村庄落点 == 森林传送点所在", v["toTile"], f["tile"])
	fails += _check("森林落点 == 村庄传送点所在", f["toTile"], v["tile"])

	# ── 落点在各自地形上站得住（水面上的传送点＝掉进水里出不来）────────────
	TerrainMap.reset() # 回到客户端确定性生成的村庄地形
	fails += _check("村庄传送点不在水里", _dry(_tile(v["tile"])), true)
	fails += _check("村庄落点（森林那侧回来的落脚处）不在水里", _dry(_tile(f["toTile"])), true)
	var r := TerrainMap.load_from_bytes(forest.build_terrain_bytes())
	fails += _check("森林地形载入成功", r["ok"], true)
	fails += _check("森林传送点不在水里", _dry(_tile(f["tile"])), true)
	fails += _check("森林落点（村庄那侧过来的落脚处）不在水里", _dry(_tile(v["toTile"])), true)
	TerrainMap.reset()

	print("test_portal: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

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
