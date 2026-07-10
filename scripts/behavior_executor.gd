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
const FOLLOW_NEAR := 3.4      ## 跟随保持距离：进到这个半径就停下等（别贴脸）
const FOLLOW_FAR := 5.0       ## 停下后目标拉开到这个半径才重新起步（滞回防抖）
const FOLLOW_REPLAN := 0.5    ## 跟随重寻路节流秒数（目标是移动的，路径持续过期）
const FLEE_NEAR := 5.0        ## 逃离触发半径：威胁进到此半径内就开逃
const FLEE_FAR := 8.0         ## 逃离解除半径：拉开到此半径外就停下歇着（滞回防抖）
const FLEE_STEP := 6.0        ## 每次逃跑规划的落点距离（沿背离威胁方向选点）
const FAIL_BACKOFF := 3.0     ## 寻路失败（无路/预算拒绝）后的重试退避（直线滑动顶着，防全图重搜打摆）

## do_action 动作时长（秒）。执行器按此阻塞，world.gd 动画层按同一张表演出（单一来源）。
const ACTION_DUR := { "wave": 1.6, "jump": 1.0, "spin": 1.1, "nod": 1.4 }
const CHAT_DUR := 6.0 ## chat_with 到达后的聊天演出时长（world.gd 气泡驱动按同一常量收尾）

var _target: Dictionary = {}
var _commands: Array = []
var _loop := false
## true = 自主闲逛（wait/wander 循环），非脚本任务。world 的「主动看你」环境演出在有
## 非 ambient（真实指令：送信/跑腿/靠近对话）执行器活跃时暂停，避免打断脚本化场景。
var ambient := false
var _idx := 0
var _state := "idle" ## idle | move | wait | follow | done
var _wait_t := 0.0
var _move_to := Vector2.ZERO
var _arrive_override := 0.0 ## 当前指令的到达半径覆盖（0 = 用默认 ARRIVE）

# 寻路状态：waypoint 队列 + 无路直线回退 + 被挡等待/重算
var _waypoints := PackedVector2Array()
var _wp_i := 0
var _direct := false      ## true = 无路回退，直接朝目标滑动（旧行为）
var _repath_wait := 0.0
var _repaths := 0

# 异步寻路（P2）：worker 线程离主线程跑 A*，主线程只拍快照 + 回收结果。
# 单执行器单飞（_plan_task!=-1 不叠）→ 在途任务数上界=角色数，无需全局闸；
# WorkerThreadPool 自身限线程级并发，多出的排队，主线程永不阻塞。
static var _orphans: Array = []           ## 执行器取消/推进遗留的在途任务，完成后由 _reap_orphans 集中回收（不阻塞、不泄漏）
var _plan_task := -1                       ## 在途 WorkerThreadPool 任务 id（-1=空闲）
var _plan_result := PackedVector2Array()   ## worker 写、主线程在任务完成后读（is_task_completed 为真=内存屏障，happens-after 安全）

# deliver_message：走到目标角色处把话传到
var _resolver := Callable()  ## (character_id:String) -> Vector2（找不到返回 Vector2.INF）
var _deliverer := Callable() ## (target_id:String, message:String) -> void
var _delivering := false
var _deliver_id := ""
var _deliver_msg := ""
var _chatting := false ## chat_with：到达目标后写 chat_with 契约键并停留聊天
var _deliver_track_t := 0.0 ## 送信/聊天目标是活人会走动：节流重解析坐标，别走到旧位置

# relay_command：跑腿传指令——点名指派不隔空遥控，走到执行者旁把脚本交给它
var _relayer := Callable()   ## (target_id:String, script:Dictionary) -> void
var _relay_script: Dictionary = {}

# 地点解析：location_name → 世界坐标（world.gd 的 POI 名/别名模糊匹配，找不到 Vector2.INF）
var _loc_resolver := Callable()

# follow/flee：持续跟随或逃离一个移动目标（玩家/角色），永不自行完成，由 cancel/新指令替换收尾。
# flee 与 follow 互斥（一个执行器只跑一条），共用这组追踪状态（目标名/是否在动/重规划节流）。
var _follow_id := ""
var _follow_moving := false
var _follow_replan_t := 0.0

func setup(target: Dictionary, script: Dictionary, resolver := Callable(), deliverer := Callable(), loc_resolver := Callable(), relayer := Callable()) -> void:
	_target = target
	_commands = script.get("commands", [])
	_loop = bool(script.get("loop", false))
	_resolver = resolver
	_deliverer = deliverer
	_loc_resolver = loc_resolver
	_relayer = relayer
	_idx = 0
	_state = "idle" if not _commands.is_empty() else "done"

