extends SceneTree
## 全量纲化带窗验证（tile-dimensional-system P2）：对真实 node 资产量 raw_aabb → fit_scale_for，
## 换算回世界米 / tile，确认视觉水平占格 ≈ visualTiles×fill（地基名副其实：城堡真占 ~7 tile、
## 民居 ~3 tile、小设施 ~2 tile；树 visualTiles 2×2 > 地基 1×1 让树冠外延）。
##
## 必须带窗跑（不要 --headless）：主题内容包在 res:// 磁盘上可用；load 走 PackRegistry 的挂载守卫，
## 编辑器二进制 --script 下 _pack_loadable 依赖 OS.has_feature("editor")。若某主题项 rawAABB 全 0，
## 说明该包未被判为可载——此工具直读 pack.json path 兜底加载，绕开挂载守卫（编辑器磁盘恒在）。
##   /Applications/Godot.app/Contents/MacOS/Godot --path . --script res://tools/verify_tile_dimensional.gd --quit-after 8000

const PACKS_DIR := "res://assets/packs"

func _initialize() -> void:
	ItemCatalog.ensure_builtin()
	var tile: float = WorldGrid.TILE_SIZE
	# 分档代表 + 树特例（visualTiles>footprint）
	var ids := [
		"mk_castle", "roman_fort", "emerald_castle",  # 城堡类 7×7（emerald 为 SDF，跳过 node 量测）
		"city_tower_a", "mv_church", "mk_barracks",    # 大公建 5×5
		"house_0", "mv_watermill",                     # 普通建筑 3×3
		"well", "windmill", "mk_watchtower",           # 小设施 2×2
		"snow_tree_a",                                 # 树：地基 1×1、视觉 2×2
		"sea_fish_a", "robot_flying",                  # 生物小 1×1
		"dino_trex", "sea_whale",                      # 生物大 3×3
	]
	var fails := 0
	print("\n=== tile-dimensional 派生验证 (TILE_SIZE=%.1fm, fill=0.9) ===" % tile)
	print("  %-15s %-6s %-7s %-7s | %-22s %-8s | %s" % ["id", "cat", "fp", "vt", "rawAABB(x×y×z)", "fit_sc", "视觉 W×D tile / 高 m"])
	for id in ids:
		var def: Dictionary = ItemCatalog.get_def(id)
		if def.is_empty():
			printerr("  ✗ %s 无 def" % id); fails += 1; continue
		var rref := String(def.get("renderRef", ""))
		var key := rref.get_slice(":", 1)
		var cat := PackRegistry.category(key)
		var fpw := int(def.get("footprintW", 1))
		var fph := int(def.get("footprintH", 1))
		var vt := PackRegistry.visual_tiles(def)
		if cat != "node":
			print("  %-15s %-6s %dx%-4d (SDF/非node，视觉走各自管线，只记地基)" % [id, cat if not cat.is_empty() else "sdf", fpw, fph])
			continue
		var ab := PackRegistry.raw_aabb(key)
		if ab.size == Vector3.ZERO:
			ab = _raw_aabb_fallback(def)  # 挂载守卫挡住 → 直读 pack.json path 兜底
		var sc := PackRegistry.fit_scale(ab, vt.x, vt.y)
		var vis_w := ab.size.x * sc / tile
		var vis_d := ab.size.z * sc / tile
		var vis_h := ab.size.y * sc
		# 断言：fit 取两轴 min（不溢出+保长宽比）→ 限制轴（较宽的资产轴）恰好填 0.9×visualTiles，
		# 另一轴按原始长宽比更小。故「视觉限制轴」= max(vis_w,vis_d) ≈ 0.9×visualTiles（方形 vt）。
		var expect := 0.9 * maxf(vt.x, vt.y)
		var got_max := maxf(vis_w, vis_d)
		var ok := ab.size != Vector3.ZERO and absf(got_max - expect) < 0.05
		if not ok:
			fails += 1
		print("  %-15s %-6s %dx%-4d %.0fx%-4.0f | %6.2f×%6.2f×%6.2f %8.4f | %.2f×%.2f tile, 高 %.2fm %s" % [
			id, cat, fpw, fph, vt.x, vt.y, ab.size.x, ab.size.y, ab.size.z, sc, vis_w, vis_d, vis_h,
			"" if ok else "  ✗ 限制轴 %.2f≠期望 %.2f" % [got_max, expect]])
	print("=== verify_tile_dimensional: %s ===\n" % ("PASS" if fails == 0 else "FAIL(%d)" % fails))
	quit(fails)

## raw_aabb 的挂载守卫兜底：直读 pack.json 的资源路径 load()，绕开 PackMounter 判定（仅本验证工具用，
## 编辑器磁盘上主题包恒在）。测量口径与 PackRegistry._accumulate_aabb 一致（按子节点 transform 精确聚合）。
func _raw_aabb_fallback(def: Dictionary) -> AABB:
	var rref := String(def.get("renderRef", ""))
	var key := rref.get_slice(":", 1)
	var pack := PackRegistry.pack_of(key)
	var doc: Variant = _read_json("%s/%s/pack.json" % [PACKS_DIR, pack])
	if typeof(doc) != TYPE_DICTIONARY:
		return AABB()
	var entries: Variant = (doc as Dictionary).get("entries", {})
	if typeof(entries) != TYPE_DICTIONARY or not (entries as Dictionary).has(key):
		return AABB()
	var path := String((entries as Dictionary)[key].get("path", ""))
	var res := load(path)
	if not (res is PackedScene):
		return AABB()
	var inst := (res as PackedScene).instantiate()
	var acc := {}
	_accum(inst, Transform3D.IDENTITY, acc)
	inst.free()
	return acc.get("aabb", AABB())

func _accum(node: Node, xform: Transform3D, acc: Dictionary) -> void:
	var t := xform
	if node is Node3D:
		t = xform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var a := (node as MeshInstance3D).mesh.get_aabb()
		for i in range(8):
			var corner := a.position + Vector3(a.size.x * float(i & 1), a.size.y * float((i >> 1) & 1), a.size.z * float((i >> 2) & 1))
			var p := t * corner
			acc["aabb"] = (acc["aabb"] as AABB).expand(p) if acc.has("aabb") else AABB(p, Vector3.ZERO)
	for c in node.get_children():
		_accum(c, t, acc)

func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())
