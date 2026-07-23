extends SceneTree
## 壁挂物品（home-wall-decor，docs/home-wall-decor-design.md）：
## - is_room_wall_edge 纯函数：房间周界墙边判定（后/左/右墙 = 真，前墙/内部/室外 = 假）
## - edge_sticker_pose 纯函数：墙边贴纸抬墙高、面朝屋内（yaw+180）、内移防穿墙；
##   非墙边/室外走贴地朝外（原行为）
## - chunk_manager 室内渲染烟测：周界墙边 seed 一张贴纸，set_room_bounds 后 _skin 不崩、
##   贴纸 MultiMesh 出现（headless MultiMesh transform 读不回，只断言 instance_count/存活）
## 运行: godot --headless --script res://test/test_wall_decor.gd

var fails := 0

func _init() -> void:
	TerrainMap.reset()
	OccupancyMap.clear()
	ItemCatalog.reset()
	ItemCatalog.ensure_builtin()

	var origin := Vector2i(19, 19)  # = world.gd ROOM_ORIGIN_TILE
	var n := 10                     # = world.gd ROOM_N → tiles [19..28]

	# ── is_room_wall_edge：三面墙 = 真 ─────────────────────────────────────
	_check("后墙：y==min 的 N 边",
		ChunkManager.is_room_wall_edge(Vector2i(23, 19), TerrainMap.EDGE_N, origin, n), true)
	_check("左墙：x==min 的 W 边",
		ChunkManager.is_room_wall_edge(Vector2i(19, 23), TerrainMap.EDGE_W, origin, n), true)
	_check("右墙：x==max 的 E 边",
		ChunkManager.is_room_wall_edge(Vector2i(28, 23), TerrainMap.EDGE_E, origin, n), true)
	_check("后墙沿整行都算（角点）",
		ChunkManager.is_room_wall_edge(Vector2i(19, 19), TerrainMap.EDGE_N, origin, n), true)

	# ── is_room_wall_edge：前墙（不建）/内部/错边/室外 = 假 ─────────────────
	_check("前墙 y==max 的 S 边不算墙（前墙不建）",
		ChunkManager.is_room_wall_edge(Vector2i(23, 28), TerrainMap.EDGE_S, origin, n), false)
	_check("内部 tile 的边不算墙",
		ChunkManager.is_room_wall_edge(Vector2i(23, 23), TerrainMap.EDGE_N, origin, n), false)
	_check("后墙行但取错边（S）不算",
		ChunkManager.is_room_wall_edge(Vector2i(23, 19), TerrainMap.EDGE_S, origin, n), false)
	_check("n<=0（无房间/室外）恒假",
		ChunkManager.is_room_wall_edge(Vector2i(23, 19), TerrainMap.EDGE_N, origin, 0), false)

	# ── edge_sticker_pose：室内墙边 → 抬墙高、面朝屋内 ─────────────────────
	var wall_center := ChunkManager.WALL_STICKER_CENTER - ChunkManager.STICKER_H * 0.5
	var back := ChunkManager.edge_sticker_pose(TerrainMap.EDGE_N, Vector2i(23, 19), true, origin, n)
	_approx("后墙贴纸抬到墙高中段", (back["off"] as Vector3).y, wall_center)
	_check("后墙贴纸面朝屋内（+z，yaw=0）", back["yaw"], 0.0)
	var left := ChunkManager.edge_sticker_pose(TerrainMap.EDGE_W, Vector2i(19, 23), true, origin, n)
	_approx("左墙贴纸抬到墙高中段", (left["off"] as Vector3).y, wall_center)
	_check("左墙贴纸面朝屋内（+x，yaw=90）", left["yaw"], 90.0)
	var right := ChunkManager.edge_sticker_pose(TerrainMap.EDGE_E, Vector2i(28, 23), true, origin, n)
	_check("右墙贴纸面朝屋内（-x，yaw=270）", right["yaw"], 270.0)
	# 墙边贴纸沿法线内移（往屋内），不外移进墙：后墙 z 从 -1（边）挪到 -0.95
	_check("后墙贴纸内移防穿墙（z 略大于边 -1）",
		1 if (back["off"] as Vector3).z > -1.0 and (back["off"] as Vector3).z < -0.9 else 0, 1)

	# ── edge_sticker_pose：室内非墙边 / 室外 → 贴地朝外（原行为）───────────
	var interior := ChunkManager.edge_sticker_pose(TerrainMap.EDGE_N, Vector2i(23, 23), true, origin, n)
	_approx("室内内部边仍贴地（未抬墙）", (interior["off"] as Vector3).y, ChunkManager.STICKER_LIFT)
	_check("室内内部边朝外 yaw 不翻", interior["yaw"], ChunkManager.EDGE_YAWS[TerrainMap.EDGE_N])
	var outdoor := ChunkManager.edge_sticker_pose(TerrainMap.EDGE_N, Vector2i(23, 19), false, origin, n)
	_approx("室外贴纸贴地（indoor=false 即使在周界坐标）", (outdoor["off"] as Vector3).y, ChunkManager.STICKER_LIFT)
	_check("室外贴纸朝外 yaw 不翻", outdoor["yaw"], ChunkManager.EDGE_YAWS[TerrainMap.EDGE_N])

	# ── 室内渲染烟测：周界墙边 seed 贴纸，_skin 不崩、出贴纸 MultiMesh ───────
	# tile (23,19) 后墙 N 边落在 wrapped 区块 (0,0)（CHUNK_TILES=25）。
	var p: Dictionary = TerrainMap.apply_patch({
		"paletteAppend": [{ "index": 1, "itemId": "sticker_sun" }],
		"edits": [{ "x": 23, "y": 19, "edge": [TerrainMap.EDGE_N, 1] }],
	})
	_check("墙边 edge patch 应用 ok", p["ok"], true)
	var cm := ChunkManager.new()
	var host := Node3D.new()
	root.add_child(host)
	host.add_child(cm)
	cm.set_terrain_hidden(true)               # 室内
	cm.set_room_bounds(origin, n)             # 告知房间周界
	var slot := {
		"tile": MeshInstance3D.new(), "water": MeshInstance3D.new(),
		"deco": Node3D.new(), "wrapped": Vector2i(0, 0), "skinned": false,
	}
	for k in ["tile", "water", "deco"]:
		host.add_child(slot[k])
	cm._skin(slot, Vector2i(0, 0))            # 不崩即过（下方再确认贴纸出现）
	var sticker_mmi: MultiMeshInstance3D = null
	for c in (slot["deco"] as Node3D).get_children():
		if c is MultiMeshInstance3D and (c as MultiMeshInstance3D).multimesh.mesh is QuadMesh:
			sticker_mmi = c
	_check("室内墙边重铺后出现贴纸 MultiMesh", sticker_mmi != null, true)
	if sticker_mmi != null:
		_check("单张墙贴合批为 1 实例", sticker_mmi.multimesh.instance_count, 1)

	TerrainMap.reset()
	ItemCatalog.reset()
	print("test_wall_decor: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	print("  FAIL %s: got %s want %s" % [what, str(got), str(want)])
	fails += 1
	return 1

func _approx(what: String, got: float, want: float) -> int:
	if absf(got - want) < 0.001:
		return 0
	print("  FAIL %s: got %s want %s" % [what, str(got), str(want)])
	fails += 1
	return 1
