extends SceneTree
## 世界级预下载编排器（world-full-predownload-gate P2）：纯函数 build_plan/plan_total_bytes/fmt_mb
## + run() 进度/去重/已挂跳过/弱网缺包 的 mock 驱动闭环。
## 运行: godot --headless --path . --script res://test/test_world_predownload.gd

const WP := preload("res://scripts/world_predownload.gd")

## mock Api：fetch_world_packs 回预置清单；fetch_pack 记录被下的 hash，fail 集里的返回空模拟弱网失败。
class MockApi extends RefCounted:
	var packs: Array = []
	var fetched: Array = []
	var fail: Dictionary = {}
	func fetch_world_packs(_wid: String) -> Array:
		return packs
	func fetch_pack(h: String) -> String:
		fetched.append(h)
		if fail.has(h):
			return ""
		return "user://packs/%s.pck" % h

## mock PackMounter：mounted 记 hash（预置=二次启动已缓存），ensure_mounted 成功挂上。
class MockPm extends RefCounted:
	var mounted: Dictionary = {}
	var names: Dictionary = {}
	func is_mounted(h: String) -> bool:
		return mounted.has(h)
	func note_mounted_name(n: String) -> void:
		if not n.is_empty():
			names[n] = true
	func ensure_mounted(h: String, n: String) -> bool:
		mounted[h] = true
		note_mounted_name(n)
		return true

func _init() -> void:
	var fails := 0
	fails += _test_build_plan()
	fails += _test_totals_and_fmt()
	fails += await _test_run_all_fresh()
	fails += await _test_run_skip_mounted_and_weaknet()
	fails += await _test_run_offline_passes()
	if fails == 0:
		print("world_predownload tests PASS")
	else:
		printerr("world_predownload tests FAILED: %d" % fails)
	quit(fails)

func _test_build_plan() -> int:
	var f := 0
	# 去重（同 hash 只留一次）+ 丢空 name/hash + 保序
	var raw := [
		{"name": "base", "hash": "h1", "bytes": 100},
		{"name": "bgm", "hash": "h2", "bytes": 200},
		{"name": "base_alias", "hash": "h1", "bytes": 100}, # 同 h1 → 去重
		{"name": "", "hash": "h3", "bytes": 50},            # 空 name → 丢
		{"name": "toyroom", "hash": "", "bytes": 50},       # 空 hash → 丢
		"garbage",                                          # 非字典 → 丢
	]
	var plan := WP.build_plan(raw)
	f += _eq("build_plan 去重+过滤后 2 条", plan.size(), 2)
	f += _eq("build_plan 保序[0]=base", String((plan[0] as Dictionary)["name"]), "base")
	f += _eq("build_plan 保序[1]=bgm", String((plan[1] as Dictionary)["name"]), "bgm")
	return f

func _test_totals_and_fmt() -> int:
	var f := 0
	var plan := WP.build_plan([
		{"name": "a", "hash": "h1", "bytes": 1024 * 1024},
		{"name": "b", "hash": "h2", "bytes": 512 * 1024},
	])
	f += _eq("plan_total_bytes", WP.plan_total_bytes(plan), 1024 * 1024 + 512 * 1024)
	f += _eq("fmt_mb 1.5MB", WP.fmt_mb(1024 * 1024 + 512 * 1024), "1.5")
	f += _eq("fmt_mb 0", WP.fmt_mb(0), "0.0")
	return f

func _test_run_all_fresh() -> int:
	var f := 0
	var api := MockApi.new()
	api.packs = [
		{"name": "base", "hash": "h1", "bytes": 100},
		{"name": "bgm", "hash": "h2", "bytes": 200},
	]
	var pm := MockPm.new()
	var wp := WP.new()
	var last := [0, 0, 0, 0]
	var done := [false, false]
	# GDScript lambda 捕获是按值复制——重新赋值捕获变量不会回传外层，但改可变对象【内容】会（引用共享）。
	wp.progress_changed.connect(func(dp, tp, db, tb): last.assign([dp, tp, db, tb]))
	wp.finished.connect(func(all_ok): done[0] = true; done[1] = all_ok)
	await wp.run(api, pm, "w1")
	f += _eq("all_fresh 全下齐 all_mounted", done[1], true)
	f += _eq("all_fresh done_packs", wp.done_packs, 2)
	f += _eq("all_fresh done_bytes", wp.done_bytes, 300)
	f += _eq("all_fresh total_bytes", wp.total_bytes, 300)
	f += _eq("all_fresh 末次进度=(2,2,300,300)", str(last), str([2, 2, 300, 300]))
	f += _eq("all_fresh 两个包都被 fetch", api.fetched.size(), 2)
	return f

func _test_run_skip_mounted_and_weaknet() -> int:
	var f := 0
	var api := MockApi.new()
	api.packs = [
		{"name": "base", "hash": "h1", "bytes": 100}, # 全新下
		{"name": "bgm", "hash": "h2", "bytes": 200},  # 预挂→跳过
		{"name": "toyroom", "hash": "h3", "bytes": 300}, # 弱网失败
	]
	api.fail = {"h3": true}
	var pm := MockPm.new()
	pm.mounted = {"h2": true} # bgm 二次启动已缓存挂载
	var wp := WP.new()
	var done := [false, false]
	wp.finished.connect(func(all_ok): done[0] = true; done[1] = all_ok)
	await wp.run(api, pm, "w1")
	f += _eq("weaknet 有缺 → all_mounted=false", done[1], false)
	f += _eq("weaknet done_packs=2(base+已挂bgm)", wp.done_packs, 2)
	f += _eq("weaknet done_bytes=300(100+200)", wp.done_bytes, 300)
	f += _eq("weaknet total_packs=3", wp.total_packs, 3)
	f += _eq("weaknet 已挂的 h2 未被重下", api.fetched.has("h2"), false)
	f += _eq("weaknet 已挂 bgm 补记名字", pm.names.has("bgm"), true)
	# 重试补缺：解除弱网再 run 一次 → 全挂
	api.fail = {}
	await wp.run(api, pm, "w1")
	f += _eq("retry 后 all_mounted", done[1], true)
	f += _eq("retry 后 done_packs=3", wp.done_packs, 3)
	return f

func _test_run_offline_passes() -> int:
	var f := 0
	var wp := WP.new()
	var done := [false, false]
	wp.finished.connect(func(all_ok): done[0] = true; done[1] = all_ok)
	await wp.run(null, null, "") # 离线/无世界：直接放行
	f += _eq("offline finished", done[0], true)
	f += _eq("offline all_mounted=true(放行)", done[1], true)
	f += _eq("offline total_packs=0", wp.total_packs, 0)
	return f

func _eq(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
