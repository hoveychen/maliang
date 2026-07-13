extends SceneTree
## 引路（fairy-guide）验证：服务端下发 GuidePlan → 小仙子飞在【玩家与目标之间】领路（离开随身轨道，
## 但不超过 GUIDE_FLY_CAP，始终在视野里）→ 小朋友走到目标 → 引路收尾（说「到啦」、取消按钮收起）。
## 另验取消入口：「不去了」按钮一点即停。
##
## 关键契约：引路【不碰玩家的 avatar】——她只是飞在前面，走路的是小朋友。所以本测试全程
## 不驱动 player，靠直接改 player["logical"] 模拟「他自己走过去了」。
## 运行：scripts/test-headless.sh（退出码 = 失败断言数）

var scene: Node
var frame := 0
var fails := 0

const START_TILE := Vector2i(10, 10)
const GOAL_TILE := Vector2i(40, 40)

var max_lead := 0.0      ## 引路中仙子离玩家的最远距离（应明显领飞出去）
var min_dot := 1.0       ## 仙子方向与「玩家→目标」方向的最小点积（应始终朝目标那边领）
var btn_shown := false   ## 引路中「不去了」按钮曾可见
var arrived := false     ## 玩家走到目标后引路自行收尾

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.ready.connect(_setup)
	process_frame.connect(_tick)

func _setup() -> void:
	var player: Dictionary = scene.get("player")
	var pos := TerrainMap.tile_center(START_TILE)
	player["logical"] = pos
	OccupancyMap.char_register("player", pos, 2)
	var fairy: Dictionary = scene.call("_find_fairy")
	if not fairy.is_empty():
		fairy["logical"] = WorldGrid.wrap_pos(pos + Vector2(3.0, 2.0))
	# 只验证引路：跳过问候/闲聊，别让 POI 提醒插进来抢她
	scene.set("_fairy_greeted", true)
	scene.set("_fairy_chat_t", 9999.0)
	scene.set("_poi_check_t", 9999.0)

func _plan(tile: Vector2i) -> Dictionary:
	return {
		"targetKind": "location",
		"targetName": "小山坡",
		"targetScene": "village",
		"targetTile": { "tileX": tile.x, "tileY": tile.y },
		"legs": [],  # 同场景：不需要走 portal
	}

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	var player: Dictionary = scene.get("player")
	var fairy: Dictionary = scene.call("_find_fairy")
	if fairy.is_empty() or player.is_empty():
		return

	if frame == 10:
		scene.call("start_guide", _plan(GOAL_TILE))

	# ── 领飞阶段：她该飞到玩家与目标之间 ──
	if frame > 14 and frame < 60:
		var guide: Dictionary = scene.get("_fairy_guide")
		if not guide.is_empty():
			var to_fairy := WorldGrid.shortest_delta(player["logical"], fairy["logical"])
			var to_goal := WorldGrid.shortest_delta(player["logical"], TerrainMap.tile_center(GOAL_TILE))
			max_lead = maxf(max_lead, to_fairy.length())
			if to_fairy.length() > 1.0:
				min_dot = minf(min_dot, to_fairy.normalized().dot(to_goal.normalized()))
			var btn: Button = scene.get("guide_stop_button")
			if btn != null and btn.visible:
				btn_shown = true

	if frame == 60:
		_check("领飞出去（离玩家 %.1f，随身轨道约 3.2）" % max_lead, max_lead > 6.0, true)
		_check("始终朝目标方向领（min_dot=%.2f）" % min_dot, min_dot > 0.8, true)
		_check("不飞出视野（≤ GUIDE_FLY_CAP=12）", max_lead <= 12.5, true)
		_check("「不去了」按钮在引路中可见", btn_shown, true)
		# 模拟小朋友自己走到了目标（引路不碰他的 avatar，是他自己走的）
		player["logical"] = TerrainMap.tile_center(GOAL_TILE)

	if frame > 62 and frame < 80:
		if (scene.get("_fairy_guide") as Dictionary).is_empty():
			arrived = true

	if frame == 80:
		_check("玩家到达目标后引路自行收尾", arrived, true)
		var btn: Button = scene.get("guide_stop_button")
		_check("收尾后按钮收起", btn == null or not btn.visible, true)
		# ── 取消入口：再起一段引路，点「不去了」 ──
		# 目标必须换成【远离玩家当前位置】的点：他此刻正站在 GOAL_TILE 上，
		# 拿同一个目标再引一次会当场判定「已到达」直接收尾——那是对的行为，但测不到取消。
		scene.call("start_guide", _plan(START_TILE))

	if frame == 84:
		_check("取消前引路在进行中", not (scene.get("_fairy_guide") as Dictionary).is_empty(), true)
		scene.call("_on_guide_stop_pressed")

	if frame == 88:
		_check("点「不去了」即停", (scene.get("_fairy_guide") as Dictionary).is_empty(), true)
		var btn: Button = scene.get("guide_stop_button")
		_check("取消后按钮收起", btn == null or not btn.visible, true)
		if fails == 0:
			print("fairy_guide PASS")
		else:
			printerr("fairy_guide FAILED: %d" % fails)
		quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
