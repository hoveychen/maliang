extends SceneTree
## POI 提醒验证：玩家在池塘发现半径内 → 小仙子朝池塘方向飞出（离开随身轨道）、
## 播 poi_pond 台词、说完飞回玩家身边。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie screenshots/poi/f.png \
##       --fixed-fps 10 --quit-after 130 --script res://test/test_visual_fairy_poi.gd
## headless 回测（无截图，仅断言）：把 --write-movie <路径> 换成 --headless，或直接跑
## scripts/test-headless.sh；退出码 = 失败断言数。

var scene: Node
var frame := 0
var fails := 0
var max_dist := 0.0   ## 小仙子离玩家的最大距离（应明显飞出去）
var spoke := false
var returned := false ## 说完台词后曾回到玩家身边

func _initialize() -> void:
	# 固定 RNG：FairyVoice.try_play 用 randi() 选台词，不同台词 WAV 时长不同→里程碑落定帧漂移、
	# 吃截止余量而间歇挂。无条件播种（TEST_SEED 可覆盖以复现）使选词确定、时长稳定。
	var s := OS.get_environment("TEST_SEED")
	seed(int(s) if not s.is_empty() else 20260718)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.ready.connect(_teleport)
	process_frame.connect(_tick)

## 把玩家挪到池塘边（tile 24,31 → 距池塘中心 14 单位 < 发现半径 20）。
func _teleport() -> void:
	var player: Dictionary = scene.get("player")
	var pos := TerrainMap.tile_center(Vector2i(24, 31))
	player["logical"] = pos
	OccupancyMap.char_register("player", pos, 2)
	var fairy: Dictionary = scene.call("_find_fairy")
	if not fairy.is_empty():
		fairy["logical"] = WorldGrid.wrap_pos(pos + Vector2(3.0, 2.0))
	# 只验证 POI 路径：跳过问候、禁掉闲聊，提早首次扫描
	scene.set("_fairy_greeted", true)
	scene.set("_fairy_chat_t", 9999.0)
	scene.set("_poi_check_t", 1.0)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	var player: Dictionary = scene.get("player")
	var fairy: Dictionary = scene.call("_find_fairy")
	if fairy.is_empty() or player.is_empty():
		return
	if frame > 12: # 传送稳定后开始记 POI 飞行距离
		var d := WorldGrid.shortest_delta(fairy["logical"], player["logical"]).length()
		max_dist = maxf(max_dist, d)
		var poi: Dictionary = scene.get("_fairy_poi")
		if not poi.is_empty() and poi.get("spoke", false):
			spoke = true
		# 飞回判定按事件记录而非只看末帧：headless 的 dummy 音频让台词瞬时"播完"，
		# 时间线整体前移，末帧时可能已在第二次 POI 提醒的飞出途中。
		if spoke and poi.is_empty() and d <= 6.5:
			returned = true
	if frame == 115:
		_check("fairy flew out to POI (max_dist=%.1f)" % max_dist, max_dist > 5.5, true)
		_check("poi line spoken", spoke, true)
		_check("fairy returned after speaking", returned, true)
		if fails == 0:
			print("visual_fairy_poi PASS")
		else:
			printerr("visual_fairy_poi FAILED: %d" % fails)
		quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
