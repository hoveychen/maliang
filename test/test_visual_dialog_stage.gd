extends SceneTree
## 对话站桩 + 构图相机的 world 层集成断言（离线 demo 世界）：
##  1) 进对话时玩家按进入侧（dx 符号）带弧线小跳到 NPC 对侧 STAGE_GAP 处，双方转脸相对；
##  2) 相机距离/焦点缓动到「双方构图」：最高者占屏中间 50%（对话态放开 ZOOM_MIN），焦点竖直抬升；
##  3) 说话人判定随状态切换（等玩家=player / 思考中=idle）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_visual_dialog_stage.gd

const W := preload("res://scripts/world.gd")
const GAP := 5.0  ## = World.STAGE_GAP

var scene: Node
var frame := 0
var fails := 0
var npc: Dictionary = {}
var staged_expect := Vector2.ZERO

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
		root.size = Vector2i(1280, 720) # headless 假视口 64×64，须先设成带窗尺寸
	match frame:
		4:
			_setup_and_enter()
		5:
			_check_entered()
		12: # 小跳 0.32s（~3 帧）后应落定站位
			_check_staged()
		25: # 相机缓动收敛：距离贴近双方构图、焦点竖直抬升
			_check_framing()
			_check_speaker_states()
		30:
			_exit_and_check()
		35:
			if fails == 0:
				print("visual_dialog_stage PASS")
			else:
				printerr("visual_dialog_stage FAILED: %d" % fails)
			quit(fails)

## 冻结漫游，把玩家摆到 NPC 右侧（+x）近处，再进对话——玩家应跳到 NPC 右侧 GAP 处。
func _setup_and_enter() -> void:
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()
	npc = (scene.get("npcs") as Array)[0]
	var player: Dictionary = scene.get("player")
	var npc_l: Vector2 = npc["logical"]
	player["logical"] = WorldGrid.wrap_pos(npc_l + Vector2(3.0, 0.0)) # 从右侧接近
	OccupancyMap.char_register(String(player["id"]), player["logical"], int(player["span"]))
	staged_expect = W.staged_logical(npc_l, player["logical"], GAP)
	scene.call("_enter_interaction", npc["node"])

func _check_entered() -> void:
	var player: Dictionary = scene.get("player")
	_check("locked onto npc", scene.get("_locked") == npc["node"], true)
	_check("hop armed", bool(player.get("_hop", false)), true)
	# 从右侧来：玩家面朝左(PI)对着 NPC，NPC 面朝右(0)对着玩家
	_check("player faces npc (left)", is_equal_approx(float(player.get("paper_face", 0.0)), PI), true)
	_check("npc faces player (right)", is_equal_approx(float(npc.get("paper_face", -1.0)), 0.0), true)
	# 站位在 NPC 右侧、离 NPC 恰好 GAP
	_check("stage on right side (dx>0)", WorldGrid.shortest_delta(npc["logical"], staged_expect).x > 0.0, true)
	_check("stage gap == STAGE_GAP", WorldGrid.shortest_delta(npc["logical"], staged_expect).length(), GAP)

func _check_staged() -> void:
	var player: Dictionary = scene.get("player")
	_check("hop finished", player.has("_hop"), false)
	_check("hover cleared", player.has("hover"), false)
	var off := WorldGrid.shortest_delta(player["logical"], staged_expect).length()
	_check("player landed on stage (off=%.2f)" % off, off < 0.3, true)
	# bug#2 回归：小跳落定后玩家仍面朝 NPC（右侧来→朝左 PI），不被小跳位移方向翻反
	_check("player still faces npc after hop (face=%.2f)" % float(player.get("paper_face", -9.0)),
			is_equal_approx(float(player.get("paper_face", -9.0)), PI), true)

func _check_framing() -> void:
	# 双方占位形象都是 3.2 单位（PLACEHOLDER_HEIGHT）→ 基础构图距离 = 3.2 / (2*0.5*tan25°) ≈ 6.86
	var expect := 3.2 / (2.0 * 0.5 * 0.4663077)
	var dist := float(scene.get("_cur_dist"))
	_check("camera dist eased to framing (dist=%.2f, want≈%.2f)" % [dist, expect], absf(dist - expect) < 1.5, true)
	# 对话态允许比 god 态 ZOOM_MIN(16) 近得多
	_check("dialog dist below god ZOOM_MIN", dist < 16.0, true)
	# 焦点竖直抬升把双方框在屏幕中段（lift≈1.6，地面≥0）
	var fy := float(scene.get("_cur_focus_y"))
	_check("focus lifted for vertical centering (fy=%.2f)" % fy, fy > 1.0, true)

func _check_speaker_states() -> void:
	# 默认（开放麦静待、无 TTS、无思考）= 玩家侧
	_check("default speaker = player (waiting)", scene.call("_dialog_speaker"), "player")
	# 思考中 = 构图归中（idle）
	scene.set("thinking_label", scene.get("thinking_label")) # no-op，保持引用
	var tl: Label = scene.get("thinking_label")
	tl.visible = true
	_check("thinking → idle", scene.call("_dialog_speaker"), "idle")
	tl.visible = false
	_check("back to player after thinking", scene.call("_dialog_speaker"), "player")

func _exit_and_check() -> void:
	scene.call("_exit_interaction")
	var player: Dictionary = scene.get("player")
	_check("unlocked on exit", scene.get("_locked") == null, true)
	_check("no dangling hop after exit", player.has("_hop"), false)
	_check("target dist restored to god", is_equal_approx(float(scene.get("_target_dist")), 23.0), true)

func _check(name: String, got: Variant, want: Variant) -> void:
	if typeof(got) == TYPE_FLOAT and typeof(want) == TYPE_FLOAT:
		if absf(got - want) < 1e-3:
			print("  ok %s" % name)
			return
	elif got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
