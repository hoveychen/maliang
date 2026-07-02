class_name BehaviorExecutor
extends RefCounted
## 执行后端下发的行为脚本，驱动角色在环面上移动（移植 worldlet 思路）。
## 作用于一个可变字典 { "logical": Vector2, ... }（角色逻辑坐标）；移动走 WorldGrid wrap。

const SPEED := 8.0 ## 世界单位/秒
const ARRIVE := 1.0

var _target: Dictionary = {}
var _commands: Array = []
var _loop := false
var _idx := 0
var _state := "idle" ## idle | move | wait | done
var _wait_t := 0.0
var _move_to := Vector2.ZERO

# deliver_message：走到目标角色处把话传到
var _resolver := Callable()  ## (character_id:String) -> Vector2（找不到返回 Vector2.INF）
var _deliverer := Callable() ## (target_id:String, message:String) -> void
var _delivering := false
var _deliver_id := ""
var _deliver_msg := ""

func setup(target: Dictionary, script: Dictionary, resolver := Callable(), deliverer := Callable()) -> void:
	_target = target
	_commands = script.get("commands", [])
	_loop = bool(script.get("loop", false))
	_resolver = resolver
	_deliverer = deliverer
	_idx = 0
	_state = "idle" if not _commands.is_empty() else "done"

func is_done() -> bool:
	return _state == "done"

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
	match type:
		"move_to":
			_move_to = _resolve_target(params)
			_state = "move"
		"wander":
			var radius := float(params.get("radius", 5.0))
			var off := Vector2(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0) * radius
			_move_to = WorldGrid.wrap_pos(_target["logical"] + off)
			_state = "move"
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
				_state = "move"
			else:
				_advance() ## 解析不到目标角色 → 跳过
		_:
			_advance() ## say / emote / face 等暂跳过（动作由 UI 层处理）

## move_to 目标解析：优先显式坐标；location_name 暂无法解析时给一个可见的示意位移。
func _resolve_target(params: Dictionary) -> Vector2:
	if params.has("target") and params["target"] is Array and (params["target"] as Array).size() >= 2:
		var t: Array = params["target"]
		return WorldGrid.wrap_pos(Vector2(float(t[0]), float(t[1])))
	if params.has("tile_x") and params.has("tile_y"):
		return WorldGrid.wrap_pos(Vector2(float(params["tile_x"]), float(params["tile_y"])) * WorldGrid.TILE_SIZE)
	# TODO(M2-real): location_name → 世界坐标（需把世界角色/地点清单喂给意图 LLM）
	return WorldGrid.wrap_pos(_target["logical"] + Vector2(24.0, 0.0))

func _step_move(delta: float) -> void:
	var cur: Vector2 = _target["logical"]
	var d := WorldGrid.shortest_delta(cur, _move_to)
	if d.length() <= ARRIVE:
		if _delivering:
			_delivering = false
			if _deliverer.is_valid():
				_deliverer.call(_deliver_id, _deliver_msg)
		_advance()
		return
	var step_vec := d.normalized() * SPEED * delta
	if step_vec.length() > d.length():
		step_vec = d
	# 统一走 Mover：地形台阶规则 + 物件占地阻挡（整步不行退化单轴滑动）
	var moved := Mover.attempt(cur, step_vec, int(_target.get("span", 2)))
	if moved == cur:
		_advance() # 被崖壁/水/物件挡死：放弃当前指令，避免原地磨墙
		return
	_target["logical"] = moved

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
