extends RefCounted
## StageAgent 的能力宿主 mock：记录被调命令，扣住完成型命令的 done 回调供测试手动触发。
## 不依赖真实执行器/音频。被 test_stage_agent.gd 与 test_screenplay_replay.gd 共用。

var calls: Array = []
var last_move_done := Callable()
var last_action_done := Callable()
var last_say_done := Callable()
var last_narrate_done := Callable()
var last_prop_done := Callable()
var last_ball_done := Callable()
var last_prompt_done := Callable()

func stage_begin(actors: Array) -> void:
	calls.append({ "m": "begin", "actors": actors })

func stage_finish(result: Dictionary, aborted: bool, reason: String) -> void:
	calls.append({ "m": "finish", "result": result, "aborted": aborted, "reason": reason })

func stage_move(actor_id: String, target: Variant, done: Callable) -> void:
	calls.append({ "m": "move", "actor": actor_id, "target": target })
	last_move_done = done

func stage_action(actor_id: String, action: String, done: Callable) -> void:
	calls.append({ "m": "action", "actor": actor_id, "action": action })
	last_action_done = done

func stage_say(actor_id: String, text: String, action: String, voice_id: String, done: Callable) -> void:
	calls.append({ "m": "say", "actor": actor_id, "text": text, "action": action, "voice": voice_id })
	last_say_done = done

func stage_narrate(text: String, done: Callable) -> void:
	calls.append({ "m": "narrate", "text": text })
	last_narrate_done = done

func stage_prompt(actor_id: String, hint: String, done: Callable) -> void:
	calls.append({ "m": "prompt", "actor": actor_id, "hint": hint })
	last_prompt_done = done

func stage_follow(actor_id: String, target_id: String) -> void:
	calls.append({ "m": "follow", "actor": actor_id, "target": target_id })

func stage_flee(actor_id: String, target_id: String) -> void:
	calls.append({ "m": "flee", "actor": actor_id, "target": target_id })

func stage_stop(actor_id: String) -> void:
	calls.append({ "m": "stop", "actor": actor_id })

func stage_banner(text: String) -> void:
	calls.append({ "m": "banner", "text": text })

func stage_hud_score(id: String, label: String) -> void:
	calls.append({ "m": "hud_score", "id": id, "label": label })

func stage_hud_score_add(id: String, n: int) -> void:
	calls.append({ "m": "hud_score_add", "id": id, "n": n })

func stage_camera(mode: String, a: String, b: String) -> void:
	calls.append({ "m": "camera", "mode": mode, "a": a, "b": b })

func stage_hud_countdown(id: String, sec: int, server_start_ms: int, offset_ms: int) -> void:
	calls.append({ "m": "hud_countdown", "id": id, "sec": sec, "start": server_start_ms, "offset": offset_ms })

func stage_hud_cancel(id: String) -> void:
	calls.append({ "m": "hud_cancel", "id": id })

func stage_hud_toast(text: String) -> void:
	calls.append({ "m": "hud_toast", "text": text })

func stage_prop_spawn(id: String, spec: Dictionary, near: Variant, done: Callable) -> void:
	calls.append({ "m": "prop_spawn", "id": id, "spec": spec, "near": near })
	last_prop_done = done

func stage_prop_place(id: String, at: Variant) -> void:
	calls.append({ "m": "prop_place", "id": id, "at": at })

func stage_prop_remove(id: String) -> void:
	calls.append({ "m": "prop_remove", "id": id })

func stage_spawn_ball(id: String, at: Variant, done: Callable) -> void:
	calls.append({ "m": "spawn_ball", "id": id, "at": at })
	last_ball_done = done

func stage_ball_reset(id: String, at: Variant, done: Callable) -> void:
	calls.append({ "m": "ball_reset", "id": id, "at": at })
	last_ball_done = done

## 某类调用的次数。
func count(m: String) -> int:
	var n := 0
	for c in calls:
		if String(c["m"]) == m:
			n += 1
	return n

## 最后一次某类调用（无则 {}）。
func last(m: String) -> Dictionary:
	for i in range(calls.size() - 1, -1, -1):
		if String(calls[i]["m"]) == m:
			return calls[i]
	return {}
