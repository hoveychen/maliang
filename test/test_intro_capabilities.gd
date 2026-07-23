extends SceneTree
## intro 重做 P2 客户端能力回测（离线 demo 世界）：
## 1) intro_spawn_seed —— 具名种子村民登场：返回逻辑坐标、id=demo_<slug>、char_name 取自 SEED、
##    paper_action=pop_in 缩放弹出，数帧后 scale 收敛到 ONE；bench_despawn_load 不误删（非 bench_ 前缀）。
## 2) 点点 intro 编排 —— intro_fairy_fly_to 果断飞到注入点 → intro_fairy_arrived 转真 → 朝向注视点；
##    intro_fairy_release 释放后回漂移跟随。
## 3) intro_fairy_act —— 给点点挂 paper_action（挥笔=wave），键到时后 _update_action_anim 自动清除。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 120 \
##       --script res://test/test_intro_capabilities.gd

var scene: Node
var frame := 0
var fails := 0
var fairy: Dictionary = {}
var spawned: Dictionary = {}
var _arrived_frame := -1

func _initialize() -> void:
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
		3:
			_find_fairy()
			_test_spawn_seed()
		# pop_in（dur 0.7，fixed-fps 10）：登场先缩到近 0 再弹起。frame 4 已长了一拍，仍明显 < 1。
		4:
			var node := spawned["node"] as PaperCharacter
			_check("pop_in 起手在长大途中（scale.y=%.2f < 1）" % node.scale.y, node.scale.y < 0.75, true)
		8: # k≈0.7：easeOutBack 尾段冲过 1（弹性 overshoot），证明是「弹」出来不是线性长
			var node2 := spawned["node"] as PaperCharacter
			_check("pop_in overshoot 冲过 1（%.2f）" % node2.scale.y, node2.scale.y > 1.0, true)
		16: # pop_in 结束（>0.7s）：paper_action 键清除、scale 硬复位 ONE
			var node3 := spawned["node"] as PaperCharacter
			_check("pop_in 结束键清除", String(spawned.get("paper_action", "")) != "pop_in", true)
			_check("pop_in 结束 scale 复位 ONE", node3.scale, Vector3.ONE)
			# bench_despawn_load 不该误删具名种子村民（非 bench_ 前缀）
			var before := _count_npc(spawned["id"])
			scene.call("bench_despawn_load")
			_check("具名种子村民不被 bench_despawn_load 清除", _count_npc(spawned["id"]), before)
			_start_fairy_fly()
		# 点点飞向注入点：数帧内到位
		36:
			_check("点点已飞到 intro 目标点", bool(scene.call("intro_fairy_arrived")), true)
			if _arrived_frame < 0:
				_arrived_frame = frame
		40: # 到位数帧后：朝向注视点（注视点在左 → paper_face=PI）
			_check("点点朝向注视点（面左 PI）", is_equal_approx(float(fairy.get("paper_face", 0.0)), PI), true)
			# 挥笔表演：intro_fairy_act 给点点挂 paper_action
			scene.call("intro_fairy_act", "wave")
		42:
			_check("intro_fairy_act 挂上 paper_action", String(fairy.get("paper_action", "")), "wave")
			# 释放编排：回漂移跟随
			scene.call("intro_fairy_release")
			_check("release 后不再 arrived", bool(scene.call("intro_fairy_arrived")), false)
			_finish()

func _test_spawn_seed() -> void:
	var before := (scene.get("npcs") as Array).size()
	var target := Vector2(6.0, 0.0)
	var pos: Vector2 = scene.call("intro_spawn_seed", 0, target)
	_check("intro_spawn_seed 返回逻辑坐标", pos, WorldGrid.wrap_pos(target))
	_check("npcs 增加一个", (scene.get("npcs") as Array).size(), before + 1)
	spawned = (scene.get("npcs") as Array).back()
	_check("id 为 demo_<slug>", String(spawned.get("id", "")).begins_with("demo_"), true)
	var v: Dictionary = VillagerAssets.SEED[0]
	_check("id 用 SEED slug", spawned.get("id"), "demo_%s" % String(v["slug"]))
	_check("char_name 取自 SEED", (spawned["node"] as PaperCharacter).char_name, String(v["name"]))
	_check("登场即挂 pop_in", String(spawned.get("paper_action", "")), "pop_in")

func _start_fairy_fly() -> void:
	if fairy.is_empty():
		return
	var here: Vector2 = fairy["logical"]
	var target := WorldGrid.wrap_pos(here + Vector2(5.0, 0.0)) # 右前方 5 单位
	var face := WorldGrid.wrap_pos(here + Vector2(-10.0, 0.0)) # 注视点在左
	scene.call("intro_fairy_fly_to", target, face)
	_check("fly_to 后尚未到位", bool(scene.call("intro_fairy_arrived")), false)

func _find_fairy() -> void:
	for n in (scene.get("npcs") as Array):
		if bool((n as Dictionary).get("is_fairy", false)):
			fairy = n
	_check("找到点点", not fairy.is_empty(), true)

func _count_npc(id: Variant) -> int:
	var c := 0
	for n in (scene.get("npcs") as Array):
		if (n as Dictionary).get("id") == id:
			c += 1
	return c

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])

func _finish() -> void:
	if fails > 0:
		printerr("test_intro_capabilities: %d FAILED" % fails)
		quit(1)
	else:
		print("test_intro_capabilities: all passed")
		quit(0)
