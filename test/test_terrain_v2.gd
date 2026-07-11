extends SceneTree
## 地形矩阵 v2（scene-items P1）：九平面 + palette 尾段的解析与访问器。
## - v1 载荷仍兼容（物品层补零、palette 空、与 _paint() 一致 → changed=false）
## - v2 载荷：物品引用/朝向/palette 读回正确，物品层差异也触发 changed
## - 非法 v2（索引越 palette/palette 截断/重复项/多余尾巴）一律拒收且不污染已有地形
## 运行: godot --headless --path . --script res://test/test_terrain_v2.gd

const EX := preload("res://tools/export_terrain.gd")
const HEADER := 11

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES
	var count := n * n
	# 导出工具已产 v2；本测试要一份纯地貌 v1 作底——裁前三平面降版即可
	var v1 := EX.build_terrain_bytes().slice(0, HEADER + 3 * count)
	v1[4] = TerrainMap.MLTR_VERSION_1

	# ── v1 兼容：物品层补零，与本地 _paint() 一致 → changed=false ──────────
	TerrainMap.reset()
	var r: Dictionary = TerrainMap.load_from_bytes(v1)
	fails += _check("v1 载入 ok", r["ok"], true)
	fails += _check("v1 与本地一致 changed=false", r["changed"], false)
	fails += _check("v1 无物品", TerrainMap.tile_item_id(Vector2i(10, 10)), "")
	fails += _check("v1 palette 空", TerrainMap.palette().size(), 0)

	# ── v2：树挂 (10,10) 朝向 180°，边缘全空 ───────────────────────────────
	var tile := Vector2i(10, 10)
	var idx := tile.y * n + tile.x
	var v2 := _v2_from_v1(v1, ["tree_puff_a", "小明的花"], { idx: [1, 128], (idx + 3): [2, 64] })
	TerrainMap.reset()
	r = TerrainMap.load_from_bytes(v2)
	fails += _check("v2 载入 ok", r["ok"], true)
	fails += _check("v2 有物品 → changed=true", r["changed"], true)
	fails += _check("物品 id 读回", TerrainMap.tile_item_id(tile), "tree_puff_a")
	fails += _check("造物 id 读回（palette 第 2 项）", TerrainMap.tile_item_id(Vector2i(13, 10)), "小明的花")
	fails += _check("朝向 180°", TerrainMap.tile_item_yaw_deg(tile), 180.0)
	fails += _check("空 tile 无物品", TerrainMap.tile_item_id(Vector2i(11, 11)), "")
	fails += _check("边缘一期恒空", TerrainMap.edge_item_id(tile, TerrainMap.EDGE_N), "")
	fails += _check("palette 2 项", TerrainMap.palette().size(), 2)
	fails += _check("地貌照常（池塘中心是水）", TerrainMap.tile_type(Vector2i(24, 24)), TerrainMap.T_WATER)

	# 同一份 v2 再载一遍 → changed=false（物品层参与比对）
	r = TerrainMap.load_from_bytes(v2)
	fails += _check("重载同 v2 changed=false", r["changed"], false)

	# 物品挪一格 → changed=true（地貌三平面没变也要触发重铺）
	var moved := _v2_from_v1(v1, ["tree_puff_a", "小明的花"], { (idx + 1): [1, 128], (idx + 3): [2, 64] })
	r = TerrainMap.load_from_bytes(moved)
	fails += _check("物品挪格 changed=true", r["changed"], true)

	# ── 非法 v2 一律拒收且不污染 ───────────────────────────────────────────
	TerrainMap.reset()
	TerrainMap.load_from_bytes(v2) # 先有一份好地形
	for c in _bad_payloads(v1, v2):
		r = TerrainMap.load_from_bytes(c["buf"])
		fails += _check("拒收 %s" % c["why"], r["ok"], false)
	fails += _check("拒收后物品仍在", TerrainMap.tile_item_id(tile), "tree_puff_a")

	TerrainMap.reset()
	print("test_terrain_v2: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## v1 载荷 → v2：版本改 2，补物品/边缘平面与 palette 尾段。
## refs: { 平面索引: [palette引用(1起), arg字节] }
func _v2_from_v1(v1: PackedByteArray, palette: Array, refs: Dictionary) -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var out := v1.slice(0, HEADER + 3 * count)
	out[4] = TerrainMap.MLTR_VERSION
	var item_ref := PackedByteArray()
	item_ref.resize(count)
	var item_arg := PackedByteArray()
	item_arg.resize(count)
	for i in refs:
		item_ref[i] = refs[i][0]
		item_arg[i] = refs[i][1]
	out.append_array(item_ref)
	out.append_array(item_arg)
	var zeros := PackedByteArray()
	zeros.resize(4 * count) # 四张空边缘平面
	out.append_array(zeros)
	out.append(palette.size())
	for id: String in palette:
		var b := id.to_utf8_buffer()
		out.append(b.size())
		out.append_array(b)
	return out

func _bad_payloads(v1: PackedByteArray, v2: PackedByteArray) -> Array:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var out: Array = []

	var over := v2.duplicate()
	over[HEADER + 3 * count + 7] = 9 # itemRef=9，palette 只有 2 项
	out.append({ "buf": over, "why": "索引越出 palette" })

	var edge_over := v2.duplicate()
	edge_over[HEADER + 5 * count + 9] = 5 # edgeN 平面越界索引
	out.append({ "buf": edge_over, "why": "边缘索引越出 palette" })

	out.append({ "buf": v2.slice(0, v2.size() - 2), "why": "palette 截断" })

	var trailing := v2.duplicate()
	trailing.append(0)
	out.append({ "buf": trailing, "why": "palette 后多余尾巴" })

	var dup := _v2_from_v1(v1, ["same", "same"], {})
	out.append({ "buf": dup, "why": "palette 重复项" })

	var bad_ver := v2.duplicate()
	bad_ver[4] = 99
	out.append({ "buf": bad_ver, "why": "版本不认识" })
	return out

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
