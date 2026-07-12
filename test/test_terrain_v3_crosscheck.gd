extends SceneTree
## 两端 u16 字节对齐的真跨实现校验：加载「服务端 terrain.ts 编码」的 v3 blob
## （test/fixtures/v3_crosscheck.mltr，由 server/test/gen_v3_fixture.ts 生成），
## 断言客户端 TerrainMap 逐字节解出契约值。捕捉服务端 DataView-LE 编码与客户端
## decode_u16-LE 解码之间任何字节序/偏移不一致——客户端自造 blob 测不出这类 bug。
## 契约值须与 gen_v3_fixture.ts 保持一致（改一处两处都改）。
## 运行: godot --headless --path . --script res://test/test_terrain_v3_crosscheck.gd

const FIXTURE := "res://test/fixtures/v3_crosscheck.mltr"

func _init() -> void:
	var fails := 0
	var f := FileAccess.open(FIXTURE, FileAccess.READ)
	if f == null:
		printerr("  ✗ 缺 fixture %s（先跑 node server/test/gen_v3_fixture.ts）" % FIXTURE)
		print("test_terrain_v3_crosscheck: FAIL(1)")
		quit(1)
		return
	var buf := f.get_buffer(f.get_length())
	f.close()

	fails += _check("fixture 是 v3(版本位=3)", buf[4], 3)

	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(buf)
	fails += _check("服务端 v3 blob 客户端载入 ok", r["ok"], true)

	var tile := Vector2i(20, 20)
	# itemRef=256 → palette[255]=it255（证明 u16 高字节没丢、小端对齐）
	fails += _check("高索引物品(itemRef=256) → it255", TerrainMap.tile_item_id(tile), "it255")
	# 边缘 W ref=200 → palette[199]=it199
	fails += _check("边缘 W 高索引(ref=200) → it199", TerrainMap.edge_item_id(tile, TerrainMap.EDGE_W), "it199")
	fails += _check("朝向 90°(arg=64)", TerrainMap.tile_item_yaw_deg(tile), 90.0)
	fails += _check("palette 256 项", TerrainMap.palette().size(), 256)
	fails += _check("空 tile 无物品", TerrainMap.tile_item_id(Vector2i(21, 21)), "")
	fails += _check("其余边空", TerrainMap.edge_item_id(tile, TerrainMap.EDGE_N), "")

	TerrainMap.reset()
	print("test_terrain_v3_crosscheck: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
