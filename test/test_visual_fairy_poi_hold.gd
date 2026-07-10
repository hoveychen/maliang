extends SceneTree
## 缺陷 ③ 回归测试：POI 提醒已在飞行途中时进入与小仙子的对话 —— 她必须停在原地听小朋友说话，
## 不能被提醒拽走（老板原话「在对话状态下角色会被推走」）。
##
## 根因：_update_fairy 里 `if not _fairy_poi.is_empty()` 排在 `elif selected == fairy` 之前，
## POI 分支以 speed_min=14 果断飞过去，压过了「对话中停在原地」那一支；且仙子位移直接改
## fairy["logical"] 不走行为脚本，_halt_npc 取消执行器也拦不住它。
##
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 90 \
##       --script res://test/test_visual_fairy_poi_hold.gd

var scene: Node
var frame := 0
var fails := 0
var entered := false        ## 已在 POI 飞行途中进入对话
var anchor := Vector2.ZERO  ## 进对话瞬间小仙子的位置
var drift := 0.0            ## 进对话后她漂移的最大距离
var poi_cleared := false    ## 对话中 POI 被丢弃（否则退出后会飞去一个过时的点）

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.ready.connect(_teleport)
	process_frame.connect(_tick)

## 与 test_visual_fairy_poi 同款布置：把玩家挪到池塘发现半径内，让 POI 必定触发。
func _teleport() -> void:
	var player: Dictionary = scene.get("player")
	var pos := TerrainMap.tile_center(Vector2i(24, 31))
	player["logical"] = pos
	OccupancyMap.char_register("player", pos, 2)
	var fairy: Dictionary = scene.call("_find_fairy")
	if not fairy.is_empty():
		fairy["logical"] = WorldGrid.wrap_pos(pos + Vector2(3.0, 2.0))
	scene.set("_fairy_greeted", true)
	scene.set("_fairy_chat_t", 9999.0)
	scene.set("_poi_check_t", 1.0)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	var fairy: Dictionary = scene.call("_find_fairy")
	if fairy.is_empty():
		return
	var poi: Dictionary = scene.get("_fairy_poi")

	# POI 起飞后（尚未说完台词）立刻进入与仙子的对话
	if not entered and not poi.is_empty() and not poi.get("spoke", false) and frame > 14:
		scene.call("_enter_interaction", fairy["node"])
		entered = true
		anchor = fairy["logical"]
		return

	if entered:
		drift = maxf(drift, WorldGrid.shortest_delta(fairy["logical"], anchor).length())
		if (scene.get("_fairy_poi") as Dictionary).is_empty():
			poi_cleared = true

	if frame == 80:
		# 悬浮微动是允许的（hover/呼吸），但不该被 POI 拽走：POI 飞行速度 speed_min=14/s，
		# 60 帧(=6 虚拟秒)足以飞出十几个单位，阈值 1.5 足够区分「停在原地」与「被拽飞」。
		_check("对话中小仙子停在原地（漂移 %.2f）" % drift, drift < 1.5, true)
		_check("对话中丢弃过时的 POI 提醒", poi_cleared, true)
		if fails == 0:
			print("visual_fairy_poi_hold PASS")
		else:
			printerr("visual_fairy_poi_hold FAILED: %d" % fails)
		quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
