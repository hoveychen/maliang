extends SceneTree
## 场面调度：开演后参演角色必须站定听调度，不能还在自主闲逛。
## 老板真机试演《丑小鸭》时的第三个症状——「是不是没关掉角色默认闲逛」：
## 村民降生时各挂了一个 loop 的 wander 执行器，开演后到第一条舞台命令下来之前
## （以及旁白/对白期间），三个演员在镜头里各走各的。
##
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 130 --script res://test/test_stage_staging.gd

const DRIFT_EPS := 0.3  ## 判定「站住没动」的容差（米）

var scene: Node
var frame := 0
var fails := 0
var _cast: Array = []      ## 参演的两位
var _bystander: Dictionary = {}
var _cast_pos: Array = []
var _bystander_pos := Vector2.ZERO

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	match frame:
		1: root.size = Vector2i(640, 360)
		12: _begin()
		14: _after_begin()
		95: _check_drift()
		97: _after_finish()

func _begin() -> void:
	var npcs: Array = scene.get("npcs")
	if npcs.size() < 3:
		printerr("  FAIL 世界里 NPC 不足三个，测不了场面调度")
		fails += 1
		_finish()
		return
	_cast = [npcs[0], npcs[1]]
	_bystander = npcs[2]
	_check("降生就挂了自主闲逛", _has_ambient(_cast[0]), true)

	var actors: Array = []
	for a in _cast:
		actors.append({ "id": String(a.get("id", "")), "name": (a["node"] as PaperCharacter).char_name, "isPlayer": false })
	scene.call("stage_begin", actors)
	_cast_pos = [_cast[0]["logical"], _cast[1]["logical"]]
	_bystander_pos = _bystander["logical"]

func _after_begin() -> void:
	_check("开演停掉了 1 号演员的闲逛", _has_ambient(_cast[0]), false)
	_check("开演停掉了 2 号演员的闲逛", _has_ambient(_cast[1]), false)
	_check("路人不受影响，照旧闲逛", _has_ambient(_bystander), true)

func _check_drift() -> void:
	# 开演到第一条舞台命令之间的那几秒：演员必须站在原地等调度
	for i in _cast.size():
		var moved := WorldGrid.shortest_delta(_cast[i]["logical"], _cast_pos[i]).length()
		_check("%d 号演员开演后站住没动（漂了 %.2f）" % [i + 1, moved], moved <= DRIFT_EPS, true)
	# 反证：闲逛执行器确实会让人走动，否则上面的断言是空的
	_check("路人这段时间确实晃了",
		WorldGrid.shortest_delta(_bystander["logical"], _bystander_pos).length() > DRIFT_EPS, true)
	scene.call("stage_finish", {}, false, "")

func _after_finish() -> void:
	_check("收场恢复 1 号演员的闲逛", _has_ambient(_cast[0]), true)
	_check("收场恢复 2 号演员的闲逛", _has_ambient(_cast[1]), true)
	_check("玩家没被挂上闲逛执行器", _has_ambient(scene.get("player")), false)
	_finish()

## 这个角色身上有没有**还活着**的自主闲逛执行器（cancel 过的要到下一帧才从表里摘掉）。
func _has_ambient(dict: Dictionary) -> bool:
	if dict.is_empty():
		return false
	for e in (scene.get("_executors") as Array):
		var ex := e as BehaviorExecutor
		if ex.ambient and not ex.is_done() and ex.drives(dict):
			return true
	return false

func _finish() -> void:
	# 在途 A* 任务的绑定 Callable 活到引擎关停会崩（见 test_scene_unload）
	for e in (scene.get("_executors") as Array):
		(e as BehaviorExecutor).cancel()
	if fails == 0:
		print("stage_staging PASS")
	else:
		printerr("stage_staging FAILED: %d" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % what)
	else:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1
