extends SceneTree
## 地形导出（scene-terrain-serve P3）：.mltr 字节流必须与 TerrainMap 内存三数组逐字节一致。
## 这是「地形搬服务端」的验收标准——上线后玩家看到的地图与今天完全一致。
## 运行: godot --headless --path . --script res://test/test_terrain_export.gd

const EX := preload("res://tools/export_terrain.gd")
const HEADER := 11

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var buf := EX.build_terrain_bytes()

	# ── 头部 ──────────────────────────────────────────────────────────────
	fails += _check("总长 = 11 + 3×N", buf.size(), HEADER + 3 * count)
	fails += _check("75×75 → 16886 B", buf.size(), 16886)
	fails += _check("magic M", buf[0], "M".unicode_at(0))
	fails += _check("magic L", buf[1], "L".unicode_at(0))
	fails += _check("magic T", buf[2], "T".unicode_at(0))
	fails += _check("magic R", buf[3], "R".unicode_at(0))
	fails += _check("version", buf[4], 1)
	fails += _check("gridW", buf[5], n)
	fails += _check("gridH", buf[6], n)
	fails += _check("tileSize(f32 LE)", buf.decode_float(7), WorldGrid.TILE_SIZE)

	# ── 三个平面逐字节对拍（这是本测试的核心）────────────────────────────
	var mismatch_type := 0
	var mismatch_h := 0
	var mismatch_d := 0
	for y in range(n):
		for x in range(n):
			var t := Vector2i(x, y)
			var i := y * n + x
			if buf[HEADER + i] != TerrainMap.tile_type(t):
				mismatch_type += 1
			if buf[HEADER + count + i] != TerrainMap.tile_height(t):
				mismatch_h += 1
			if buf[HEADER + 2 * count + i] != TerrainMap.tile_depth(t):
				mismatch_d += 1
	fails += _check("types 平面零失配", mismatch_type, 0)
	fails += _check("heights 平面零失配", mismatch_h, 0)
	fails += _check("depths 平面零失配", mismatch_d, 0)

	# ── 服务端解码器的不变量：非水格水深必须为 0 ────────────────────────
	var bad_depth := 0
	var water := 0
	for i in range(count):
		var ty := buf[HEADER + i]
		var d := buf[HEADER + 2 * count + i]
		if ty == TerrainMap.T_WATER:
			water += 1
		elif d != 0:
			bad_depth += 1
	fails += _check("非水格水深为 0（服务端会拒收）", bad_depth, 0)
	fails += _check("确实有水（不是全草地的空地形）", water > 0, true)

	# ── tile 类型全部合法 ────────────────────────────────────────────────
	var bad_type := 0
	for i in range(count):
		var ty := buf[HEADER + i]
		if ty != TerrainMap.T_GRASS and ty != TerrainMap.T_PATH and ty != TerrainMap.T_WATER:
			bad_type += 1
	fails += _check("tile 类型全合法", bad_type, 0)

	# ── 确定性：连续两次导出必须逐字节相同 ──────────────────────────────
	fails += _check("两次导出字节一致（地形是纯函数）", buf == EX.build_terrain_bytes(), true)

	print("test_terrain_export: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT and typeof(want) == TYPE_FLOAT:
		if is_equal_approx(got, want):
			return 0
	elif got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
