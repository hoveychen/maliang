extends SceneTree
## RoomStage 几何节点单测（home-interior 重做 P1）。
## - build(n) 造出地板 + 后/左/右三面墙 + 三条踢脚线；前墙不建
## - 地板 PlaneMesh 尺寸 = n×TILE 见方
## - 墙盒沿墙方向覆盖净空（含补角）、抬到 WALL_H/2
## - clear() 拆干净、room_n() 归零
## - 幂等：连续两次 build 同尺寸不叠加节点
## 运行: godot --headless --path . --script res://test/test_room_stage.gd
const RS := preload("res://scripts/room_stage.gd")

func _init() -> void:
	var fails := 0
	var stage: RoomStage = RS.new()
	get_root().add_child(stage)

	# ── 未构建 ──────────────────────────────────────────────────────────────
	fails += _check("初始 room_n = 0", stage.room_n(), 0)
	fails += _check("初始无子节点", stage.get_child_count(), 0)

	# ── build(10)：地板 + 3 墙 + 3 踢脚线 = 7 节点 ─────────────────────────
	var n := 10
	stage.build(n)
	fails += _check("build 后 room_n = 10", stage.room_n(), n)
	fails += _check("子节点数 = 7（地板+3墙+3踢脚）", stage.get_child_count(), 7)

	var floor_mi := stage.get_node_or_null("Floor") as MeshInstance3D
	fails += _check("有 Floor 节点", floor_mi != null, true)
	if floor_mi != null:
		var pm := floor_mi.mesh as PlaneMesh
		fails += _check("Floor 是 PlaneMesh", pm != null, true)
		if pm != null:
			fails += _check("地板边长 = n×TILE", pm.size, Vector2(float(n) * RS.TILE, float(n) * RS.TILE))

	fails += _check("有后墙", stage.get_node_or_null("WallBack") != null, true)
	fails += _check("有左墙", stage.get_node_or_null("WallLeft") != null, true)
	fails += _check("有右墙", stage.get_node_or_null("WallRight") != null, true)
	fails += _check("前墙不建（朝相机开口）", stage.get_node_or_null("WallFront"), null)

	var back := stage.get_node_or_null("WallBack") as MeshInstance3D
	if back != null:
		var box := back.mesh as BoxMesh
		fails += _check("后墙是 BoxMesh", box != null, true)
		if box != null:
			fails += _check("后墙横向覆盖净空+补角", box.size.x, float(n) * RS.TILE + RS.WALL_THICK)
			fails += _check("后墙高 = WALL_H", box.size.y, RS.WALL_H)
		fails += _check("后墙抬到 WALL_H/2", back.position.y, RS.WALL_H * 0.5)
		var half := float(n) * RS.TILE * 0.5
		fails += _check("后墙在 -z 侧", back.position.z, -half - RS.WALL_THICK * 0.5)

	# ── 幂等：再 build 同尺寸不叠加 ────────────────────────────────────────
	stage.build(n)
	fails += _check("重复 build 子节点数不变", stage.get_child_count(), 7)

	# ── clear() ────────────────────────────────────────────────────────────
	stage.build(12)
	fails += _check("build(12) 后 room_n = 12", stage.room_n(), 12)
	stage.clear()
	fails += _check("clear 后 room_n = 0", stage.room_n(), 0)
	await process_frame  # queue_free 在下一帧生效
	fails += _check("clear 后无子节点", stage.get_child_count(), 0)

	# ── build(0) 视作 clear ───────────────────────────────────────────────
	stage.build(0)
	fails += _check("build(0) room_n = 0", stage.room_n(), 0)

	print("test_room_stage: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT and typeof(want) == TYPE_FLOAT:
		if is_equal_approx(got, want):
			return 0
	elif got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
