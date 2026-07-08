extends SceneTree
## 对话站桩 + 构图相机纯函数单测（World.stage_side / staged_logical / compute_dialog_cam）。
## 只验证不依赖场景实例的数学：站位落点、FOV 反算轨道距离、说话人跟随的焦点/距离偏移。
## 运行: godot --headless --path . --script res://test/test_dialog_camera.gd

const W := preload("res://scripts/world.gd")
const TANHALF := 0.4663077  ## tan(25°)，fov=50 竖直半角
const FILL := 0.5

func _init() -> void:
	var fails := 0

	# ---- 站桩侧：dx>0 玩家在右(+1)、否则左(-1)，dx≈0 默认左 ----
	fails += _check("stage_side right", W.stage_side(3.0), 1.0)
	fails += _check("stage_side left", W.stage_side(-3.0), -1.0)
	fails += _check("stage_side zero→left", W.stage_side(0.0), -1.0)

	# ---- 玩家站位：站到 NPC 的进入侧、离 NPC 恰好 STAGE_GAP ----
	var npc := Vector2(0.0, 0.0)
	var stage_r := W.staged_logical(npc, Vector2(3.0, 0.0), 5.0)  # 玩家从右侧来
	fails += _check("staged right x", stage_r.x, 5.0)
	fails += _check("staged right gap", WorldGrid.shortest_delta(npc, stage_r).length(), 5.0)
	var stage_l := W.staged_logical(npc, Vector2(-3.0, 0.0), 5.0) # 玩家从左侧来（环面 wrap，用最短向量判侧）
	fails += _check("staged left x", WorldGrid.shortest_delta(npc, stage_l).x, -5.0)

	# ---- 基础构图（is_idle）：最高者 5 占屏中间 50%，焦点=中点、竖直居中抬 2.5 ----
	var base := W.compute_dialog_cam(npc, Vector2.ZERO, 5.0, 1.5, 50.0, true)
	var expect_base_dist := 5.0 / (2.0 * FILL * TANHALF)  # ≈10.722
	fails += _check("idle dist frames tallest at 50%", base["dist"], expect_base_dist)
	fails += _check("idle lift centers vertically", base["lift"], 2.5)
	fails += _check("idle want stays at center", (base["want"] as Vector2).is_equal_approx(npc), true)

	# ---- 说话人=矮仙子(1.5)：焦点朝仙子偏 0.35、距离朝仙子单独构图混 0.45（明显更近）----
	var fairy := W.compute_dialog_cam(npc, Vector2(3.0, 0.0), 5.0, 1.5, 50.0, false)
	var indiv := 1.5 / (2.0 * FILL * TANHALF)             # ≈3.217
	var expect_fairy_dist := lerpf(expect_base_dist, indiv, 0.45) # ≈7.345
	fails += _check("fairy-speak zooms in (smaller→closer)", fairy["dist"], expect_fairy_dist)
	fails += _check("fairy-speak dist < base", fairy["dist"] < expect_base_dist, true)
	fails += _check("fairy-speak focus shifts toward fairy", (fairy["want"] as Vector2).x, 3.0 * 0.35)
	fails += _check("fairy-speak lift", fairy["lift"], lerpf(5.0, 1.5, 0.35) * 0.5)

	# ---- 说话人=高玩家(5=最高)：几乎不 zoom（单独构图≈基础），仅焦点朝玩家偏 ----
	var pl := W.compute_dialog_cam(npc, Vector2(-3.0, 0.0), 5.0, 5.0, 50.0, false)
	fails += _check("player-speak barely zooms (dist≈base)", pl["dist"], expect_base_dist)
	fails += _check("player-speak focus shifts toward player", WorldGrid.shortest_delta(npc, pl["want"]).x, -3.0 * 0.35)

	# ---- 尺寸差自动处理：矮说话方 zoom 幅度 > 高说话方 ----
	var fairy_zoom := expect_base_dist - float(fairy["dist"])
	var player_zoom := expect_base_dist - float(pl["dist"])
	fails += _check("smaller speaker zooms more than taller", fairy_zoom > player_zoom, true)

	if fails == 0:
		print("dialog_camera tests PASS")
	else:
		printerr("dialog_camera tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if typeof(got) == TYPE_FLOAT:
		if absf(got - want) < 1e-3:
			return 0
	elif got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
