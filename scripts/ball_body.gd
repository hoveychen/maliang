class_name BallBody
extends RefCounted
## C 档「玩家操纵物」的通用物理原语——一个能被踢、会滚、会摩擦停下、撞墙反弹的球。
## 游戏无关（踢球/躲避球/保龄球共用它，是四份不同的服务端脚本，见 realtime-game-primitives-design §3）：
## 这里只认「球怎么滚」，永远不知道自己在被哪个玩法用，也不知道「进球算谁的分」。
##
## 自写简化 2D 滚动（不用 Godot RigidBody——环面 wrap 下刚体接缝麻烦，见设计 §8 开放问题 4）：
##   速度积分 + 线性摩擦衰减 + 走 Mover 吃同一套地形/占用规则（撞墙）+ WorldGrid 环面 wrap。
## 坐标同角色：逻辑坐标 Vector2(x, z)，范围 [0, WORLD_SPAN)。step 是纯逻辑推进，渲染在 StageBall 节点。
##
## 权威（P2b）：host 默认拥有并模拟；踢者临时所有权 + 客户端预测/和解留 P2c（见设计 §5）。

const FRICTION := 7.0        ## 滚动摩擦减速度（世界单位/秒²）；一脚 kick power=12 约 1.7s / 10m 滚停
const RESTITUTION := 0.55    ## 撞墙反弹系数（0=吸收停死，1=完全弹回）；幼儿园手感偏软，留点弹性
const STOP_SPEED := 0.2      ## 低于此速视作滚停，速度清零（避免摩擦拖出无限小滑行尾巴）
const MAX_SPEED := 40.0      ## 速度硬顶，防脚本/预测给出离谱初速把球一帧甩穿半个世界

var logical := Vector2.ZERO  ## 球心逻辑坐标（环面 wrap 后）
var velocity := Vector2.ZERO ## 当前速度（世界单位/秒）
var span := 2                ## 占地边长（半格数，喂 Mover/OccupancyMap；球比角色小可后续调）
var _exclude_id := ""        ## 若球登记进角色层则排除自己（P2b 不登记，留空）

## 踢球（通用动词，非某玩法专属）：赋一个初速度。dir 会归一化，power 为世界单位/秒。
## 踢击本身由客户端玩家动作触发（不在服务端脚本），此原语只负责「被赋速后怎么滚」。
func kick(dir: Vector2, power: float) -> void:
	if dir.is_zero_approx() or power <= 0.0:
		return
	velocity = dir.normalized() * minf(power, MAX_SPEED)

## 复位/落位到某点：清零速度，wrap 回世界内。spawnBall / ball.reset 走这里。
func place(pos: Vector2) -> void:
	logical = WorldGrid.wrap_pos(pos)
	velocity = Vector2.ZERO

## 是否还在滚（速度高于滚停阈值）。owner 据此决定是否继续模拟 / 交回所有权（P2c）。
func is_rolling() -> bool:
	return velocity.length() > STOP_SPEED

## 推进一帧：先摩擦衰减，滚停即清零收工；否则按速度位移走 Mover（吃地形台阶/水/占用），
## 被挡的轴反弹（Mover 已做单轴滑动，据实际位移判断哪个轴被墙吃掉）。返回本帧是否仍在滚。
func step(delta: float) -> bool:
	if delta <= 0.0:
		return is_rolling()
	# 线性摩擦：匀减速逼近零（比指数衰减更像真实滚动摩擦，且能干净停死）
	velocity = velocity.move_toward(Vector2.ZERO, FRICTION * delta)
	if not is_rolling():
		velocity = Vector2.ZERO
		return false
	var intended := velocity * delta
	var moved := Mover.attempt(logical, intended, span, _exclude_id)
	var actual := WorldGrid.shortest_delta(logical, moved)  # 实际发生的位移（环面最短）
	# 某轴实际位移明显短于意图 → 被墙吃掉 → 该轴速度反弹并按 RESTITUTION 衰减
	var eps := 0.001
	if absf(actual.x) < absf(intended.x) - eps:
		velocity.x = -velocity.x * RESTITUTION
	if absf(actual.y) < absf(intended.y) - eps:
		velocity.y = -velocity.y * RESTITUTION
	logical = moved
	# 反弹后可能已低于滚停阈值：再判一次，撞墙软停不留残速
	if not is_rolling():
		velocity = Vector2.ZERO
		return false
	return true
