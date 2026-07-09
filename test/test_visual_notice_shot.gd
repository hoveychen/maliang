extends SceneTree
## 临时视觉验证(不进回测):村民注意到玩家→转头挥手+头顶小表情气泡。
## 带窗跑:
##   MALIANG_API_BASE=http://127.0.0.1:1 godot --path . --quit-after 40 \
##     --script res://test/test_visual_notice_shot.gd
## 输出 /tmp/notice_shot.png。

var scene: Node
var frame := 0
var npc := {}

func _initialize() -> void:
	seed(7)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.set("_target_dist", 13.0)
	scene.set("_target_pitch", 26.0)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	frame += 1
	if frame == 1:
		player["logical"] = TerrainMap.tile_center(Vector2i(37, 37))
		return
	if frame == 3:
		for ex in (scene.get("_executors") as Array):
			(ex as BehaviorExecutor).cancel()
		for n in (scene.get("npcs") as Array):
			if not n.get("is_fairy", false):
				npc = n
				break
		return
	# 持续把村民钉在玩家左侧 3.5m 并保持想打招呼(免得 ambient wander 拽走/掉冷却)
	if frame >= 4 and not npc.is_empty():
		var pl: Vector2 = player["logical"]
		npc["logical"] = WorldGrid.wrap_pos(pl + Vector2(-3.5, 0.5))
		npc["paper_walk"] = 0.0
		if String(npc.get("paper_action", "")).is_empty() and not (npc.get("notice_bubble") and (npc["notice_bubble"] as Sprite3D).visible):
			npc["notice_cd"] = 0.0  # 没在演出就催它再打一次招呼
	if frame == 12:
		var img := root.get_viewport().get_texture().get_image()
		img.save_png("/tmp/notice_shot.png")
		var bub := npc.get("notice_bubble") as Sprite3D
		print("[notice] saved /tmp/notice_shot.png action=%s bubble_vis=%s" % [
			String(npc.get("paper_action", "")), str(bub != null and bub.visible)])
		quit(0)
