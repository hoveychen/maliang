extends SceneTree
## bug#1 回归：站桩落点必须可通行——若首选侧被建筑/物件占用，改站对侧；两侧都站不下则不跳。
## 复现老板真机「玩家跳进房子里卡住」：进对话前把首选站位格占掉，断言玩家不落在被占格、
## 且落点 footprint 空闲(Pathfinder.cell_free)。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 30 --script res://test/test_visual_dialog_stage_blocked.gd

const W := preload("res://scripts/world.gd")
const GAP := 5.0

var scene: Node
var frame := 0
var fails := 0
var npc: Dictionary = {}
var blocked_cell := Vector2i.ZERO

func _initialize() -> void:
	var s := OS.get_environment("TEST_SEED")
	if not s.is_empty():
		seed(int(s))
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
			_setup_blocked_and_enter()
		15: # 小跳落定后检查
			_check_not_in_building()
		20:
			if fails == 0:
				print("visual_dialog_stage_blocked PASS")
			else:
				printerr("visual_dialog_stage_blocked FAILED: %d" % fails)
			quit(fails)

func _setup_blocked_and_enter() -> void:
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()
	npc = (scene.get("npcs") as Array)[0]
	var player: Dictionary = scene.get("player")
	var npc_l: Vector2 = npc["logical"]
	# 玩家从右侧接近 → 首选站位在 NPC 右侧 NPC+(GAP,0)
	player["logical"] = WorldGrid.wrap_pos(npc_l + Vector2(3.0, 0.0))
	OccupancyMap.char_register(String(player["id"]), player["logical"], int(player["span"]))
	# 用「房子」占掉首选站位格(4×4 格覆盖 player footprint)
	var pref := W.staged_logical(npc_l, player["logical"], GAP)
	blocked_cell = OccupancyMap.to_cell(pref)
	OccupancyMap.occupy_rect(blocked_cell - Vector2i(2, 2), 6, 6)
	scene.call("_enter_interaction", npc["node"])

func _check_not_in_building() -> void:
	var player: Dictionary = scene.get("player")
	var pl: Vector2 = player["logical"]
	var landed := OccupancyMap.to_cell(pl)
	# 落点 footprint 必须空闲(排除自己)——不能站进房子
	var free := Pathfinder.cell_free(landed, int(player["span"]), String(player["id"]))
	_check("player landed on a walkable cell (not inside building)", free, true)
	# 不能落在被占的首选格附近(至少离被占中心 > 2 格)
	var away := (Vector2(landed - blocked_cell)).length()
	_check("player avoided the blocked stage cell (dist=%.1f cells)" % away, away >= 2.0, true)
	# 无论站哪侧，都应面朝 NPC（从落点看 NPC 的水平方向）
	var fdx := WorldGrid.shortest_delta(npc["logical"], pl).x
	var want_face := 0.0 if fdx <= 0.0 else PI  # 玩家在 NPC 右(fdx>0)→朝左PI；左→朝右0
	_check("player faces npc from wherever it staged", is_equal_approx(float(player.get("paper_face", -9.0)), want_face), true)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [str(name), str(got), str(want)])
