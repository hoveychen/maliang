extends SceneTree
## 贴纸物品客户端（sticker-items P3，docs/sticker-items-design.md）：
## - apply_patch 的 edge:[side,ref] 通路：挂贴纸/清除/坏载荷整体拒绝
## - chunk_manager 边缘渲染：重铺后贴纸 MultiMesh 出现、实例数与网格形状正确
##   （headless 下 MultiMesh transform 走 RenderingServer dummy 后端读不回——
##   与 _shadow_xforms 同因，只断言 instance_count / mesh 形状，不断言位置）
## - ItemCatalog.sticker_ids：小铺货架数据源 12 张
## 运行: godot --headless --script res://test/test_sticker_edges.gd

var fails := 0

func _init() -> void:
	TerrainMap.reset()
	OccupancyMap.clear()
	ItemCatalog.reset()
	ItemCatalog.ensure_builtin()

	# ── 小铺货架数据源 ─────────────────────────────────────────────────────
	var ids: Array = ItemCatalog.sticker_ids()
	_check("内置贴纸 12 张", ids.size(), 12)
	_check("贴纸实体 mount=edge", String(ItemCatalog.get_def("sticker_sun").get("mount", "")), "edge")

	# ── apply_patch：挂贴纸到边缘（palette 追加）────────────────────────────
	var p: Dictionary = TerrainMap.apply_patch({
		"paletteAppend": [{ "index": 1, "itemId": "sticker_sun" }],
		"edits": [
			{ "x": 30, "y": 30, "edge": [TerrainMap.EDGE_S, 1] },
			{ "x": 30, "y": 31, "edge": [TerrainMap.EDGE_E, 1] },
		],
	})
	_check("edge patch 应用 ok", p["ok"], true)
	_check("南边缘挂上", TerrainMap.edge_item_id(Vector2i(30, 30), TerrainMap.EDGE_S), "sticker_sun")
	_check("东边缘挂上", TerrainMap.edge_item_id(Vector2i(30, 31), TerrainMap.EDGE_E), "sticker_sun")
	_check("itemRef 不受牵连", TerrainMap.tile_item_id(Vector2i(30, 30)), "")

	# ── 坏 edge 整体拒绝且不半改 ────────────────────────────────────────────
	for bad in [
		{ "why": "side 越界", "patch": { "edits": [{ "x": 5, "y": 5, "edge": [4, 1] }] } },
		{ "why": "ref 越界", "patch": { "edits": [{ "x": 5, "y": 5, "edge": [0, 9] }] } },
		{ "why": "edge 非数组", "patch": { "edits": [{ "x": 5, "y": 5, "edge": "S" }] } },
	]:
		var br: Dictionary = TerrainMap.apply_patch(bad["patch"])
		fails += 0 if not br["ok"] else 1
		if br["ok"]:
			print("  FAIL 拒绝：", bad["why"])
	_check("拒绝后已挂贴纸未被半改", TerrainMap.edge_item_id(Vector2i(30, 30), TerrainMap.EDGE_S), "sticker_sun")

	# ── chunk_manager 边缘渲染：tile(30,30/31) 落在 wrapped 区块 (1,1) ───────
	var cm := ChunkManager.new()
	var host := Node3D.new()
	root.add_child(host)
	host.add_child(cm)
	var slot := {
		"tile": MeshInstance3D.new(), "water": MeshInstance3D.new(),
		"deco": Node3D.new(), "wrapped": Vector2i(1, 1), "skinned": false,
	}
	for k in ["tile", "water", "deco"]:
		host.add_child(slot[k])
	cm._skin(slot, Vector2i(1, 1))

	var sticker_mmi: MultiMeshInstance3D = null
	for c in (slot["deco"] as Node3D).get_children():
		if c is MultiMeshInstance3D and (c as MultiMeshInstance3D).multimesh.mesh is QuadMesh:
			sticker_mmi = c
	_check("重铺后出现贴纸 MultiMesh", sticker_mmi != null, true)
	if sticker_mmi != null:
		_check("两处贴纸合批为 2 实例", sticker_mmi.multimesh.instance_count, 2)
		var q := sticker_mmi.multimesh.mesh as QuadMesh
		_check("竖片高为 STICKER_H", q.size.y, ChunkManager.STICKER_H)
		_check("底边对齐原点（center_offset 上移半高）", q.center_offset.y, ChunkManager.STICKER_H * 0.5)

	# ── 清除：edge ref=0 → 空边；重铺后贴纸实例只剩 1 ───────────────────────
	var pc: Dictionary = TerrainMap.apply_patch({ "edits": [{ "x": 30, "y": 30, "edge": [TerrainMap.EDGE_S, 0] }] })
	_check("清除 patch ok", pc["ok"], true)
	_check("南边缘已空", TerrainMap.edge_item_id(Vector2i(30, 30), TerrainMap.EDGE_S), "")
	cm._skin(slot, Vector2i(1, 1)) # 同槽位重铺（queue_free 未及生效，重新数新增节点）
	var count_after := -1
	var seen := 0
	for c in (slot["deco"] as Node3D).get_children():
		if c is MultiMeshInstance3D and (c as MultiMeshInstance3D).multimesh.mesh is QuadMesh and not c.is_queued_for_deletion():
			seen += 1
			count_after = (c as MultiMeshInstance3D).multimesh.instance_count
	_check("重铺后仅一个贴纸 MultiMesh 存活", seen, 1)
	_check("清除后实例数 1", count_after, 1)

	# ── 边缘几何常量表（渲染朝外/中点偏移的契约，位置断言的纯数据替身）─────────
	_check("N 偏移", ChunkManager.EDGE_OFFSETS[TerrainMap.EDGE_N], Vector2(0, -0.5))
	_check("S 偏移", ChunkManager.EDGE_OFFSETS[TerrainMap.EDGE_S], Vector2(0, 0.5))
	_check("N 朝外 yaw=180", ChunkManager.EDGE_YAWS[TerrainMap.EDGE_N], 180.0)
	_check("S 朝外 yaw=0", ChunkManager.EDGE_YAWS[TerrainMap.EDGE_S], 0.0)

	TerrainMap.reset()
	ItemCatalog.reset()
	print("test_sticker_edges: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	print("  FAIL %s: got %s want %s" % [what, str(got), str(want)])
	fails += 1
	return 1
