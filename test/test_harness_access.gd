extends SceneTree
## 无障碍模型纯函数单测（game-pilot 重写 P1）。验 HarnessAccess 的：
##  1) id 拼装（entity_id/action_id/tile_key）稳定；
##  2) screen_rect 以投影点为中心；
##  3) execution_for 真输入优先、off-screen/SubViewport 回退 handler；
##  4) action/describe_entity 记录形状（target_id 空→null）；
##  5) build_actions 按状态事实判 enabled/reason（mic/遮罩/确认/造物卡/手机）。
## 全程无视口——投影本身（碰相机）在 test_harness_do.gd（P2，带真视口）里验。
## 运行: godot --headless --path . --script res://test/test_harness_access.gd

var _ran := false

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ✓ %s" % name)
		return 0
	printerr("  ✗ %s: got %s want %s" % [name, str(got), str(want)])
	return 1

func _find(arr: Array, aid: String) -> Dictionary:
	for a in arr:
		if String((a as Dictionary).get("action_id", "")) == aid:
			return a
	return {}

func _initialize() -> void:
	process_frame.connect(_run_once)

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	print("[id 拼装]")
	fails += _check("action_id 带目标", HarnessAccess.action_id("talk", "npc:pig"), "talk:npc:pig")
	fails += _check("action_id 全局无目标", HarnessAccess.action_id("say", ""), "say")
	fails += _check("entity_id", HarnessAccess.entity_id("npc", "pig"), "npc:pig")
	fails += _check("tile_key", HarnessAccess.tile_key(Vector2i(3, 4)), "3,4")

	print("[screen_rect 居中]")
	var r := HarnessAccess.screen_rect(Vector2(100, 100), 80.0)
	fails += _check("rect x", r["x"], 20.0)
	fails += _check("rect y", r["y"], 20.0)
	fails += _check("rect w", r["w"], 160.0)
	fails += _check("rect h", r["h"], 160.0)

	print("[execution_for：真输入优先 / 回退]")
	fails += _check("press 根视口=tap", HarnessAccess.execution_for("press", true, "root")["execution"], "tap")
	fails += _check("press SubViewport=gui", HarnessAccess.execution_for("press", true, "PhoneScreen")["execution"], "gui")
	fails += _check("talk 在屏=tap", HarnessAccess.execution_for("talk", true, "root")["execution"], "tap")
	fails += _check("talk 出屏=handler", HarnessAccess.execution_for("talk", false, "root")["execution"], "handler")
	fails += _check("talk 出屏 reason", HarnessAccess.execution_for("talk", false, "root")["execution_reason"], "off_screen_fallback")
	fails += _check("pickup 出屏=handler", HarnessAccess.execution_for("pickup", false, "root")["execution"], "handler")
	fails += _check("enter_portal=walk", HarnessAccess.execution_for("enter_portal", false, "root")["execution"], "walk")
	fails += _check("walk=walk", HarnessAccess.execution_for("walk", false, "root")["execution"], "walk")
	fails += _check("say=voice", HarnessAccess.execution_for("say", false, "root")["execution"], "voice")
	fails += _check("phone=handler", HarnessAccess.execution_for("phone", false, "root")["execution"], "handler")
	fails += _check("debug=handler:debug", HarnessAccess.execution_for("debug", false, "root")["execution"], "handler:debug")

	print("[action 记录形状]")
	var a_say := HarnessAccess.action("say", "", "说话", true, "", false, "root", null, {"text": "string"})
	fails += _check("say action_id", a_say["action_id"], "say")
	fails += _check("say target_id 空→null", a_say["target_id"], null)
	fails += _check("say execution", a_say["execution"], "voice")
	fails += _check("say args_schema", a_say["args_schema"], {"text": "string"})
	var a_talk := HarnessAccess.action("talk", "npc:pig", "找猪说话", true, "", true, "root", {"x": 1})
	fails += _check("talk target_id", a_talk["target_id"], "npc:pig")
	fails += _check("talk enabled", a_talk["enabled"], true)
	fails += _check("talk screen_rect 透传", a_talk["screen_rect"], {"x": 1})

	print("[describe_entity 形状]")
	var el := HarnessAccess.describe_entity("npc", "npc:pig", "猪大哥", "root", true, {"x": 1}, {"tile": {"x": 3, "y": 4}}, [a_talk])
	for k in ["id", "kind", "label", "viewport", "on_screen", "screen_rect", "world", "actions"]:
		fails += _check("元素含 %s" % k, el.has(k), true)
	fails += _check("元素 actions 数", (el["actions"] as Array).size(), 1)

	print("[build_actions：状态事实 → 可用性]")
	var g1 := HarnessAccess.build_actions({"mic_open": true})
	fails += _check("开麦 say 可用", _find(g1, "say")["enabled"], true)
	var g2 := HarnessAccess.build_actions({"mic_open": false})
	fails += _check("闭麦 say 禁用", _find(g2, "say")["enabled"], false)
	fails += _check("闭麦 say reason", _find(g2, "say")["reason_disabled"], "mic_closed")
	var g3 := HarnessAccess.build_actions({"mic_open": true, "play_blocked": true})
	fails += _check("遮罩下 say 禁用", _find(g3, "say")["enabled"], false)
	fails += _check("遮罩下 say reason", _find(g3, "say")["reason_disabled"], "blocked_by_overlay")
	var g4 := HarnessAccess.build_actions({"vc_confirming": true})
	fails += _check("确认态 采纳可用", _find(g4, "confirm:confirm_accept")["enabled"], true)
	var g5 := HarnessAccess.build_actions({"vc_confirming": false})
	fails += _check("非确认态 采纳禁用", _find(g5, "confirm:confirm_accept")["enabled"], false)
	var g6 := HarnessAccess.build_actions({"in_creation": true, "creation_options": [{"id": "opt_a", "label": "A"}]})
	fails += _check("造物态【不再】造 pick_option 业务后门(改走通用 press:btn 真 tap)", _find(g6, "pick_option:opt_a").is_empty(), true)
	var g7 := HarnessAccess.build_actions({"phone_open": false})
	fails += _check("手机关→有打开动作", _find(g7, "phone:open").is_empty(), false)
	var g8 := HarnessAccess.build_actions({"phone_open": true})
	fails += _check("手机开→有收起动作", _find(g8, "phone:close").is_empty(), false)

	if fails == 0:
		print("[PASS] test_harness_access")
	else:
		printerr("[FAIL] test_harness_access: %d 处" % fails)
	quit(fails)
