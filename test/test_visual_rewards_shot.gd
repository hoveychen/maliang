extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：奖赏系统演出截帧。
## 编排（--fixed-fps 8）：1s 委托 chip 亮起 → 2s 委托完成（小绿跳+🎉+盖章飞入手机按钮）→
## 5s 打开手机小红花 app（3×3 花格+盖章进度）→ 8s 关 → 10s 委托升花（换到小红花）→ 20s 结束。
## 环境变量：PITCH/DIST 调相机。
## 运行: godot --write-movie <目录>/f.png --fixed-fps 8 --quit-after 160 \
##       --script res://test/test_visual_rewards_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0
var blue: Dictionary = {}
var green: Dictionary = {}

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var pitch := OS.get_environment("PITCH")
	if pitch != "":
		scene.set("_target_pitch", float(pitch))
	var dist := OS.get_environment("DIST")
	if dist != "":
		scene.set("_target_dist", float(dist))
	process_frame.connect(_tick)

func _teleport(d: Dictionary, tile: Vector2i) -> void:
	var pos := TerrainMap.tile_center(tile)
	d["logical"] = pos
	OccupancyMap.char_register(String(d.get("id", "")), pos, int(d.get("span", 2)))

func _tick() -> void:
	if scene == null:
		return
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	frame += 1
	if frame == 1:
		_teleport(player, Vector2i(37, 37))
		for n in (scene.get("npcs") as Array):
			match (n["node"] as PaperCharacter).char_name:
				"小蓝": blue = n
				"小绿": green = n
		_teleport(blue, Vector2i(41, 38))
		_teleport(green, Vector2i(35, 39))
		scene.set("online", true)
		return
	match frame:
		8:
			scene.call("_on_world_state", { "wallet": { "flowers": 2, "stampProgress": 2, "stampsTotal": 5 },
				"activeTask": {
					"id": "t", "type": "deliver", "npcId": String(green.get("id", "")),
					"npcName": "小绿", "targetName": "小蓝", "message": "你好呀", "stampStyle": "star" } })
		16:
			scene.call("_on_task_complete", { "task": { "id": "t", "type": "deliver",
				"npcId": String(green.get("id", "")), "npcName": "小绿", "stampStyle": "medal" },
				"stampStyle": "medal", "flowerGained": true,
				"wallet": { "flowers": 3, "stampProgress": 0, "stampsTotal": 6 } })
		40:
			scene.call("_toggle_album")
		64:
			scene.call("_toggle_album")
