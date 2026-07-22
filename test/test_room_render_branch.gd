extends SceneTree
## 室内渲染分支：ChunkManager.set_terrain_hidden 契约（室内重做 P2）。
## 室内场景不铺无限地形——全部地形槽隐藏、update() 跳过铺设（屋子几何由 RoomStage 单独渲染）；
## 出室内复位后 update() 按半径正常显隐。覆盖：
##   1. set_terrain_hidden(true) 立即把所有槽 root invisible（不等下一帧 update）。
##   2. hidden 时 update() 保持全隐、且不铺设（skinned 标志不被翻动）。
##   3. set_terrain_hidden(false) 后 update() 恢复按半径显隐（近处槽可见）。
## 裸实例即可：_ensure_slots 建槽、update 只改 root.visible / skinned，不依赖材质或散布。
## 运行: godot --headless --script res://test/test_room_render_branch.gd

var fails := 0

func _init() -> void:
	WorldGrid.configure(50)  # home_interior 预设网格；2×2 = 4 槽
	TerrainMap.reset()
	var cm := ChunkManager.new()
	get_root().add_child(cm)
	cm._ensure_slots()
	_check("50 网格建 2×2 = 4 槽", cm._slots.size(), 4)

	# 预标全铺（模拟已铺完的室外世界），便于验证 hidden 不翻动 skinned。
	for s in cm._slots:
		s["skinned"] = true

	# ── ① set_terrain_hidden(true) 立即全隐 ────────────────────────────────
	cm.set_terrain_hidden(true)
	var all_hidden := true
	for s in cm._slots:
		if (s["root"] as Node3D).visible:
			all_hidden = false
	_check("set_terrain_hidden(true) 立即全隐", all_hidden, true)

	# ── ② hidden 时 update() 保持全隐 + 不铺设 ─────────────────────────────
	cm.update(Vector2.ZERO)
	all_hidden = true
	var still_skinned := true
	for s in cm._slots:
		if (s["root"] as Node3D).visible:
			all_hidden = false
		if not s["skinned"]:
			still_skinned = false
	_check("hidden 时 update 后仍全隐", all_hidden, true)
	_check("hidden 时 update 不铺设（skinned 不变）", still_skinned, true)

	# ── ③ set_terrain_hidden(false) 后 update 恢复按半径显隐 ────────────────
	cm.set_terrain_hidden(false)
	cm.update(Vector2.ZERO)  # 玩家在原点：近处槽应落在 RENDER_RADIUS 内 → 可见
	var any_visible := false
	for s in cm._slots:
		if (s["root"] as Node3D).visible:
			any_visible = true
	_check("复位后 update 至少有近处槽可见", any_visible, true)

	cm.queue_free()
	WorldGrid.configure(WorldGrid.DEFAULT_GRID_TILES)  # 复位，别污染后续测试
	print("test_room_render_branch: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	fails += 1
	return 1
