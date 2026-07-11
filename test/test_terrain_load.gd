extends SceneTree
## 客户端载入服务端地形（scene-terrain-serve P4）：
## 合法 .mltr 载入成功且与本地 _paint() 一致（changed=false，这是步骤①的验收）；
## 任何非法载荷都被拒收且不污染已有地形（离线/老服务端必须能照常进世界）。
## 运行: godot --headless --path . --script res://test/test_terrain_load.gd

const EX := preload("res://tools/export_terrain.gd")
const HEADER := 11

func _init() -> void:
	var fails := 0
	var good := EX.build_terrain_bytes()

	# ── 合法载荷：载入成功；地貌与本地 _paint() 相同，但 v2 物品层是新增 → changed=true ──
	TerrainMap.reset()
	fails += _check("reset 后不是服务端地形", TerrainMap.is_server_loaded(), false)

	var r: Dictionary = TerrainMap.load_from_bytes(good)
	fails += _check("载入 ok", r["ok"], true)
	fails += _check("v2 物品层新增 → changed=true", r["changed"], true)
	fails += _check("标记为服务端地形", TerrainMap.is_server_loaded(), true)
	fails += _check("重载同载荷 changed=false", TerrainMap.load_from_bytes(good)["changed"], false)

	# 载入后访问器仍给出同样的地形
	fails += _check("池塘中心仍是水", TerrainMap.tile_type(Vector2i(24, 24)), TerrainMap.T_WATER)
	fails += _check("主峰仍有高度", TerrainMap.tile_height(Vector2i(37, 6)) > 0, true)

	# ── 真的不同的地貌：改一格高度 → changed=true ────────────────────────
	var diff := good.duplicate()
	diff[HEADER + WorldGrid.GRID_TILES * WorldGrid.GRID_TILES + 300] = 7 # 改一格高度
	r = TerrainMap.load_from_bytes(diff)
	fails += _check("不同地形 ok", r["ok"], true)
	fails += _check("不同地形 changed=true", r["changed"], true)

	# ── 非法载荷一律拒收，且不动已有地形 ────────────────────────────────
	TerrainMap.reset()
	TerrainMap.tile_type(Vector2i(0, 0)) # 触发本地 _paint()
	var before_pond: int = TerrainMap.tile_type(Vector2i(24, 24))

	for c in _bad_payloads(good):
		r = TerrainMap.load_from_bytes(c["buf"])
		fails += _check("拒收 %s" % c["why"], r["ok"], false)
		fails += _check("拒收 %s 后仍非服务端地形" % c["why"], TerrainMap.is_server_loaded(), false)

	fails += _check("拒收后地形没被污染", TerrainMap.tile_type(Vector2i(24, 24)), before_pond)

	# 收尾：把地形恢复成本地生成，免得污染同进程后续测试
	TerrainMap.reset()

	print("test_terrain_load: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _bad_payloads(good: PackedByteArray) -> Array:
	var out: Array = []

	var short_buf := good.slice(0, 5)
	out.append({ "buf": short_buf, "why": "连头都不够" })

	var bad_magic := good.duplicate()
	bad_magic[0] = "X".unicode_at(0)
	out.append({ "buf": bad_magic, "why": "magic 不对" })

	var bad_ver := good.duplicate()
	bad_ver[4] = 99
	out.append({ "buf": bad_ver, "why": "版本不认识" })

	var bad_grid := good.duplicate()
	bad_grid[5] = 64
	out.append({ "buf": bad_grid, "why": "网格不是 75" })

	var truncated := good.slice(0, good.size() - 1)
	out.append({ "buf": truncated, "why": "长度截断" })

	out.append({ "buf": PackedByteArray(), "why": "空载荷" })
	return out

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
