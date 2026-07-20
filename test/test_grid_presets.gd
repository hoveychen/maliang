extends SceneTree
## GRID_TILES 预设尺寸端到端（gridtiles-presets P5）：非 75 尺寸场景全链不崩。
## 对每个预设 50/75/100 走一遍：造该尺寸空地形 → load_from_bytes 按地形头自配
## WorldGrid（GRID_TILES/WORLD_SPAN）→ occupancy CELLS=2·g、快照自包含 cell 数 →
## chunk 常驻槽 (g/25)²（50→4 / 75→9 / 100→16）且边角区块网格可建 → 坐标/占用边角
## 不越界。100 格的 4×4 偶数边是旧「奇数窗口」设计过不去的坎，这里正是它的回归。
## 运行: godot --headless --path . --script res://test/test_grid_presets.gd

const HEADER := 11

var fails := 0

func _init() -> void:
	for g in [50, 75, 100]:
		_run_preset(g)

	# 收尾：复位到默认 75，免污染同进程后续（各测试本是独立进程，双保险）。
	WorldGrid.configure(75)
	TerrainMap.reset()
	OccupancyMap.clear()

	print("test_grid_presets: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _run_preset(g: int) -> void:
	TerrainMap.reset()
	OccupancyMap.clear()
	ItemCatalog.reset()
	ItemCatalog.ensure_builtin()

	# ── 载入 g×g 地形 → 地形头自描述网格，自动 configure WorldGrid ──────────────
	var r: Dictionary = TerrainMap.load_from_bytes(_flat_grass_bytes(g))
	_check("g=%d 载入 ok" % g, r["ok"], true)
	_check("g=%d WorldGrid.GRID_TILES 自配" % g, WorldGrid.GRID_TILES, g)
	_check("g=%d WORLD_SPAN=g·TILE_SIZE" % g, WorldGrid.WORLD_SPAN, float(g) * WorldGrid.TILE_SIZE)
	# 边角 tile 可读（全草地）——数组按 g 分配，不越界
	_check("g=%d 边角 tile=草" % g, TerrainMap.tile_type(Vector2i(g - 1, g - 1)), TerrainMap.T_GRASS)
	_check("g=%d is_valid_tile 边角合法" % g, WorldGrid.is_valid_tile(Vector2i(g - 1, g - 1)), true)
	_check("g=%d is_valid_tile 越界拒" % g, WorldGrid.is_valid_tile(Vector2i(g, 0)), false)

	# ── 占用图随网格 ────────────────────────────────────────────────────────
	ItemCatalog.apply_static_occupancy()   # 顶部 sync_grid → CELLS 同步到 2g
	_check("g=%d OccupancyMap.CELLS=2g" % g, OccupancyMap.CELLS, g * 2)
	var far := OccupancyMap.tile_to_cell(Vector2i(g - 1, g - 1))
	_check("g=%d 边角半格空闲(空地形)" % g, OccupancyMap.is_free_rect(far, 2, 2), true)
	# 快照自包含 cell 数（worker 侧不读全局 GRID_TILES）
	var snap := OccupancyMap.snapshot()
	_check("g=%d 快照 _cells=2g" % g, snap._cells, g * 2)

	# ── chunk 常驻槽随网格（rebuild 触发 _ensure_slots，裸实例即可）──────────────
	var cm := ChunkManager.new()
	cm.rebuild()
	var cps := g / 25
	_check("g=%d 常驻槽数=(g/25)²" % g, cm._slots.size(), cps * cps)
	_check("g=%d _chunks_per_side=g/25" % g, cm._chunks_per_side, cps)
	# 边角 wrapped 区块地面网格可建（大尺寸不越界不崩）——100 格才有 wrapped=(3,3)
	var corner := Vector2i(cps - 1, cps - 1)
	var m: ArrayMesh = cm._chunk_mesh(corner)
	_check("g=%d 边角区块(%d,%d)网格非空" % [g, corner.x, corner.y], m != null and m.get_surface_count() > 0, true)
	cm.free()

## 合法但全草地、全高度 0、无水深的平坦 g×g .mltr（v1，头部同 export_terrain.gd）。
func _flat_grass_bytes(g: int) -> PackedByteArray:
	var count := g * g
	var buf := PackedByteArray()
	buf.resize(HEADER + 3 * count) # v1：resize 清零 = 全草(0)/高度0/深度0
	for i in range(4):
		buf[i] = "MLTR".unicode_at(i)
	buf[4] = 1        # version 1（仅 3 平面）
	buf[5] = g
	buf[6] = g
	buf.encode_float(7, WorldGrid.TILE_SIZE)
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)])
		fails += 1
