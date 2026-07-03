extends SceneTree
## POI 提醒验证：玩家在池塘发现半径内 → 小仙子朝池塘方向飞出（离开随身轨道）、
## 播 poi_pond 台词、说完飞回玩家身边。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --write-movie screenshots/poi/f.png \
##       --fixed-fps 10 --quit-after 130 --script res://test/test_visual_fairy_poi.gd

var scene: Node
var frame := 0
var fails := 0
var max_dist := 0.0   ## 小仙子离玩家的最大距离（应明显飞出去）
var spoke := false

func _initialize() -> void:
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
		max_dist = maxf(max_dist, WorldGrid.shortest_delta(fairy["logical"], player["logical"]).length())
		var poi: Dictionary = scene.get("_fairy_poi")
		if not poi.is_empty() and poi.get("spoke", false):
			spoke = true
	if frame == 115:
		_check("fairy flew out to POI (max_dist=%.1f)" % max_dist, max_dist > 5.5, true)
		_check("poi line spoken", spoke, true)
		var back := WorldGrid.shortest_delta(fairy["logical"], player["logical"]).length()
		_check("fairy returned (dist=%.1f)" % back, back <= 6.5, true)
		if fails == 0:
			print("visual_fairy_poi PASS")
		else:
			printerr("visual_fairy_poi FAILED: %d" % fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
