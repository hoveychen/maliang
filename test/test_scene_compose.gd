extends SceneTree
## 场景组装等价性（scene-items P2）：scene_compose 产的物品层必须与运行时
## chunk_manager 的散布规则逐 tile 等价——这是「散布搬进矩阵、上线世界与今天
## 一致」的验收标准。P4 删除 chunk_manager 的规则副本后，本测试的对拍段随之退役，
## 落位不变量（锚点/无冲突/确定性）保留。
## - 森林：无手工锚点 → 散布判定与物品层严格双射（kind 与变体都对上）
## - 村庄：除锚点 footprint 覆盖的 tile 外严格双射；被覆盖处只允许「该长而没长」
## 运行: godot --headless --path . --script res://test/test_scene_compose.gd

const COMPOSE := preload("res://tools/scene_compose.gd")
const FOREST := preload("res://tools/export_forest.gd")
const HEADER := 11

const KIND_IDS := {
	COMPOSE.DECO_TREE: ["tree_puff_a", "tree_puff_b", "tree_puff_c"],
	COMPOSE.DECO_BUSH: ["bush_puff"],
	COMPOSE.DECO_ROCK: ["rock_0", "rock_1", "rock_2"],
	COMPOSE.DECO_TUFT: ["tuft_0", "tuft_1"],
}
const ANCHOR_SPAN_IDS := ["well", "windmill", "house_0", "house_1", "house_2", "house_3", "walking_hut", "hop_mailbox"]
const ANCHOR_1X1_IDS := ["nodding_flower", "pinwheel", "paper_note", "crayon", "village_sign"]

func _init() -> void:
	var fails := 0
	var n := WorldGrid.GRID_TILES

	# ── 村庄 ────────────────────────────────────────────────────────────────
	TerrainMap.reset() # 村庄 = 本地 _paint()
	var v := COMPOSE.compose("village")
	fails += _run_scene("village", v, n)

	# 锚点表里非散布 id 的落位数量 = 表行数（螺旋挪位也不会丢/复制）
	var counts := _count_ids(v, n)
	fails += _check("village 民居共 8 栋", counts.get("house_0", 0) + counts.get("house_1", 0)
		+ counts.get("house_2", 0) + counts.get("house_3", 0), 8)
	fails += _check("village 水井 1", counts.get("well", 0), 1)
	fails += _check("village 风车 1", counts.get("windmill", 0), 1)
	for id in ["walking_hut", "hop_mailbox", "nodding_flower", "pinwheel", "paper_note", "crayon", "village_sign"]:
		fails += _check("village %s 1 个" % id, counts.get(id, 0), 1)

	# 确定性：两次组装逐字节一致
	var v2nd = COMPOSE.compose("village")
	fails += _check("village 组装确定性", v["item_ref"] == v2nd["item_ref"] and v["item_arg"] == v2nd["item_arg"]
		and v["palette"] == v2nd["palette"], true)

	# ── 森林 ────────────────────────────────────────────────────────────────
	var forest_bytes: PackedByteArray = FOREST.build_terrain_bytes() # 副作用后已 reset
	var fv1 := forest_bytes.slice(0, HEADER + 3 * n * n)
	fv1[4] = TerrainMap.MLTR_VERSION_1
	TerrainMap.reset()
	var fr: Dictionary = TerrainMap.load_from_bytes(fv1) # 只灌地貌，规则读它
	fails += _check("森林地貌可载入", fr["ok"], true)
	var f = COMPOSE.compose("forest")
	fails += _run_scene("forest", f, n)
	var fcounts := _count_ids(f, n)
	fails += _check("forest 无村庄建筑", fcounts.get("well", 0) + fcounts.get("windmill", 0)
		+ fcounts.get("house_0", 0) + fcounts.get("walking_hut", 0), 0)
	var trees: int = fcounts.get("tree_puff_a", 0) + fcounts.get("tree_puff_b", 0) + fcounts.get("tree_puff_c", 0)
	fails += _check("forest 郁闭林冠（树 > 1500）", trees > 1500, true)

	TerrainMap.reset()
	print("test_scene_compose: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## 逐 tile 对拍：矩阵物品层 vs 运行时散布规则（前置：TerrainMap 已是该场景地貌）。
func _run_scene(scene_id: String, composed: Dictionary, n: int) -> int:
	var fails := 0
	var item_ref: PackedByteArray = composed["item_ref"]
	var palette: PackedStringArray = composed["palette"]

	# 锚点 footprint 覆盖集（散布被合法排挤的唯一豁免区）
	var covered := {}
	for y in range(n):
		for x in range(n):
			var id := _id_at(item_ref, palette, n, x, y)
			if id in ANCHOR_SPAN_IDS:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						covered[Vector2i(posmod(x + dx, n), posmod(y + dy, n))] = true
			elif id in ANCHOR_1X1_IDS:
				covered[Vector2i(x, y)] = true

	var mismatch := 0
	var dropped_outside_cover := 0
	for y in range(n):
		for x in range(n):
			var gt := Vector2i(x, y)
			var id := _id_at(item_ref, palette, n, x, y)
			if id in ANCHOR_SPAN_IDS or id in ANCHOR_1X1_IDS:
				continue # 锚点：泉石 rock 与散布 rock id 相同，凭表位置无冲突，跳过对拍
			if scene_id == "village" and (gt == Vector2i(30, 12) or gt == Vector2i(28, 12)):
				continue # 泉石地标（散布 id，锚点语义）
			var kind: int = ChunkManager._deco_kind_village(gt) if scene_id == "village" else ChunkManager._deco_kind_forest(gt)
			if kind == COMPOSE.DECO_NONE:
				if id != "":
					mismatch += 1
				continue
			var want: Array = KIND_IDS[kind]
			var want_id: String = want[posmod(hash(gt), want.size())]
			if id == want_id:
				continue
			if id == "":
				# 该长没长：只允许发生在锚点 footprint 覆盖区（被地标合法排挤）
				if not covered.has(gt):
					dropped_outside_cover += 1
				continue
			mismatch += 1
	fails += _check("%s 散布零失配" % scene_id, mismatch, 0)
	fails += _check("%s 覆盖区外零丢失" % scene_id, dropped_outside_cover, 0)
	return fails

func _id_at(item_ref: PackedByteArray, palette: PackedStringArray, n: int, x: int, y: int) -> String:
	var r := item_ref[y * n + x]
	return "" if r == 0 else palette[r - 1]

func _count_ids(composed: Dictionary, n: int) -> Dictionary:
	var out := {}
	var item_ref: PackedByteArray = composed["item_ref"]
	var palette: PackedStringArray = composed["palette"]
	for i in range(n * n):
		if item_ref[i] != 0:
			var id := palette[item_ref[i] - 1]
			out[id] = out.get(id, 0) + 1
	return out

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