func is_done() -> bool:
	return _state == "done"

## 外部中止：立即完成（玩家新点击替换旧指令、交互叫停 NPC）。
func cancel() -> void:
	_detach_task()  # 在途寻路任务转孤儿，完成后集中回收
	_state = "done"

## 是否在驱动这个角色字典（按引用同一性，防内容巧合相等）。
func drives(target: Dictionary) -> bool:
	return is_same(_target, target)

## 正在跟随的目标名（非 follow 状态返回空）：交互叫停时用于记住「还要继续跟」。
func following_id() -> String:
	return _follow_id if _state == "follow" else ""

func step(delta: float) -> void:
	if _state == "done":
		return
	_poll_plan()  # 回收自己/孤儿的在途寻路任务，完成则填 waypoint
	if _state == "idle":
		_start(_commands[_idx])
	match _state:
		"move": _step_move(delta)
		"wait": _step_wait(delta)
		"follow": _step_follow(delta)
		"flee": _step_flee(delta)

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
			# 目标预检：随机点落在占用格/水面就换一个（几次哈希查询）。不预检时
			# 落进房子/树丛/水里的目标会烧一次注定失败的全预算 A*（真机 ~300ms），
			# 十来个村民各自每几秒 wander 一次 = 「原地间歇掉帧」的持续来源。
			var radius := float(params.get("radius", 5.0))
			var picked := Vector2.INF
			for _try in range(6):
				var off := Vector2(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0) * radius
				var cand := WorldGrid.wrap_pos(_target["logical"] + off)
				if TerrainMap.tile_type(WorldGrid.to_tile(cand)) != TerrainMap.T_WATER \
						and Pathfinder.cell_free(OccupancyMap.to_cell(cand), _span(), _char_id()):
					picked = cand
					break
			if picked == Vector2.INF:
				_advance() # 周围全被占：这轮不逛，直接下一条指令
			else:
				_move_to = picked
				_begin_move()
		"wait":
			_wait_t = float(params.get("duration", 1.0))
			_state = "wait"
		"follow":
			_follow_id = String(params.get("target_name", params.get("target_id", "玩家")))
			if _resolver.is_valid() and _resolver.call(_follow_id) != Vector2.INF:
				_follow_moving = false
				_follow_replan_t = 0.0
				_state = "follow"
			else:
				_advance() ## 跟随目标解析不到 → 跳过
		"flee":
			_follow_id = String(params.get("target_name", params.get("target_id", "玩家")))
			if _resolver.is_valid() and _resolver.call(_follow_id) != Vector2.INF:
				_follow_moving = false
				_follow_replan_t = 0.0
				_state = "flee"
			else:
				_advance() ## 逃离目标解析不到 → 跳过
		"stop_follow":
			# 停止语义由「新脚本替换旧执行器」达成（旧 follow 已被 cancel）；
			# 这里只需清掉交互叫停时记下的「还要继续跟」标记。
			_target.erase("resume_follow")
			_advance()
		"do_action":
			# 写契约键（world.gd 动画层读 paper_action 演出并清除），阻塞动作时长再下一条
			var action := String(params.get("action", "wave"))
			if not ACTION_DUR.has(action):
				action = "wave"
			_target["paper_action"] = action
			_target["paper_action_t"] = 0.0
			_wait_t = float(ACTION_DUR[action])
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
		"chat_with":
			# 走到目标角色旁（复用送信走位），到达写 chat_with 契约键（world.gd 气泡驱动），停留聊完
			_deliver_id = String(params.get("character_name", params.get("to", "")))
			var cp := Vector2.INF
			if _resolver.is_valid():
				cp = _resolver.call(_deliver_id)
			if cp != Vector2.INF:
				_move_to = cp
				_delivering = true
				_chatting = true
				_begin_move()
			else:
				_advance() ## 解析不到聊天对象 → 跳过
		"relay_command":
			# 跑腿传指令：走到执行者旁（复用送信走位），到达把脚本交给它（_relayer 回调）
			_deliver_id = String(params.get("to", ""))
			_relay_script = params.get("script", {})
			var rp := Vector2.INF
			if _resolver.is_valid():
				rp = _resolver.call(_deliver_id)
			if rp != Vector2.INF and not _relay_script.is_empty():
				_move_to = rp
				_delivering = true
				_begin_move()
			else:
				_relay_script = {}
				_advance() ## 解析不到执行者/空脚本 → 跳过
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
	_waypoints = PackedVector2Array()  # 清旧队列：新目标的路算回前先直线兜底（异步不空窗）
	_wp_i = 0
	_plan_path()

