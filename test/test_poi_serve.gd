extends SceneTree
## POI 下发（scene-terrain-serve P7）：
## 导出的 POI JSON 经 parse_server_pois 还原后与内置常量等价（往返不丢信息）；
## 非法/空载荷一律回退内置常量——绝不让世界变成没有地点的空壳。
## 运行: godot --headless --path . --script res://test/test_poi_serve.gd

const W := preload("res://scripts/world.gd")
const EX := preload("res://tools/export_terrain.gd")

func _init() -> void:
	var fails := 0

	# ── 导出的 POI JSON 覆盖全部内置 POI ────────────────────────────────
	var exported := EX.build_poi_json("village")
	fails += _check("导出数量 == 内置数量", exported.size(), (W.POIS as Array).size())

	# ── 往返：导出 → JSON 文本 → 解析 → 与内置常量逐字段等价 ────────────
	# 走一遍真实的 JSON 序列化/反序列化，暴露 Vector2i 之类不可 JSON 化的类型
	var round_tripped: Variant = JSON.parse_string(JSON.stringify(exported))
	fails += _check("JSON 可序列化", typeof(round_tripped), TYPE_ARRAY)

	var parsed := W.parse_server_pois(round_tripped)
	fails += _check("解析出全部 POI", parsed.size(), (W.POIS as Array).size())

	for i in range(parsed.size()):
		var got: Dictionary = parsed[i]
		var want: Dictionary = (W.POIS as Array)[i]
		fails += _check("POI[%d] tile" % i, got["tile"], want["tile"])
		fails += _check("POI[%d] radius" % i, got["radius"], float(want["radius"]))
		fails += _check("POI[%d] trigger" % i, got["trigger"], want["trigger"])
		fails += _check("POI[%d] name" % i, got["name"], want["name"])
		fails += _check("POI[%d] aliases" % i, Array(got["aliases"]), Array(want["aliases"]))

	# ── 非法载荷：解析出空数组（调用方据此保留内置常量）────────────────
	fails += _check("非数组 → 空", W.parse_server_pois("不是数组").size(), 0)
	fails += _check("空数组 → 空", W.parse_server_pois([]).size(), 0)
	fails += _check("元素非字典 → 跳过", W.parse_server_pois([1, 2]).size(), 0)
	fails += _check("缺 tile → 跳过", W.parse_server_pois([{ "name": "池塘", "trigger": "t" }]).size(), 0)
	fails += _check("tile 长度不对 → 跳过", W.parse_server_pois([{ "tile": [1], "name": "a", "trigger": "t" }]).size(), 0)
	fails += _check("缺 name → 跳过", W.parse_server_pois([{ "tile": [1, 2], "trigger": "t" }]).size(), 0)
	fails += _check("缺 trigger → 跳过", W.parse_server_pois([{ "tile": [1, 2], "name": "a" }]).size(), 0)

	# ── 混合载荷：坏条目跳过，好条目保留 ────────────────────────────────
	var mixed := W.parse_server_pois([
		{ "tile": [1, 2], "name": "好地点", "trigger": "poi_pond", "radius": 5.0, "aliases": ["别名"] },
		{ "tile": [9], "name": "坏地点", "trigger": "x" },
	])
	fails += _check("混合载荷只留好的", mixed.size(), 1)
	fails += _check("好条目 tile 正确", (mixed[0] as Dictionary)["tile"], Vector2i(1, 2))
	fails += _check("好条目 radius 正确", (mixed[0] as Dictionary)["radius"], 5.0)

	# ── radius 缺省有兜底（不至于变成 0 半径永不触发）────────────────────
	var no_radius := W.parse_server_pois([{ "tile": [3, 4], "name": "无半径", "trigger": "t" }])
	fails += _check("radius 缺省 > 0", (no_radius[0] as Dictionary)["radius"] > 0.0, true)

	# ── homes（「谁的家」建筑住户表，interaction-feedback B 档）→ { tile: characterId } ──
	var homes := W.parse_server_homes([
		{ "tile": [10, 12], "characterId": "bear" },
		{ "tile": [20, 22], "characterId": "wolf" },
	])
	fails += _check("homes 解析出全部条目", homes.size(), 2)
	fails += _check("homes tile→characterId 映射正确", homes.get(Vector2i(10, 12), ""), "bear")
	fails += _check("homes 第二条映射正确", homes.get(Vector2i(20, 22), ""), "wolf")
	# 非法/缺省载荷：空字典（调用方据此走通用解释，不崩）
	fails += _check("homes 非数组 → 空字典", W.parse_server_homes("nope").size(), 0)
	fails += _check("homes 空数组 → 空字典", W.parse_server_homes([]).size(), 0)
	fails += _check("homes 缺 characterId → 跳过", W.parse_server_homes([{ "tile": [1, 2] }]).size(), 0)
	fails += _check("homes tile 长度不对 → 跳过", W.parse_server_homes([{ "tile": [1], "characterId": "x" }]).size(), 0)
	# 混合：坏条目跳过、好条目保留
	var homes_mixed := W.parse_server_homes([
		{ "tile": [5, 6], "characterId": "pig" },
		{ "tile": [9], "characterId": "坏" },
	])
	fails += _check("homes 混合只留好的", homes_mixed.size(), 1)
	fails += _check("homes 好条目正确", homes_mixed.get(Vector2i(5, 6), ""), "pig")

	# ── build_homes_json：village_forest 的 6 栋住户往返（导出 → JSON → parse）─────
	# 4 农舍(resident) + 外婆家(grandma) + 七矮人合住小木屋(snow，dwarf-cottage 计划)
	var homes_export := EX.build_homes_json("village_forest")
	fails += _check("village_forest 导出 6 户", homes_export.size(), 6)
	var homes_rt: Variant = JSON.parse_string(JSON.stringify(homes_export))
	fails += _check("homes JSON 可序列化", typeof(homes_rt), TYPE_ARRAY)
	var homes_parsed := W.parse_server_homes(homes_rt)
	fails += _check("往返后仍 6 户（全部 characterId 非空）", homes_parsed.size(), 6)
	fails += _check("外婆家在表里", homes_parsed.get(Vector2i(66, 60), ""), "grandma")
	fails += _check("七矮人小屋在表里(绑 snow)", homes_parsed.get(Vector2i(30, 94), ""), "snow")
	fails += _check("村舍 house_0 在表里", homes_parsed.has(Vector2i(11, 10)), true)
	# 老场景（village/oz）天然无住户 → 空数组（消费方走通用布景解释，不崩）
	fails += _check("village 无住户", EX.build_homes_json("village").size(), 0)
	fails += _check("oz 无住户", EX.build_homes_json("oz").size(), 0)

	print("test_poi_serve: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
