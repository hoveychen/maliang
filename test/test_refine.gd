extends SceneTree
## 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md §5）客户端冒烟：
## ① wish_trial → 进试用态：亮变大/变小箭头、立指向 refineItemRef 的指示器、播仙子问句（走
##    FairyVoice 独立通道，不碰 _tts_player）。
## ② 点箭头 → send_wish_refine 载荷（itemRef + 按三档阶梯步进后的 newSize）。
## ③ wish_retry → 箭头保留（可继续调）。
## ④ character_resized → 角色按新 scale 比例重缩放，且不换纹理对象、不 reload（只改倍率）。
## ⑤ task_complete → 收起箭头 HUD。
## ⑥ 指示器指向 refineItemRef：角色目标 → 指示器落在那个 npc 头顶。
## ⑦ _scan_item_tile 能在矩阵里反查到某造物所在 tile。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --path . \
##       --fixed-fps 10 --quit-after 90 --script res://test/test_refine.gd

var scene: Node
var frame := 0
var fails := 0
var _sent: Array = []
var _buddy: PaperCharacter

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
	match frame:
		30: _seed()
		32: _test_wish_trial()
		34: _test_indicator_points_at_target()
		36: _test_arrow_sends_refine()
		38: _test_retry_keeps_view()
		40: _test_character_resized()
		42: _test_scan_finds_existing_item()
		44: _test_task_complete_ends()
		48:
			if fails == 0:
				print("refine PASS")
			else:
				printerr("refine FAILED: %d" % fails)
			quit(fails)

## 造一个村民 buddy（作 refine 目标）塞进 npcs，侦听 backend 出站，online=true 让箭头可发。
func _seed() -> void:
	scene.set("online", true)
	scene.set("world_id", "default")
	var backend = scene.get("backend")
	backend.sent.connect(func(obj: Dictionary) -> void: _sent.append(obj))
	_buddy = PaperCharacter.new()
	scene.add_child(_buddy)
	var img := Image.create(100, 200, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.8, 0.6, 0.9))
	var tex := ImageTexture.create_from_image(img)
	_buddy.setup(tex, Color.WHITE, "小龙")
	# 摆成「大号村民」高度基准，便于 resize 断言（缩小后可见高度应变小）。
	_buddy.pixel_size = (6.0 * 1.4) / 200.0
	_buddy.global_position = Vector3(3.0, 0.0, 2.0)
	var npcs: Array = scene.get("npcs")
	npcs.append({ "node": _buddy, "id": "buddy", "logical": Vector2(3.0, 2.0), "is_fairy": false, "scale": 1.4 })

## wish_trial → 进试用态（造物类心愿；这里 itemRef 指向 buddy 走角色分支）。
func _test_wish_trial() -> void:
	scene.call("_on_wish_trial", {
		"npcId": "buddy", "itemRef": "buddy", "refineDir": "smaller",
		"fromSize": "big", "complaint": "太大啦", "voiceId": "v-buddy", "fairyHint": "refine_hint",
	})
	_check("进试用态", scene.get("_refine_active"), true)
	_check("记住 refineItemRef", scene.get("_refine_item_ref"), "buddy")
	_check("当前档=造出来的档 big", scene.get("_refine_size"), "big")
	_check("试用 HUD 亮起", (scene.get("_refine_view") as Control).visible, true)
	_check("指示器已立", scene.get("_refine_indicator") != null, true)
	# 仙子问句走 FairyVoice 独立通道，不碰角色 TTS 播放器
	_check("不碰 _tts_player", (scene.get("_tts_player") as AudioStreamPlayer).playing, false)

## 指示器每帧摆到 refineItemRef 头顶：角色目标 → 落在 buddy 附近（x/z 对齐、抬在头顶上方）。
func _test_indicator_points_at_target() -> void:
	var ind := scene.get("_refine_indicator") as Node3D
	_check("指示器可见", ind.visible, true)
	var p := ind.global_position
	_check("指示器 x 对齐 buddy", absf(p.x - _buddy.global_position.x) < 0.5, true)
	_check("指示器 z 对齐 buddy", absf(p.z - _buddy.global_position.z) < 0.5, true)
	_check("指示器在 buddy 头顶上方", p.y > _buddy.global_position.y + 1.0, true)

## 点「变小一点」→ 三档阶梯 big→medium，发 wish_refine（itemRef + newSize）。
func _test_arrow_sends_refine() -> void:
	_sent.clear()
	scene.call("_refine_press", -1)
	var rf: Dictionary = {}
	for m in _sent:
		if String((m as Dictionary).get("type", "")) == "wish_refine":
			rf = m
	_check("发出 wish_refine", not rf.is_empty(), true)
	if not rf.is_empty():
		_check("itemRef=buddy", String(rf.get("itemRef", "")), "buddy")
		_check("big 变小一档 → medium", String(rf.get("newSize", "")), "medium")
	_check("本地档同步到 medium", scene.get("_refine_size"), "medium")

## wish_retry → 箭头保留（可继续调），仍在试用态。
func _test_retry_keeps_view() -> void:
	scene.call("_on_wish_retry", { "npcId": "buddy", "itemRef": "buddy", "refineDir": "smaller", "tries": 1, "fairyHint": "refine_hint_2" })
	_check("retry 后仍在试用态", scene.get("_refine_active"), true)
	_check("retry 后 HUD 仍亮", (scene.get("_refine_view") as Control).visible, true)

## character_resized → 按新 scale 比例重缩放；纹理对象不变（不换资产、不 reload），可见高度变小。
func _test_character_resized() -> void:
	var before_tex := _buddy.texture
	var before_h := _buddy.visible_height()
	scene.call("_on_character_resized", { "characterId": "buddy", "size": "medium", "scale": 1.0 })
	_check("纹理对象不变(不换资产/不reload)", _buddy.texture == before_tex, true)
	_check("可见高度变小(big→medium)", _buddy.visible_height() < before_h, true)
	_check("新高度≈中号村民基准", absf(_buddy.visible_height() - 6.0) < 0.5, true)

## _scan_item_tile 反查：先在矩阵里找任一已摆物品，再验证按其 id 能扫回同一 tile。
func _test_scan_finds_existing_item() -> void:
	var n: int = WorldGrid.GRID_TILES
	var found := Vector2i(-1, -1)
	var found_id := ""
	for y in range(n):
		for x in range(n):
			var id := TerrainMap.tile_item_id(Vector2i(x, y))
			if not id.is_empty():
				found = Vector2i(x, y)
				found_id = id
				break
		if found.x >= 0:
			break
	if found.x < 0:
		_check("矩阵里有可反查的物品(离线地形应有树木)", false, true)
		return
	var got: Vector2i = scene.call("_scan_item_tile", found_id)
	_check("_scan_item_tile 扫回该物品所在 tile", got, found)
	_check("_scan_item_tile 未知物品回 (-1,-1)", scene.call("_scan_item_tile", "no_such_item_xyz"), Vector2i(-1, -1))

## task_complete → 收起试用 HUD（盖章了）。
func _test_task_complete_ends() -> void:
	scene.call("_on_task_complete", { "stampStyle": "star", "task": { "npcId": "buddy" }, "wallet": {} })
	_check("盖章后退出试用态", scene.get("_refine_active"), false)
	_check("盖章后 HUD 收起", (scene.get("_refine_view") as Control).visible, false)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		return
	fails += 1
	printerr("  ✗ %s: got=%s want=%s" % [name, str(got), str(want)])
