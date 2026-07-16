extends SceneTree
## P2 回归：world 的离线/demo 村民必须用打包的 seed 村民图集（VillagerAssets）以 idle 动画降生，
## 而不是染色 critter 静态占位（此前 _setup_npcs 用 critter_tex + 小蓝/小绿/小黄 三种颜色）。
## 断言两件事：
##   ① VillagerAssets.SEED 图集完整——能加载，且尺寸 = cols*cellW × rows*cellH（meta 与图对齐）。
##   ② 离线实例化 main.tscn 后，demo_ 前缀的非仙子 NPC 都置了 _sheet（=已 play_anim 动画）
##      且贴图正是某个 seed 村民图集。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_villager_assets.gd

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	_check_manifest()
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _check_manifest() -> void:
	var seed: Array = VillagerAssets.SEED
	if seed.size() < 3:
		printerr("  FAIL SEED 少于 3 个村民: %d" % seed.size()); fails += 1
	for v in seed:
		var atlas := load(String(v["atlas"])) as Texture2D
		if atlas == null:
			printerr("  FAIL 图集加载失败: %s" % v["atlas"]); fails += 1; continue
		var m: Dictionary = v["meta"]
		var want_w := int(m["cols"]) * int(m["cellW"])
		var want_h := int(m["rows"]) * int(m["cellH"])
		if atlas.get_width() == want_w and atlas.get_height() == want_h:
			print("  ok %s 图集 %dx%d 与 meta 吻合" % [v["slug"], want_w, want_h])
		else:
			printerr("  FAIL %s 图集 %dx%d 与 meta 期望 %dx%d 不符" % [v["slug"], atlas.get_width(), atlas.get_height(), want_w, want_h]); fails += 1

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 20:
		_check_demo_villagers()
		if fails == 0:
			print("villager_assets tests PASS")
		else:
			printerr("villager_assets tests FAILED: %d" % fails)
		quit(fails)

func _check_demo_villagers() -> void:
	var npcs: Array = scene.get("npcs")
	var demos := npcs.filter(func(n: Dictionary) -> bool:
		return String(n.get("id", "")).begins_with("demo_") and not bool(n.get("is_fairy", false)))
	if demos.size() < 3:
		printerr("  FAIL demo 村民少于 3: %d" % demos.size()); fails += 1; return
	var seed_atlases := {}
	for v in VillagerAssets.SEED:
		seed_atlases[load(String(v["atlas"]))] = v["slug"]
	for n in demos:
		var node: PaperCharacter = n["node"]
		var sheet: Dictionary = node.get("_sheet")
		if sheet.is_empty():
			printerr("  FAIL demo %s 未置 _sheet（仍是静态占位，没 play_anim）" % n["id"]); fails += 1
		elif not seed_atlases.has(node.texture):
			printerr("  FAIL demo %s 贴图不是 seed 村民图集" % n["id"]); fails += 1
		else:
			print("  ok demo %s 已用 seed 村民图集动画降生" % [n["id"]])
