extends SceneTree
## 资产包注册表守门（world-themes P3，数据驱动化）。
## 锁死：打包内置物品（builtin_items.json，服务端 BUILTIN_ITEMS 对拍副本）里每个
## 非 SDF 的 renderRef，其冒号后段 key 都能在 PackRegistry 解析（分类合法 + 资源可 load
## + 可实例化），且 PackRegistry 无孤儿声明（每条 pack 声明都被某物品引用）。
## 这是 P3 把 4 张编译期 preload 表迁 assets/packs/*/pack.json 后的通用守门——
## 任一方漂移（漏声明/路径错/分类错/加了没人用的孤儿键）都在这里炸。
## 运行: godot --headless --path . --script res://test/test_pack_registry.gd

const BUILTIN_JSON := "res://assets/terrain/builtin_items.json"

func _init() -> void:
	var fails := 0

	# 注册表非空（index.json + 至少一个 pack.json 载入成功）
	var all_keys := PackRegistry.all_keys()
	fails += _check("PackRegistry 非空", 1 if all_keys.size() > 0 else 0, 1)

	var f := FileAccess.open(BUILTIN_JSON, FileAccess.READ)
	if f == null:
		printerr("  FAIL 打不开 %s" % BUILTIN_JSON)
		quit(1)
		return
	var defs: Variant = JSON.parse_string(f.get_as_text())
	if typeof(defs) != TYPE_ARRAY:
		printerr("  FAIL builtin_items.json 非数组")
		quit(1)
		return

	# 每个内置物品的 renderRef：SDF 类（sdf_inline/sdf_res:）跳过（不进 manifest，
	# 运行时按 json 路径加载）；其余 key 必须在 PackRegistry 解析、可 load、可实例化。
	var referenced := {}
	for d in defs:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var rref := String((d as Dictionary).get("renderRef", ""))
		if rref.is_empty() or rref == "sdf_inline" or rref.begins_with("sdf_res:"):
			continue
		var key := rref.get_slice(":", 1)
		referenced[key] = true
		if not PackRegistry.has(key):
			printerr("  FAIL renderRef %s 的键未在 PackRegistry 注册" % rref)
			fails += 1
			continue
		var cat := PackRegistry.category(key)
		fails += _check("%s 分类合法(baked/scatter/node)" % rref,
			1 if cat in ["baked", "scatter", "node"] else 0, 1)
		var res: Variant = PackRegistry.load_resource(key)
		fails += _check("%s 资源可 load" % rref, 1 if res is Resource else 0, 1)
		if cat == "node":
			fails += _check("%s scale>0" % rref, 1 if PackRegistry.scale(key) > 0.0 else 0, 1)
			if res is PackedScene:
				var inst: Node = (res as PackedScene).instantiate()
				fails += _check("%s 可实例化为 Node3D" % rref, 1 if inst is Node3D else 0, 1)
				if inst:
					inst.free()
		elif cat == "baked":
			fails += _check("%s 是 Mesh" % rref, 1 if res is Mesh else 0, 1)
		elif cat == "scatter":
			fails += _check("%s 是 PackedScene" % rref, 1 if res is PackedScene else 0, 1)

	# 无孤儿：每条 pack 声明都被某内置物品引用（防止加了没人用的键，或删物品漏删声明）
	for k in all_keys:
		fails += _check("pack 键[%s] 被内置物品引用（无孤儿声明）" % k,
			1 if referenced.has(k) else 0, 1)

	if fails == 0:
		print("pack_registry tests PASS")
	else:
		printerr("pack_registry tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: int, want: int) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %d want %d" % [name, got, want])
	return 1
