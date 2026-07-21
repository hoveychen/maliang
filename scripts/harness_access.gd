class_name HarnessAccess
extends Object
## AI 驱动 harness 的无障碍模型（game-pilot 重写 P1）。
##
## 把游戏里一切可交互物统一成【元素记录】+【动作描述符】，让驱动方按稳定 ID 寻址、
## 从"可用动作"列表里挑一条来做——不带业务理解也能摸索 UI/UX。执行由 debug_cmd_server 的
## do op 负责（P2），默认走真输入（tap 元素投影屏幕矩形 / 真走路 / 真长按），无真路径才回退。
##
## 本模块只放【纯函数】（可 headless 无视口单测，仿 debug_cmd_server.parse_command 的纪律）：
## id 拼装、元素/动作记录组装、按状态事实算动作可用性与执行路径。碰实时树/相机的收集器
## （unproject 投影、遍历 npcs/pois/portals/props）留在 debug_cmd_server._do_access。

# ── 稳定 ID ──────────────────────────────────────────────────────────────────
## 元素 id：kind + 原始标识。角色用后端 id，portal 用 to_scene@tile，prop/sticker 用 tile。
static func entity_id(kind: String, raw: String) -> String:
	return "%s:%s" % [kind, raw] if not raw.is_empty() else kind

## 动作 id：kind + 目标元素 id（无目标的全局动作只留 kind）。全局唯一、跨快照稳定。
static func action_id(kind: String, target_id: String) -> String:
	return "%s:%s" % [kind, target_id] if not target_id.is_empty() else kind

## tile → 稳定串（prop/sticker/portal 寻址用）。
static func tile_key(tile: Vector2i) -> String:
	return "%d,%d" % [tile.x, tile.y]

# ── 屏幕矩形 ──────────────────────────────────────────────────────────────────
## 以投影点为中心、PICK 半径为边距的方形（真 tap 落点/ web 叠加框）。纯。
static func screen_rect(center: Vector2, radius: float) -> Dictionary:
	return {"x": center.x - radius, "y": center.y - radius, "w": radius * 2.0, "h": radius * 2.0}

# ── 执行路径判定（纯）──────────────────────────────────────────────────────────
## 给定动作 kind + 元素是否在屏 + 所在视口，判 do op 该走哪条路 + 原因。
## 真输入优先：on_screen 的根视口元素走 tap/long_press/walk；off-screen 或 SubViewport 回退 handler。
## 返回 {execution, execution_reason}。
static func execution_for(kind: String, on_screen: bool, viewport: String) -> Dictionary:
	match kind:
		"say":
			return {"execution": "voice", "execution_reason": "asr_inject"}
		"confirm":
			return {"execution": "handler", "execution_reason": "no_real_path"}  # 确认流程无在屏按钮
		"phone", "remix":
			return {"execution": "handler", "execution_reason": "subviewport"}   # 手机屏在 SubViewport
		"enter_portal":
			return {"execution": "walk", "execution_reason": "walk_into_radius"} # 走进半径触发
		"walk":
			return {"execution": "walk", "execution_reason": "walk_to_target"}   # 走到目标附近
		"press":
			if viewport != "root":
				return {"execution": "gui", "execution_reason": "subviewport"}
			return {"execution": "tap", "execution_reason": "on_screen"}
		"pickup":
			if on_screen:
				return {"execution": "long_press", "execution_reason": "on_screen"}
			return {"execution": "handler", "execution_reason": "off_screen_fallback"}
		"talk", "pick_option":
			if on_screen:
				return {"execution": "tap", "execution_reason": "on_screen"}
			return {"execution": "handler", "execution_reason": "off_screen_fallback"}
		"debug":
			return {"execution": "handler:debug", "execution_reason": "debug_only"}
	return {"execution": "handler", "execution_reason": "no_real_path"}

# ── 记录组装（纯）────────────────────────────────────────────────────────────
## 动作描述符。element-targeted 动作 target_id 非空；全局动作（say/confirm/phone）target_id 空。
static func action(kind: String, target_id: String, label: String, enabled: bool,
		reason_disabled: String, on_screen: bool, viewport: String,
		screen_rect_: Variant = null, args_schema: Dictionary = {}) -> Dictionary:
	var ex := execution_for(kind, on_screen, viewport)
	return {
		"action_id": action_id(kind, target_id),
		"kind": kind,
		"target_id": target_id if not target_id.is_empty() else null,
		"label": label,
		"enabled": enabled,
		"reason_disabled": reason_disabled,
		"execution": ex["execution"],
		"execution_reason": ex["execution_reason"],
		"screen_rect": screen_rect_,
		"args_schema": args_schema,
	}

## 元素记录。actions 是该元素上的 element-targeted 动作（也会被扁平进顶层 actions[]）。
static func describe_entity(kind: String, id: String, label: String, viewport: String,
		on_screen: bool, screen_rect_: Variant, world: Variant, actions: Array) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"label": label,
		"viewport": viewport,
		"on_screen": on_screen,
		"screen_rect": screen_rect_,
		"world": world,
		"actions": actions,
	}

# ── 全局/上下文动作（纯）──────────────────────────────────────────────────────
## 从扁平状态事实算全局动作列表（不含 element-targeted 的 talk/pickup/press——那些随元素生成）。
## facts 键：mic_open, vc_confirming, in_creation, creation_options[{id,label}], phone_open,
##          phone_app, play_blocked, stage_active。
## 世界被遮罩/舞台占用时，交互类动作 enabled=false, reason_disabled="blocked_by_overlay"/"stage_active"。
static func build_actions(facts: Dictionary) -> Array:
	var out: Array = []
	var blocked := bool(facts.get("play_blocked", false))
	var staged := bool(facts.get("stage_active", false))
	var block_reason := "blocked_by_overlay" if blocked else ("stage_active" if staged else "")
	var world_gate := not (blocked or staged)

	# say：需开麦 + 世界未被遮。
	var mic := bool(facts.get("mic_open", false))
	var say_ok := mic and world_gate
	var say_reason := "" if say_ok else (block_reason if not world_gate else "mic_closed")
	out.append(action("say", "", "说话", say_ok, say_reason, false, "root", null, {"text": "string"}))

	# 确认三键：仅确认模式下可用。
	var confirming := bool(facts.get("vc_confirming", false))
	for c in [["confirm_accept", "采纳"], ["confirm_replay", "回放"], ["confirm_retry", "重说"]]:
		var cid := String(c[0])
		var enabled := confirming
		out.append(action("confirm", cid, String(c[1]), enabled,
			"" if enabled else "not_confirming", false, "root"))

	# 引导式造物点卡：in_creation 且有卡时，每张卡一条 pick_option。
	if bool(facts.get("in_creation", false)):
		var opts: Variant = facts.get("creation_options", [])
		if typeof(opts) == TYPE_ARRAY:
			for o in (opts as Array):
				if typeof(o) != TYPE_DICTIONARY:
					continue
				var oid := String((o as Dictionary).get("id", ""))
				if oid.is_empty():
					continue
				var enabled2 := world_gate
				out.append(action("pick_option", oid, String((o as Dictionary).get("label", oid)),
					enabled2, "" if enabled2 else block_reason, false, "root"))

	# 手机：便捷全局动作（手机屏 SubViewport，走 handler）。
	var phone_open := bool(facts.get("phone_open", false))
	if phone_open:
		out.append(action("phone", "close", "收起手机", true, "", false, "root"))
	else:
		out.append(action("phone", "open", "打开手机", world_gate,
			"" if world_gate else block_reason, false, "root"))
	return out
