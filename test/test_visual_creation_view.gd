extends SceneTree
## 创造视图人眼 QA（带窗，无断言）：进与仙子的交互 → 驱动一轮 creation_prompt → 截图看
## 特写构图 + 暗底 + 居中 2×2 大卡 + 仙子身旁的降生蛋 + 右上角取消叉是否像方案 A；
## 再点一张卡，截「答案飞向蛋」的中途帧。
## 运行: /Applications/Godot.app/Contents/MacOS/Godot --path . --script res://test/test_visual_creation_view.gd
## 产物：screenshots/creation_view.png（引导态）、screenshots/creation_throw.png（答案飞行中）

var scene: Node
var frame := 0
var seen := -1    ## 仙子第一次出现的帧；她随后还会被真立绘替换（节点重建），故再等 STABLE 帧才进交互
var entered := -1 ## 进交互的那一帧
const STABLE := 60

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	root.size = Vector2i(1280, 720)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if entered < 0:
		if frame > 900:
			push_error("仙子始终没出现，放弃截图")
			quit(1)
			return
		var fairy: Dictionary = scene.call("_find_fairy")
		if fairy.is_empty():
			return
		if seen < 0:
			seen = frame
			return
		if frame - seen < STABLE:
			return # 世界还在铺，立绘一换节点就 free，这时进交互会拿到个死引用
		scene.call("_enter_interaction", fairy["node"])
		entered = frame
		return
	var t := frame - entered
	if t == 20:
		scene.call("_on_creation_prompt", {
			"goal": "character", # 造角色 → 仙子身旁立降生蛋（造物则是魔法熔炉）
			"replyText": "它是什么颜色的呀？", "question": "它是什么颜色的呀？", "category": "color",
			"options": [
				{ "id": "red", "label": "红", "iconAsset": "" },
				{ "id": "yellow", "label": "黄", "iconAsset": "" },
				{ "id": "blue", "label": "蓝", "iconAsset": "" },
				{ "id": "green", "label": "绿", "iconAsset": "" },
			],
			"ttsAsset": "", "voiceId": "",
		})
	if t == 70: # 等相机推近缓动到位
		_shot("creation_view")
	if t == 72: # 点第一张卡 → 它飞向蛋
		var cards := scene.get("_creation_cards") as GridContainer
		if cards.get_child_count() > 0:
			scene.call("_on_creation_card", "red", cards.get_child(0))
	if t == 82: # 飞行中途（THROW_TIME=0.55s，此刻约走了三分之一）
		_shot("creation_throw")
		quit(0)

func _shot(name: String) -> void:
	var img := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://screenshots")
	img.save_png("res://screenshots/%s.png" % name)
	print("saved screenshots/%s.png" % name)
