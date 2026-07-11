extends SceneTree
## 未来机器人主题 item 接入冒烟（world-themes P2）。
## 锁死三方一致：server BUILTIN_ITEMS 的 scifi renderRef（对拍进 builtin_items.json）
## ↔ 客户端 ChunkManager.SCIFI_NODES preload 表 ↔ glb 资产可实例化。
## 任一方漂移（改了 id/renderRef/漏 preload/glb 路径错）都在这里炸——这是「新主题接入管线」的守门测试。
## 运行: godot --headless --path . --script res://test/test_scifi_items.gd

const BUILTIN_JSON := "res://assets/terrain/builtin_items.json"

func _init() -> void:
	var fails := 0

	# 1) 读打包内置定义（客户端离线路径吃的同一份，已与服务端 BUILTIN_ITEMS 对拍）
	var f := FileAccess.open(BUILTIN_JSON, FileAccess.READ)
	if f == null:
		printerr("  FAIL 打不开 %s" % BUILTIN_JSON)
		quit(1)
		return
	var defs: Variant = JSON.parse_string(f.get_as_text())
	fails += _check("builtin_items.json 是数组", 1 if typeof(defs) == TYPE_ARRAY else 0, 1)

	# 2) 收集所有 scifi renderRef 的 key（冒号后段），逐个校验落在 SCIFI_NODES 且场景可实例化
	var scifi_keys := {}
	for d in defs:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var rref := String((d as Dictionary).get("renderRef", ""))
		if not rref.begins_with("scifi:"):
			continue
		var key := rref.get_slice(":", 1)
		scifi_keys[key] = true
		# themes 软标签必须带 scifi（造世界引导按此过滤）
		var themes: Variant = (d as Dictionary).get("themes", [])
		var has_scifi := typeof(themes) == TYPE_ARRAY and (themes as Array).has("scifi")
		fails += _check("item %s themes 含 scifi" % (d as Dictionary).get("id", "?"), 1 if has_scifi else 0, 1)
		# 客户端 preload 表必须有这个 key
		if not ChunkManager.SCIFI_NODES.has(key):
			printerr("  FAIL renderRef scifi:%s 在 SCIFI_NODES 缺 preload" % key)
			fails += 1
			continue
		var nb: Dictionary = ChunkManager.SCIFI_NODES[key]
		var scene: Variant = nb.get("scene")
		fails += _check("scifi:%s 是 PackedScene" % key, 1 if scene is PackedScene else 0, 1)
		fails += _check("scifi:%s scale>0" % key, 1 if float(nb.get("scale", 0.0)) > 0.0 else 0, 1)
		if scene is PackedScene:
			var inst: Node = (scene as PackedScene).instantiate()
			fails += _check("scifi:%s 可实例化为 Node3D" % key, 1 if inst is Node3D else 0, 1)
			if inst:
				inst.free()

	# 3) 期望恰 12 个 scifi item，且 SCIFI_NODES 无孤儿（每个 preload 都被某 item 引用）
	fails += _check("scifi item 数量", scifi_keys.size(), 12)
	for k in ChunkManager.SCIFI_NODES:
		fails += _check("SCIFI_NODES[%s] 被 item 引用（无孤儿 preload）" % k, 1 if scifi_keys.has(k) else 0, 1)

	if fails == 0:
		print("scifi_items tests PASS")
	else:
		printerr("scifi_items tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: int, want: int) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %d want %d" % [name, got, want])
	return 1
