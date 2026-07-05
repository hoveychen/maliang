class_name BehaviorExecutor
extends RefCounted
## 执行后端下发的行为脚本，驱动角色在环面上移动（移植 worldlet 思路）。
## 作用于一个可变字典 { "logical": Vector2, ... }（角色逻辑坐标）；移动走 WorldGrid wrap。

const SPEED := 8.0 ## 世界单位/秒
const ARRIVE := 1.0
const DELIVER_ARRIVE := 2.6   ## 送信到达半径：目标角色自身占格，只能走到旁边半格（~1.6m）
const WAYPOINT_ARRIVE := 0.6  ## waypoint 切换半径（半格 1m 内够近即换下一个）
const REPATH_WAIT := 0.6      ## 被挡（多为角色互撞）后原地等待再重算的秒数
const REPATH_MAX := 3         ## 单条指令内允许的重算次数，超过弃指令防死磨

var _target: Dictionary = {}
var _commands: Array = []
var _loop := false
var _idx := 0
var _state := "idle" ## idle | move | wait | done
var _wait_t := 0.0
var _move_to := Vector2.ZERO
var _arrive_override := 0.0 ## 当前指令的到达半径覆盖（0 = 用默认 ARRIVE）

# 寻路状态：waypoint 队列 + 无路直线回退 + 被挡等待/重算
var _waypoints := PackedVector2Array()
var _wp_i := 0
var _direct := false      ## true = 无路回退，直接朝目标滑动（旧行为）
var _repath_wait := 0.0
var _repaths := 0

# deliver_message：走到目标角色处把话传到
var _resolver := Callable()  ## (character_id:String) -> Vector2（找不到返回 Vector2.INF）
var _deliverer := Callable() ## (target_id:String, message:String) -> void
var _delivering := false
var _deliver_id := ""
var _deliver_msg := ""

# 地点解析：location_name → 世界坐标（world.gd 的 POI 名/别名模糊匹配，找不到 Vector2.INF）
var _loc_resolver := Callable()

func setup(target: Dictionary, script: Dictionary, resolver := Callable(), deliverer := Callable(), loc_resolver := Callable()) -> void:
	_target = target
	_commands = script.get("commands", [])
	_loop = bool(script.get("loop", false))
	_resolver = resolver
	_deliverer = deliverer
	_loc_resolver = loc_resolver
	_idx = 0
	_state = "idle" if not _commands.is_empty() else "done"

func is_done() -> bool:
	return _state == "done"

## 外部中止：立即完成（玩家新点击替换旧指令、交互叫停 NPC）。
func cancel() -> void:
	_state = "done"

## 是否在驱动这个角色字典（按引用同一性，防内容巧合相等）。
func drives(target: Dictionary) -> bool:
	return is_same(_target, target)

func step(delta: float) -> void:
	if _state == "done":
		return
	if _state == "idle":
		_start(_commands[_idx])
	match _state:
		"move": _step_move(delta)
		"wait": _step_wait(delta)

func _start(cmd: Dictionary) -> void:
	var type := String(cmd.get("type", ""))
	var params: Dictionary = cmd.get("params", {})
	_arrive_override = float(params.get("arrive", 0.0)) ## >0 覆盖 move_to 到达半径（走到对象旁边停）
	match type:
		"move_to":
			_move_to = _resolve_target(params)
			if _move_to == Vector2.INF:
				_advance() ## 地点/角色都解析不到 → 跳过（不再假装位移糊弄）
				return
			_begin_move()
		"wander":
			var radius := float(params.get("radius", 5.0))
			var off := Vector2(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0) * radius
			_move_to = WorldGrid.wrap_pos(_target["logical"] + off)
			_begin_move()
		"wait":
			_wait_t = float(params.get("duration", 1.0))
			_state = "wait"
		"deliver_message":
			_deliver_id = String(params.get("to_character_id", params.get("to", "")))
			_deliver_msg = String(params.get("message", ""))
			var p := Vector2.INF
			if _resolver.is_valid():
				p = _resolver.call(_deliver_id)
			if p != Vector2.INF:
				_move_to = p
				_delivering = true
				_begin_move()
			else:
				_advance() ## 解析不到目标角色 → 跳过
		_:
			_advance() ## say / emote / face 等暂跳过（动作由 UI 层处理）

