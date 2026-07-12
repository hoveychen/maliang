extends SceneTree
## 20 种纸片动作回测：
## 1) 纯函数层——world.action_pose 对 ACTION_DUR 全部动作逐一采样：中段必须真的在动
##    （旋转/位移/缩放/shader 形变至少一项非恒等）、数值有限、未知动作返回恒等。
## 2) world 集成层——离线 demo 世界里对真村民演 squish/paperflip：
##    scale 动作生效且结束后硬复位 ONE、旋转动作叠加到姿态上、契约键到时自动清除。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_paper_actions.gd

const WorldScript := preload("res://scripts/world.gd")

var scene: Node
var frame := 0
var fails := 0
var green: Dictionary = {}
var _base_ry := 0.0

func _initialize() -> void:
	var s := OS.get_environment("TEST_SEED")
	if not s.is_empty():
		seed(int(s))
	_test_action_pose_math() # 纯函数层不用等场景
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

## 纯函数层：全部 20 种动作的动画数学逐一体检。
func _test_action_pose_math() -> void:
	_check("action table has 20 entries", BehaviorExecutor.ACTION_DUR.size(), 20)
	for a in BehaviorExecutor.ACTION_DUR:
		var dur := float(BehaviorExecutor.ACTION_DUR[a])
		var moved := false
		var finite := true
		for kf in [0.15, 0.5, 0.85]: # 三个采样点：起收包络下中段至少一处非恒等
			var p: Dictionary = WorldScript.action_pose(String(a), dur * float(kf), dur)
			var rot := p["rot"] as Vector3
			var sc := p["scale"] as Vector3
			var y := float(p["y"])
			if not (rot.is_finite() and sc.is_finite() and is_finite(y)):
				finite = false
			if rot != Vector3.ZERO or y != 0.0 or sc != Vector3.ONE or p.has("motion"):
				moved = true
			if p.has("motion") and not (p["motion"] as Vector2).is_finite():
				finite = false
		_check("%s does something mid-action" % a, moved, true)
		_check("%s pose is finite" % a, finite, true)
	# 未知动作：恒等姿态（fallback 由 BehaviorExecutor 层负责，这里不装死）
	var pu: Dictionary = WorldScript.action_pose("moonwalk", 0.5, 1.0)
	_check("unknown action is identity",
		pu["rot"] == Vector3.ZERO and float(pu["y"]) == 0.0
		and pu["scale"] == Vector3.ONE and not pu.has("motion"), true)
	# 起步平滑：k≈0 时 scale 类动作不许瞬间跳变（防"啪一下压扁"）
	for a2 in ["bounce", "squish", "stretch", "puff", "shiver"]:
		var p0: Dictionary = WorldScript.action_pose(a2, 0.01, float(BehaviorExecutor.ACTION_DUR[a2]))
		var sc0 := p0["scale"] as Vector3
		_check("%s starts near identity scale" % a2, sc0.distance_to(Vector3.ONE) < 0.15, true)

## world 集成层时间线。
func _tick() -> void:
	if scene == null:
		return
	frame += 1
	if frame == 1:
		root.size = Vector2i(1280, 720)
	match frame:
		3:
			_find_green()
			_freeze()
		# —— squish：scale 动作生效 + 结束硬复位 ——
		6:
			green["paper_action"] = "squish"
			green["paper_action_t"] = 0.0
		9: # t≈0.3s（dur 1.2，hold 段内）：压扁生效
			var node := green["node"] as PaperCharacter
			_check("squish squashes scale.y (%.2f)" % node.scale.y, node.scale.y < 0.9, true)
			_check("squish widens scale.x (%.2f)" % node.scale.x, node.scale.x > 1.1, true)
		10: # 快进到临近结束
			green["paper_action_t"] = 1.15
		13:
			var node2 := green["node"] as PaperCharacter
			_check("squish key cleared", String(green.get("paper_action", "")) != "squish", true)
			_check("scale hard-reset to ONE", node2.scale, Vector3.ONE)
		# —— paperflip：旋转叠加在姿态上（翻面露背） ——
		16: # 站定几帧后记基准朝向
			_base_ry = (green["node"] as PaperCharacter).rotation.y
			green["paper_action"] = "paperflip"
			green["paper_action_t"] = 0.7 # dur 1.8 → k≈0.39，hold 段（rot.y+=PI）
		18:
			var node3 := green["node"] as PaperCharacter
			var dy := absf(node3.rotation.y - _base_ry)
			_check("paperflip adds ~PI yaw (dy=%.2f)" % dy, dy > 2.0, true)
			green.erase("paper_action") # 外部清键路径：scale 回正兜底不该报错
			green.erase("paper_action_t")
		25:
			var node4 := green["node"] as PaperCharacter
			_check("after external erase scale settles", node4.scale, Vector3.ONE)
			_finish()

func _find_green() -> void:
	for n in (scene.get("npcs") as Array):
		if (n["node"] as PaperCharacter).char_name == "灵狐小围巾":
			green = n
	_check("demo npc found", not green.is_empty(), true)

## 冻结漫游/清掉在途执行器：只考动作层本身，防 wander 位移与 notice 挥手干扰。
## in_chat 标记挡住 _resume_ambient 的自动恢复与 notice 的随机挥手（否则朝向会漂，
## paperflip 的基准 rotation.y 断言变 flaky）。
func _freeze() -> void:
	for ex in (scene.get("_executors") as Array):
		(ex as BehaviorExecutor).cancel()
	green["in_chat"] = true

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])

func _finish() -> void:
	if fails > 0:
		printerr("test_paper_actions: %d FAILED" % fails)
		quit(1)
	else:
		print("test_paper_actions: all passed")
		quit(0)
