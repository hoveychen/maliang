extends SceneTree
## 角色引导并发预取的素材决策单元测试（world.gd _pick_char_asset / _char_id）。
## 核心不变量：idle 动画就绪且 animAsset 非空 → 选动画图集（跳过静态大图，老板要求「有动画就不要立绘」）；
## 其余情形（pending/none/failed/animAsset 空）→ 回落静态立绘。纯函数，裸实例即可测。
## 运行: godot --headless --path . --script res://test/test_char_prefetch.gd

func _init() -> void:
	var fails := 0
	var w: Node = (load("res://scripts/world.gd") as GDScript).new()

	# --- _char_id：优先 id，无则名字兜底 ---
	fails += _check("id 优先", String(w.call("_char_id", {"id": "c1", "name": "蓬蓬"})), "c1")
	fails += _check("无 id 用名字", String(w.call("_char_id", {"name": "睡睡猫"})), "睡睡猫")

	# --- _pick_char_asset：动画就绪 → 选 animAsset ---
	var ready: Dictionary = w.call("_pick_char_asset",
		{"status": "ready", "animAsset": "anim123", "meta": {"cols": 6, "fps": 8}}, "sprite999")
	fails += _check("ready→选动画 hash", String(ready["hash"]), "anim123")
	fails += _check("ready→is_anim 真", bool(ready["is_anim"]), true)
	fails += _check("ready→带回 meta", int((ready["meta"] as Dictionary).get("cols", 0)), 6)

	# --- 动画就绪但 animAsset 空 → 回落静态 ---
	var empty_anim: Dictionary = w.call("_pick_char_asset", {"status": "ready", "animAsset": ""}, "sprite999")
	fails += _check("ready 但 anim 空→回落静态", String(empty_anim["hash"]), "sprite999")
	fails += _check("ready 但 anim 空→is_anim 假", bool(empty_anim["is_anim"]), false)

	# --- pending / none / failed → 静态 ---
	for st in ["pending", "none", "failed", ""]:
		var r: Dictionary = w.call("_pick_char_asset", {"status": st, "animAsset": "shouldIgnore"}, "spriteX")
		fails += _check("status=%s→选静态" % st, String(r["hash"]), "spriteX")
		fails += _check("status=%s→is_anim 假" % st, bool(r["is_anim"]), false)

	# --- _body_scale：size→scale 体型倍率（character-size）---
	fails += _check("大体型 scale=1.4 透传", float(w.call("_body_scale", {"scale": 1.4})), 1.4)
	fails += _check("小体型 scale=0.7 透传", float(w.call("_body_scale", {"scale": 0.7})), 0.7)
	fails += _check("缺 scale→1.0(存量不跳变)", float(w.call("_body_scale", {})), 1.0)
	fails += _check("坏数据超上限→clamp 2.0", float(w.call("_body_scale", {"scale": 99.0})), 2.0)
	fails += _check("坏数据 0→clamp 下限 0.4", float(w.call("_body_scale", {"scale": 0.0})), 0.4)

	w.free()
	print("test_char_prefetch: %d fail(s)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
