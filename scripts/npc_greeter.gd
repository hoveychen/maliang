class_name NpcGreeter
extends Node
## 村民主动社交调度器（见 docs/villager-social-design.md）。
##
## 给「注意到玩家」（world._update_npc_notice：原地转头挥手）升一档：符合【性格×熟识度】的村民
## 会【主动走过来、停在玩家旁、面向玩家打招呼】（外向的再送花，见 P4）。
##
## 本模块只做【谁在什么时候迎上来】的纯调度：资格判定、每村民冷却、全局单槽错峰、
## 接近/到达/收尾状态机。它【不碰节点、不碰走位】——真实走位由宿主复用 follow 行为脚本，
## 面向/挥手/出声/送花由宿主按本模块返回的 action 执行。这样调度逻辑可独立 headless 单测。
##
## 设计要点：
##  ① 全局单槽：同一时刻至多一个村民在主动迎接（_greeter）。老板要的「不扎堆」。
##  ② 稀：每村民 CD_MIN..CD_MAX 才主动一次，比被动挥手（8~20s）稀得多。
##  ③ 用 follow 的自停：follow 走到 FOLLOW_NEAR(3.4) 自动停住并保持，玩家走远才重新跟。
##     所以「到达」后【不取消】follow，靠它把村民钉在玩家旁；只在收尾/放弃时才取消 + 恢复闲逛。

const APPROACH_RADIUS := 9.0  ## 玩家进这个范围内，符合条件的空闲村民才起意迎上来（比 notice 的 6.5 略大）
const ARRIVE_DIST := 3.8      ## 走到这个距离内即视作「到了玩家旁」（follow 自停在 3.4，留点余量）
const TIMEOUT := 9.0          ## 接近超时：玩家一直跑、够不着就放弃，别没完没了地追
const DWELL := 2.0            ## 到达后面向玩家停留秒数（够挥手 + 出声），到点收尾恢复闲逛
const CD_MIN := 35.0          ## 单个村民两次主动迎接的最短间隔（秒）
const CD_MAX := 80.0          ## 最长间隔；每次随机，天然错峰
const GLOBAL_GAP := 12.0      ## 任意两个村民主动迎接之间的最小间隔（全局错峰）

var _t := 0.0
var _greeter := ""            ## 当前正在主动迎接的村民 id（""=无）
var _phase := ""              ## "" | "approaching" | "arrived"
var _phase_t := 0.0           ## 当前 phase 已持续秒数（超时/停留计时）
var _global_next_ok := 0.0    ## 全局下一次可开新迎接的时刻
var _next_ok := {}            ## characterId -> 可再次主动迎接的时刻

## 性格×熟识度资格：外向主动迎【陌生人】，内向只迎【熟人】（点头之交/朋友）。
## 与服务端 social.deriveSocialType/deriveFamiliarity 对齐（字段由 projectCharacterFor 下发）。
static func greet_eligible(social_type: String, familiarity: String) -> bool:
	if social_type == "extrovert":
		return familiarity == "stranger"
	if social_type == "introvert":
		return familiarity == "acquaintance" or familiarity == "friend"
	return false

## 候选筛选：这个村民此刻不该被【新】拉去主动迎接——仙子、正在对话、正在演动作、或宿主标记的
## 「不空闲」（被选中/叫停/已有执行器在驱动，宿主每帧写 greet_free）。
func _busy(n: Dictionary) -> bool:
	return n.get("is_fairy", false) \
		or bool(n.get("in_chat", false)) \
		or not String(n.get("paper_action", "")).is_empty() \
		or not bool(n.get("greet_free", false))

## 活跃迎接者中断判定：只在被真正抢走时放弃——玩家点它对话(selected)/把它叫停(_stopped)/它进了
## NPC 间对话。刻意【不】看 greet_free 或 paper_action：迎接中的村民本就被自己的 follow 驱动
## （greet_free=false），到达时又会演 wave（paper_action 非空），拿这些当中断会自锁。宿主每帧写 greet_hijack。
func _hijacked(n: Dictionary) -> bool:
	return bool(n.get("greet_hijack", false))

## 每帧由宿主调用。npcs = world.npcs（每个 dict 需带 id/logical/is_fairy/social_type/familiarity/
## in_chat/paper_action/greet_free）。player_pos = 玩家逻辑坐标。engaged = 玩家正在交互/录音/听人说话。
## 返回给宿主执行的 action：
##   {}                        本帧无事
##   {type:"approach", cid}    让这个村民朝玩家走过去（宿主下 follow 脚本）
##   {type:"arrived",  cid}    村民到玩家旁了（宿主面向玩家 + 挥手/出声/送花；【不取消】follow）
##   {type:"release",  cid}    打招呼收尾（宿主取消 follow + 恢复闲逛）
##   {type:"giveup",   cid}    够不着放弃（宿主取消 follow + 恢复闲逛）
func update(delta: float, npcs: Array, player_pos: Vector2, engaged: bool) -> Dictionary:
	_t += delta
	# ── 有活跃迎接者：推进其状态机，本帧不开新的（单槽错峰）──
	if not _greeter.is_empty():
		var n := _find(npcs, _greeter)
		# 迎接者没了 / 被玩家抢走（对话/叫停）→ 放弃收尾
		if n.is_empty() or _hijacked(n):
			return _end("giveup")
		_phase_t += delta
		var dist := WorldGrid.shortest_delta(n.get("logical", Vector2.ZERO), player_pos).length()
		if _phase == "approaching":
			if dist <= ARRIVE_DIST:
				_phase = "arrived"
				_phase_t = 0.0
				return { "type": "arrived", "cid": _greeter }
			if _phase_t >= TIMEOUT:
				return _end("giveup")
			return {}
		# arrived：面向 + 挥手已由宿主执行，这里只等停留结束（follow 自停在原地钉住村民）
		if _phase_t >= DWELL:
			return _end("release")
		return {}
	# ── 无活跃迎接者：够冷却且玩家没在交互时，挑一个最近的合格村民迎上来 ──
	if engaged or _t < _global_next_ok:
		return {}
	var best := ""
	var best_d := APPROACH_RADIUS + 0.001
	for n in npcs:
		if _busy(n):
			continue
		var cid := String(n.get("id", ""))
		if cid.is_empty() or _t < float(_next_ok.get(cid, 0.0)):
			continue
		if not greet_eligible(String(n.get("social_type", "")), String(n.get("familiarity", ""))):
			continue
		var d := WorldGrid.shortest_delta(n.get("logical", Vector2.ZERO), player_pos).length()
		if d <= best_d:
			best_d = d
			best = cid
	if best.is_empty():
		return {}
	_greeter = best
	_phase = "approaching"
	_phase_t = 0.0
	return { "type": "approach", "cid": best }

## 收尾：清空迎接者、给它一段较长的私人冷却、全局也歇一小会（错峰）。返回给宿主的 action。
func _end(kind: String) -> Dictionary:
	var cid := _greeter
	_next_ok[cid] = _t + randf_range(CD_MIN, CD_MAX)
	_global_next_ok = _t + GLOBAL_GAP
	_greeter = ""
	_phase = ""
	_phase_t = 0.0
	return { "type": kind, "cid": cid }

func _find(npcs: Array, cid: String) -> Dictionary:
	for n in npcs:
		if String(n.get("id", "")) == cid:
			return n
	return {}