## 派发一次异步寻路：主线程拍占用图快照，worker 线程跑 A*（离主线程，不阻塞帧）。
## 单飞——已有在途任务就不叠（跟随/送信按间隔重复调用时沿用旧队列直到新路算回）。
## 搜索上限 1500：NPC 走位都是近程（wander 半径 7m/跟随/送信到人旁），全图长搜索只
## 服务「目标不可达」病态用例，早认输走直线滑动、观感一致。
## （Pathfinder 的 budgeted 单帧预算不再需要——A* 已不占主线程，改单飞控在途量。）
func _plan_path() -> void:
	if _plan_task != -1:
		return
	_direct = _waypoints.is_empty()  # 派发期无队列→先直线滑动兜底；有旧队列→沿用不空窗
	var snap := OccupancyMap.snapshot()
	_plan_result = PackedVector2Array()
	_plan_task = WorkerThreadPool.add_task(
		_run_plan.bind(_target["logical"], _move_to, _span(), _char_id(), snap),
		true, "npc_pathfind")

## worker 线程体：只读不可变快照跑 A*，绝不碰任何节点/活占用图/SceneTree；
## 结果写 _plan_result，主线程在 is_task_completed 为真后（内存屏障）才读。
func _run_plan(from: Vector2, to: Vector2, sp: int, id: String, snap: OccSnapshot) -> void:
	_plan_result = Pathfinder.find_path(from, to, sp, id, true, 1500, false, snap)

## 主线程回收：孤儿任务 + 自己的在途任务；完成则搬结果、更新直线兜底标记。
func _poll_plan() -> void:
	_reap_orphans()
	if _plan_task == -1 or not WorkerThreadPool.is_task_completed(_plan_task):
		return
	WorkerThreadPool.wait_for_task_completion(_plan_task)  # 已完成，立即返回并回收任务槽
	_plan_task = -1
	_waypoints = _plan_result
	_wp_i = 0
	_direct = _waypoints.is_empty()  # 无路（不可达）→直线兜底 + FAIL_BACKOFF 退避重试

## 把在途任务转孤儿（推进/取消当前 move 指令时旧路已作废，但任务仍在跑，需回收防泄漏）。
func _detach_task() -> void:
	if _plan_task != -1:
		_orphans.append(_plan_task)
		_plan_task = -1

## 集中回收孤儿任务：完成的立即 reap，未完成的留到下次；不阻塞主线程。
static func _reap_orphans() -> void:
	if _orphans.is_empty():
		return
	var still: Array = []
	for t in _orphans:
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
		else:
			still.append(t)
	_orphans = still

## 关停时阻塞排干所有孤儿任务。WorkerThreadPool 在引擎关停时会销毁任务残留的
## 绑定 Callable（引用 GDScript 对象/快照），若此刻任务仍在途会崩（真机退出/回测
## 退出 exit 134）。关停允许阻塞，故直接 wait_for_task_completion 逐个收完。
## 调用方（world._exit_tree）须先 cancel 所有存活执行器把其在途任务转孤儿。
static func flush_all_blocking() -> void:
	for t in _orphans:
		WorkerThreadPool.wait_for_task_completion(t)
	_orphans.clear()

## 重寻路间隔：上次规划失败（无路/预算拒绝）时退避拉长——目标不可达时 A* 必烧满
## 预算（真机单次 ~100-300ms），按 0.5s 节拍全图重搜就是「原地间歇掉帧」的凶手。
func _replan_interval() -> float:
	return FAIL_BACKOFF if _direct else FOLLOW_REPLAN

func _step_move(delta: float) -> void:
	var cur: Vector2 = _target["logical"]
	# 送信/聊天的目标角色在走动：节流重解析，目标挪远了就更新终点重寻路
	if _delivering and _resolver.is_valid():
		_deliver_track_t -= delta
		if _deliver_track_t <= 0.0:
			var np: Vector2 = _resolver.call(_deliver_id)
			if np != Vector2.INF and WorldGrid.shortest_delta(np, _move_to).length() > 1.0:
				_move_to = np
				_plan_path()
			_deliver_track_t = _replan_interval()
	var arrive := DELIVER_ARRIVE if _delivering else (_arrive_override if _arrive_override > 0.0 else ARRIVE)
	if WorldGrid.shortest_delta(cur, _move_to).length() <= arrive:
		if _delivering:
			_delivering = false
			if _chatting:
				_chatting = false
				_target["chat_with"] = _deliver_id
				_target["chat_t"] = 0.0
				_wait_t = CHAT_DUR
				_state = "wait" # 站着聊完再走（气泡演出由 world.gd 驱动/收尾）
				return
			if not _relay_script.is_empty():
				var s := _relay_script
				_relay_script = {}
				if _relayer.is_valid():
					_relayer.call(_deliver_id, s) # 指令送到，执行者接棒
			elif _deliverer.is_valid():
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
		if _plan_task != -1:
			return # 首条路径还在 worker 里算，直线兜底暂时被挡是正常的——不计失败、不放弃，等 waypoint 到
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

