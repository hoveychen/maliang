extends SceneTree
## CharAnimLod 角色动画 LOD 管理器的独立测试(纯逻辑,无渲染/网络)。
## 运行: godot --headless --path . --script res://test/test_char_anim_lod.gd

func _init() -> void:
	var fails := 0

	var lod := CharAnimLod.new()
	lod.max_hi = 2

	# 首帧:3 个角色 dist=[1,2,3] → 最近 2 个(a,b)进集
	var r := lod.update([
		{ "id": "a", "dist": 1.0 },
		{ "id": "b", "dist": 2.0 },
		{ "id": "c", "dist": 3.0 },
	])
	fails += _check("首帧 enter 含 a", "a" in r["enter"], true)
	fails += _check("首帧 enter 含 b", "b" in r["enter"], true)
	fails += _check("首帧 enter 不含 c", "c" in r["enter"], false)
	fails += _check("首帧无 leave", (r["leave"] as Array).is_empty(), true)
	fails += _check("a 已在集(占位)", lod.is_hi("a"), true)
	fails += _check("c 不在集", lod.is_hi("c"), false)

	# 调用方拉到图集后 hold 真纹理(占位纹理即可,不需 GPU)
	var tex_a := PlaceholderTexture2D.new()
	var tex_b := PlaceholderTexture2D.new()
	lod.hold("a", tex_a)
	lod.hold("b", tex_b)
	fails += _check("hold 后 hi_count=2", lod.hi_count(), 2)

	# 稳定态:同样的距离再喂,无 enter/leave(集不变,不重复拉图集)
	var r2 := lod.update([
		{ "id": "a", "dist": 1.0 },
		{ "id": "b", "dist": 2.0 },
		{ "id": "c", "dist": 3.0 },
	])
	fails += _check("稳定态无 enter", (r2["enter"] as Array).is_empty(), true)
	fails += _check("稳定态无 leave", (r2["leave"] as Array).is_empty(), true)

	# 玩家移动:c 变最近、a 变最远 → c 进、a 出
	var r3 := lod.update([
		{ "id": "a", "dist": 3.0 },
		{ "id": "b", "dist": 2.0 },
		{ "id": "c", "dist": 1.0 },
	])
	fails += _check("移动后 enter 含 c", "c" in r3["enter"], true)
	fails += _check("移动后 leave 含 a", "a" in r3["leave"], true)
	fails += _check("a 已离集(引用已丢)", lod.is_hi("a"), false)
	fails += _check("c 已入集", lod.is_hi("c"), true)
	fails += _check("集大小仍为 2", lod.hi_count(), 2)

	# hold 守卫:给一个不在集里的 id hold,应被忽略(不污染池)
	lod.hold("zzz", PlaceholderTexture2D.new())
	fails += _check("hold 集外 id 无效", lod.is_hi("zzz"), false)

	# fetch 竞态:enter 后未 hold 就离开,late hold 不登记
	var r4 := lod.update([{ "id": "d", "dist": 0.5 }, { "id": "b", "dist": 2.0 }])
	fails += _check("d 入集(占位,未 hold)", lod.is_hi("d"), true)
	var r5 := lod.update([{ "id": "b", "dist": 2.0 }, { "id": "c", "dist": 1.0 }])
	fails += _check("d 未 hold 即离集", lod.is_hi("d"), false)
	lod.hold("d", PlaceholderTexture2D.new())  # late hold
	fails += _check("late hold 不复活 d", lod.is_hi("d"), false)

	# 角色数 < N:全部进集,不报错
	var lod2 := CharAnimLod.new()
	lod2.max_hi = 3
	var r6 := lod2.update([{ "id": "x", "dist": 1.0 }])
	fails += _check("不足 N 时全进", (r6["enter"] as Array).size(), 1)
	fails += _check("空输入不崩", (lod2.update([])["leave"] as Array).size(), 1)  # x 离集

	# clear 收池
	lod.clear()
	fails += _check("clear 后集空", lod.hi_count(), 0)

	if fails == 0:
		print("char_anim_lod tests PASS")
	else:
		printerr("char_anim_lod tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