## move_to 目标解析：显式坐标 > 角色名（去某人身边）> 地点名（POI 模糊匹配）。解析不到返回 INF。
func _resolve_target(params: Dictionary) -> Vector2:
	if params.has("target") and params["target"] is Array and (params["target"] as Array).size() >= 2:
		var t: Array = params["target"]
		return WorldGrid.wrap_pos(Vector2(float(t[0]), float(t[1])))
	if params.has("tile_x") and params.has("tile_y"):
		return WorldGrid.wrap_pos(Vector2(float(params["tile_x"]), float(params["tile_y"])) * WorldGrid.TILE_SIZE)
	var char_name := String(params.get("character_name", ""))
	if not char_name.is_empty() and _resolver.is_valid():
		var p: Vector2 = _resolver.call(char_name)
		if p != Vector2.INF:
			_arrive_override = DELIVER_ARRIVE # 对方自身占格，走到旁边即算到
		return p
	var loc := String(params.get("location_name", ""))
	if not loc.is_empty() and _loc_resolver.is_valid():
		return _loc_resolver.call(loc)
	return Vector2.INF

## 进入 move 状态：规划 waypoint 队列；无路（目标不可达/已在原格）回退直线滑动。
func _begin_move() -> void:
	_state = "move"
	_repaths = 0
	_repath_wait = 0.0
	_plan_path()

func _plan_path() -> void:
	_waypoints = Pathfinder.find_path(_target["logical"], _move_to, _span(), _char_id())
	_wp_i = 0
	_direct = _waypoints.is_empty()

func _step_move(delta: float) -> void:
	var cur: Vector2 = _target["logical"]
	var arrive := DELIVER_ARRIVE if _delivering else (_arrive_override if _arrive_override > 0.0 else ARRIVE)
	if WorldGrid.shortest_delta(cur, _move_to).length() <= arrive:
		if _delivering:
			_delivering = false
			if _deliverer.is_valid():
				_deliverer.call(_deliver_id, _deliver_msg)
		_advance()
		return
	if _repath_wait > 0.0:
		_repath_wait -= delta # 被挡后原地等一拍（让对方走开），再从当前位置局部重算
		if _repath_wait <= 0.0:
			_plan_path()
		return
	# 子目标：当前 waypoint；队列走完（或直线回退）后收尾到精确目标
	var sub := _move_to if _direct or _wp_i >= _waypoints.size() else _waypoints[_wp_i]
	var d := WorldGrid.shortest_delta(cur, sub)
	if not _direct and _wp_i < _waypoints.size() and d.length() <= WAYPOINT_ARRIVE:
		_wp_i += 1
		return
	var step_vec := d.normalized() * SPEED * delta
	if step_vec.length() > d.length():
		step_vec = d
	# 统一走 Mover：地形台阶规则 + 物件占地 + 角色互撞（整步不行退化单轴滑动）
	var moved := Mover.attempt(cur, step_vec, _span(), _char_id())
	if moved == cur:
		_repaths += 1
		if _repaths > REPATH_MAX:
			_advance() # 反复被挡（目标被围死等）：放弃当前指令，避免原地磨墙
			return
		_repath_wait = REPATH_WAIT
		return
	_target["logical"] = moved
	if _char_id() != "":
		OccupancyMap.char_register(_char_id(), moved, _span()) # 角色层迁移

func _span() -> int:
	return int(_target.get("span", 2))

func _char_id() -> String:
	return String(_target.get("id", ""))

func _step_wait(delta: float) -> void:
	_wait_t -= delta
	if _wait_t <= 0.0:
		_advance()

func _advance() -> void:
	_idx += 1
	if _idx >= _commands.size():
		if _loop:
			_idx = 0
			_state = "idle"
		else:
			_state = "done"
	else:
		_state = "idle"