## 持续跟随：目标在动，寻路节流重算；进 FOLLOW_NEAR 停下，拉开到 FOLLOW_FAR 再起步（滞回）。
## 被挡不放弃（目标走开自然解堵），目标消失（角色被移除）才结束。
func _step_follow(delta: float) -> void:
	var pos: Vector2 = _resolver.call(_follow_id) if _resolver.is_valid() else Vector2.INF
	if pos == Vector2.INF:
		_advance()
		return
	var cur: Vector2 = _target["logical"]
	var dist := WorldGrid.shortest_delta(cur, pos).length()
	if dist <= FOLLOW_NEAR:
		_follow_moving = false
		return
	if not _follow_moving and dist < FOLLOW_FAR:
		return
	if not _follow_moving:
		_follow_moving = true
		_follow_replan_t = 0.0
	_follow_replan_t -= delta
	if _follow_replan_t <= 0.0:
		_move_to = pos
		_plan_path()
		_follow_replan_t = _replan_interval()
	var sub := _move_to if _direct or _wp_i >= _waypoints.size() else _waypoints[_wp_i]
	var d := WorldGrid.shortest_delta(cur, sub)
	if not _direct and _wp_i < _waypoints.size() and d.length() <= WAYPOINT_ARRIVE:
		_wp_i += 1
		return
	var step_vec := d.normalized() * SPEED * delta
	if step_vec.length() > d.length():
		step_vec = d
	var moved := Mover.attempt(cur, step_vec, _span(), _char_id())
	if moved == cur:
		_follow_replan_t = 0.0 # 被挡：下帧重寻路，不计次不放弃
		return
	_target["logical"] = moved
	if _char_id() != "":
		OccupancyMap.char_register(_char_id(), moved, _span())

## 持续逃离：威胁进 FLEE_NEAR 就沿背离方向选点逃跑，拉开到 FLEE_FAR 停下歇着（滞回）。
## 被挡（逃路堵）下帧重规划另找方向，永不自行完成（由 cancel/新指令替换收尾）。
func _step_flee(delta: float) -> void:
	var threat: Vector2 = _resolver.call(_follow_id) if _resolver.is_valid() else Vector2.INF
	if threat == Vector2.INF:
		_advance() # 威胁消失（角色被移除）→ 结束逃离
		return
	var cur: Vector2 = _target["logical"]
	var away := WorldGrid.shortest_delta(threat, cur) # 从威胁指向自己
	var dist := away.length()
	if dist >= FLEE_FAR:
		_follow_moving = false
		return
	if not _follow_moving and dist > FLEE_NEAR:
		return # 处于 NEAR..FAR 且已停：继续歇着（滞回防抖）
	if not _follow_moving:
		_follow_moving = true
		_follow_replan_t = 0.0
	_follow_replan_t -= delta
	if _follow_replan_t <= 0.0:
		var dir := away.normalized() if dist > 0.01 else Vector2(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0).normalized()
		_move_to = WorldGrid.wrap_pos(cur + dir * FLEE_STEP)
		_plan_path()
		_follow_replan_t = _replan_interval()
	var sub := _move_to if _direct or _wp_i >= _waypoints.size() else _waypoints[_wp_i]
	var d := WorldGrid.shortest_delta(cur, sub)
	if not _direct and _wp_i < _waypoints.size() and d.length() <= WAYPOINT_ARRIVE:
		_wp_i += 1
		return
	var step_vec := d.normalized() * SPEED * delta
	if step_vec.length() > d.length():
		step_vec = d
	var moved := Mover.attempt(cur, step_vec, _span(), _char_id())
	if moved == cur:
		_follow_replan_t = 0.0 # 被挡：下帧重规划另找逃路，不计次不放弃
		return
	_target["logical"] = moved
	if _char_id() != "":
		OccupancyMap.char_register(_char_id(), moved, _span())

func _advance() -> void:
	_detach_task()  # 当前 move 指令结束，其在途路径作废——任务转孤儿待回收
	_idx += 1
	if _idx >= _commands.size():
		if _loop:
			_idx = 0
			_state = "idle"
		else:
			_state = "done"
	else:
		_state = "idle"
