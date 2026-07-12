class_name BallOwnership
extends RefCounted
## C 档「玩家操纵物」的所有权状态机（游戏无关原语，见 realtime-game-primitives-design §4/§5）。
## 一个球任一时刻恰好一个模拟者：中立态由 host 模拟，被踢后临时转给踢者（本地权威、零延迟），
## 滚停后交回中立（host）。这解决「球死活归 host、非 host 踢球要一个 RTT 才动」（§5 杠杆 2）。
## 纯状态（不持球体/节点），便于 headless 状态机单测；踢击输入接线与真机手感见 P3。
##
## owner_id 语义：""＝中立（host 模拟）；非空＝某玩家 id（该玩家本地模拟并广播球位置）。
## 各端独立跑同一台状态机，靠 ball_kick / ball_settle 广播驱动同一组转移，达成所有权共识。

const NEUTRAL := ""  ## 中立所有者：由 host 模拟

var owner_id: String = NEUTRAL

## 踢击：把临时所有权转给踢者。返回是否发生了变化（供只在变化时广播）。
## 空 player_id（离线未注册）不转移——保持中立，仍由 host 本地模拟，离线单机不受影响。
func kick(player_id: String) -> bool:
	if player_id.is_empty() or owner_id == player_id:
		return false
	owner_id = player_id
	return true

## 滚停/复位：交回中立（host）。返回是否发生了变化。
func settle() -> bool:
	if owner_id == NEUTRAL:
		return false
	owner_id = NEUTRAL
	return true

func is_neutral() -> bool:
	return owner_id == NEUTRAL

func owner() -> String:
	return owner_id

## 本端此刻是否是该球的模拟者（权威）：中立态＝host 模拟；否则＝所有者本人模拟。
## my_id 为本端玩家 id（backend.player_id）；is_host 为本端是否 host（world._owns_npcs）。
func simulates(my_id: String, is_host: bool) -> bool:
	if owner_id == NEUTRAL:
		return is_host
	return my_id == owner_id
