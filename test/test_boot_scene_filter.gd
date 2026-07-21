extends SceneTree
## 初载角色过滤断言（scene-drag-guard P3）：_filter_boot_characters 只留当前场景角色，
## 仙女恒随，缺 sceneId 的存量按 village。堵死「初载把全库角色生在村里 → positions_report
## 把森林村民拖成 village」的漏洞（prod 实锤过）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_boot_scene_filter.gd

var scene: Node
var frame := 0
var fails := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame < 3:
		return
	_run_checks()
	if fails == 0:
		print("boot_scene_filter PASS")
	else:
		printerr("boot_scene_filter FAILED: %d" % fails)
	quit(fails)

func _run_checks() -> void:
	var roster: Array = [
		{ "id": "v1", "name": "村民甲", "sceneId": "village" },
		{ "id": "f1", "name": "森林鹿", "sceneId": "forest" },
		{ "id": "f2", "name": "森林松鼠", "sceneId": "forest" },
		{ "id": "fairy", "name": "小神仙", "isFairy": true, "sceneId": "village" },
		{ "id": "legacy", "name": "存量角色" }, # 无 sceneId → 按 village
	]
	# 当前场景 = village 时：只留 village 角色 + 仙女 + 存量（缺 sceneId 按 village）。
	# （主场景已改 village_forest，此处显式置 village 验过滤逻辑本身——引导默认场景另由 home 系列测试覆盖。）
	scene.set("_scene_id", "village")
	var got: Array = scene.call("_filter_boot_characters", roster)
	var ids: Array = []
	for c in got:
		ids.append(String((c as Dictionary).get("id", "")))
	ids.sort()
	_check("village 引导只留村庄角色+仙女+存量", ids, ["fairy", "legacy", "v1"])

	# 若引导场景是 forest（未来支持记忆上次场景时），森林角色留下、村庄的过滤掉、仙女仍在
	scene.set("_scene_id", "forest")
	var got2: Array = scene.call("_filter_boot_characters", roster)
	var ids2: Array = []
	for c in got2:
		ids2.append(String((c as Dictionary).get("id", "")))
	ids2.sort()
	_check("forest 引导只留森林角色+仙女", ids2, ["f1", "f2", "fairy"])
	scene.set("_scene_id", "village")

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % what)
	else:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1
