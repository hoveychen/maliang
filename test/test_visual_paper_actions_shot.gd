extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：16 种新纸片动作巡演截帧。
## 玩家立于村庄广场中央，按 ACTION_DUR 逐个演完 16 个新动作（间隔 4 帧），
## stdout 打印每个动作的帧区间，便于事后挑代表帧给老板过目。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 PITCH=26 DIST=8 \
##       godot --write-movie <目录>/act.png --fixed-fps 8 --quit-after 300 \
##       --script res://test/test_visual_paper_actions_shot.gd
## 环境变量：PITCH/DIST 调相机；ONLY=lie_down 只演一个动作（改完单动作快速复验）。
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

const FPS := 8
const GAP := 4      ## 动作间歇帧（回正呼吸）
const WARMUP := 10  ## 开场等地形/角色就位
const ALL_ACTIONS := [
	"flip", "backflip", "cartwheel", "twirl", "helicopter",
	"paperflip", "peek", "lie_down", "faceplant",
	"curl_up", "shiver", "wiggle", "puff",
	"bounce", "squish", "stretch",
	"fold", "bow_fold", "corner_wink", "paper_plane", "accordion", "crumple_ball",
]
var ACTIONS: Array = ALL_ACTIONS if OS.get_environment("ONLY").is_empty() \
		else Array(OS.get_environment("ONLY").split(","))

var scene: Node
var frame := 0
var _idx := -1      ## 当前动作序号（-1=warmup）
var _next_at := WARMUP

func _initialize() -> void:
	# 录像窗口置顶：带窗 --write-movie 在窗口被遮挡时会停止出帧（整段视频冻成一帧）
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var pitch := OS.get_environment("PITCH")
	if pitch != "":
		scene.set("_target_pitch", float(pitch))
	var dist := OS.get_environment("DIST")
	if dist != "":
		scene.set("_target_dist", float(dist))
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	frame += 1
	if frame == 1:
		player["logical"] = TerrainMap.tile_center(Vector2i(37, 41)) # 广场水井南侧空地取景（37,37 有井会挡人）
		for lbl in ["coord_label", "perf_label", "voice_prof_label"]: # 藏 debug 浮层，出干净成片
			var l: Variant = scene.get(lbl)
			if l != null and is_instance_valid(l):
				(l as Control).visible = false
		return
	_cleanup_stage() # 每帧幂等清场：NPC 是陆续 spawn 的，只在 frame 1 清会漏掉后到的
	if frame < _next_at:
		return
	_idx += 1
	if _idx >= ACTIONS.size():
		print("SHOT_DONE at frame %d" % frame)
		quit(0)
		return
	var a: String = ACTIONS[_idx]
	var dur := float(BehaviorExecutor.ACTION_DUR[a])
	player["paper_action"] = a
	player["paper_action_t"] = 0.0
	var frames := int(ceil(dur * FPS))
	print("SHOT %s frames %d..%d (dur %.1fs)" % [a, frame, frame + frames, dur])
	_next_at = frame + frames + GAP

## 幂等清场：藏全体 NPC（含仙子）+压聊天/打招呼演出+掐在途脚本。NPC 与其 ambient
## 脚本在加载后陆续出现，只在开场清一次会漏掉后到的，须每帧重申；
## in_chat 同时挡住 _resume_ambient 与 notice 的随机挥手。
func _cleanup_stage() -> void:
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()
	for n in (scene.get("npcs") as Array):
		n["in_chat"] = true
		n.erase("chat_with")
		var node := n["node"] as Node3D
		if node != null and is_instance_valid(node) and node.visible:
			node.visible = false
