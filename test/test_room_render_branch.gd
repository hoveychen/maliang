extends SceneTree
## 室内渲染分支：ChunkManager.set_terrain_hidden 契约（室内重做 P2/P4）。
## 室内地板由 RoomStage 真几何接管，故隐藏各槽的【地面+水面】mesh；但【保留 deco 层 + update 照跑】，
## 好让玩家摆的家具（item_place → 矩阵物品层 → chunk deco）照常渲染并随 update 重定位。覆盖：
##   1. set_terrain_hidden(true) 立即把已铺槽的 tile/water mesh 置 invisible（root/deco 不动）。
##   2. hidden 时 update() 仍铺设（不 early-return）；_skin 出的地面/水面 mesh 保持隐藏。
##   3. set_terrain_hidden(false) 后 tile/water 复现。
## 裸实例即可：_ensure_slots 建槽、_skin 建 mesh（home_interior 平地板），不依赖入树材质。
## 运行: godot --headless --script res://test/test_room_render_branch.gd

var fails := 0

func _init() -> void:
	WorldGrid.configure(50)  # home_interior 预设网格；2×2 = 4 槽
	TerrainMap.reset_scene("home_interior")  # 纯平木地板
	var cm := ChunkManager.new()
	get_root().add_child(cm)
	cm._ensure_slots()
	_check("50 网格建 2×2 = 4 槽", cm._slots.size(), 4)

	# ── ① set_terrain_hidden(true) 立即隐 tile/water、保留 root/deco ─────────
	cm.set_terrain_hidden(true)
	var ground_hidden := true
	var root_kept := true
	for s in cm._slots:
		if (s["tile"] as MeshInstance3D).visible or (s["water"] as MeshInstance3D).visible:
			ground_hidden = false
		if not (s["root"] as Node3D).visible:
			root_kept = false  # root 不该被强隐（deco 家具挂在它下面要渲染）
	_check("hidden 立即隐藏地面/水面 mesh", ground_hidden, true)
	_check("hidden 不强隐 root（deco 家具层保活）", root_kept, true)

	# ── ② hidden 时 update() 仍铺设（不 early-return）───────────────────────
	var before := _skinned_count(cm)
	for _f in range(6):  # 每帧铺最近一块，几帧铺完 4 块
		cm.update(Vector2(48.0, 48.0))  # 焦点=房间中心
	var after := _skinned_count(cm)
	_check("hidden 时 update 仍铺设（skinned 增加）", after > before, true)
	# 铺出来的地面/水面 mesh 仍隐藏
	var still_hidden := true
	for s in cm._slots:
		if s["skinned"] and ((s["tile"] as MeshInstance3D).visible or (s["water"] as MeshInstance3D).visible):
			still_hidden = false
	_check("_skin 出的地面/水面 mesh 保持隐藏", still_hidden, true)

	# ── ③ set_terrain_hidden(false) 后 tile/water 复现 ─────────────────────
	cm.set_terrain_hidden(false)
	var shown := true
	for s in cm._slots:
		if not (s["tile"] as MeshInstance3D).visible or not (s["water"] as MeshInstance3D).visible:
			shown = false
	_check("复位后地面/水面 mesh 复现", shown, true)

	cm.queue_free()
	TerrainMap.reset()
	WorldGrid.configure(WorldGrid.DEFAULT_GRID_TILES)  # 复位，别污染后续测试
	print("test_room_render_branch: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _skinned_count(cm: ChunkManager) -> int:
	var c := 0
	for s in cm._slots:
		if s["skinned"]:
			c += 1
	return c

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	fails += 1
	return 1
