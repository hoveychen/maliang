extends SceneTree
## bug 回归：动画图集角色（idle sprite-sheet）的立绘高度必须按单格 cellH 算，
## 不能用整张图集高度（rows×cellH）——否则 _char_top 把角色算高 rows 倍，对话构图距离暴涨、
## 相机被拉远（"跟小仙子对话没用上相机系统"）。真机仙子/玩家都是动画图集，headless 静态占位测不到。
## 复现：把仙子切成 4 行图集(world_height=1.5)，进对话，断言相机距离仍是按可见 1.5m 构图（≈按玩家
## 静态高度定），而不是被 4×1.5=6 撑到远处。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 40 --script res://test/test_visual_dialog_anim.gd

var scene: Node
var frame := 0
var fails := 0
var player_h := 0.0

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
		4:
			_animate_fairy_and_enter()
		20:
			_check_dist()
		26:
			if fails == 0:
				print("visual_dialog_anim PASS")
			else:
				printerr("visual_dialog_anim FAILED: %d" % fails)
			quit(fails)

func _animate_fairy_and_enter() -> void:
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()
	var fairy: Dictionary = scene.call("_find_fairy")
	if fairy.is_empty():
		_check("找到小仙子", false, true)
		return
	# 合成一张 1 列 4 行的图集（64×256），把仙子切成动画，可见世界高度 1.5m
	var img := Image.create(64, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var atlas := ImageTexture.create_from_image(img)
	var meta := { "cols": 1, "rows": 4, "frameCount": 4, "fps": 8, "cellW": 64, "cellH": 64 }
	(fairy["node"] as Object).call("play_anim", atlas, meta, 1.5, 0.0)
	# 玩家保持静态占位；记录其可见高度（相机基础构图应由它主导，仙子只有 1.5m 更矮）
	player_h = float(scene.call("_char_top", scene.get("player")["node"]))
	scene.call("_enter_interaction", fairy["node"])

func _check_dist() -> void:
	# 修好后：base_h = max(player_h, 仙子可见 1.5m) = player_h（仙子不再被图集撑成 4×1.5=6）。
	# 基础构图 = player_h/0.4663；仙子说话(进对话招呼)时朝仙子 zoom 只会更近 → dist 恒 ≤ 基础值。
	# bug 版本仙子高度撑到 6，基础/说话都 ~12.9，必然超过上界。
	var base := player_h / 0.4663077 # ≈6.86（player_h≈3.2）
	var dist := float(scene.get("_target_dist"))
	_check("仙子未被图集撑高:dist(=%.2f) ≤ 玩家主导的基础构图(%.2f)" % [dist, base], dist <= base + 0.6, true)
	_check("相机没被动画图集拉远(dist>3 且 <9)", dist > 3.0 and dist < 9.0, true)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [str(name), str(got), str(want)])
