extends SceneTree
## 家具真实比例 footprint（interior-camera-and-size）：床/沙发是首批【非方形】内置物品——
## 验 ItemCatalog.footprint 读到正确 W×H，且 90°/270° 朝向交换宽高（与 server rotatedFootprint 一致）。
## 这是新能力守护：旧版全是方形 span-3，本测试会断言 (1,2)/(2,1)/(2,2)，若谁把家具改回方形立刻红。
## 运行: godot --headless --path . --script res://test/test_furniture_footprint.gd

func _init() -> void:
	var fails := 0
	ItemCatalog.ensure_builtin()

	# yaw 0（朝前，不旋转）：床 1×2、沙发 2×1、桌 2×2。
	fails += _check("床 yaw0 = 1×2", ItemCatalog.footprint("toy_bed_single", 0), Vector2i(1, 2))
	fails += _check("沙发 yaw0 = 2×1", ItemCatalog.footprint("toy_sofa", 0), Vector2i(2, 1))
	fails += _check("桌 yaw0 = 2×2", ItemCatalog.footprint("toy_table", 0), Vector2i(2, 2))
	fails += _check("椅仍 1×1", ItemCatalog.footprint("toy_chair", 0), Vector2i(1, 1))

	# yaw 90（arg 64）：非方形交换 W/H；方形不变。
	var a90 := 64
	fails += _check("床 yaw90 交换 = 2×1", ItemCatalog.footprint("toy_bed_single", a90), Vector2i(2, 1))
	fails += _check("沙发 yaw90 交换 = 1×2", ItemCatalog.footprint("toy_sofa", a90), Vector2i(1, 2))
	fails += _check("桌 yaw90 方形不变 = 2×2", ItemCatalog.footprint("toy_table", a90), Vector2i(2, 2))

	# P5：compose 已删除本地 ITEM_FOOTPRINT 副本，_place_anchor 改从 ItemCatalog.get_def 读同一真相
	# （builtin_items.json）。故上面 13-15 行的 ItemCatalog.footprint 就是 compose 导出所用的占地——
	# 单一真相，无需再对拍第二份副本（那份副本 P2 分档后漂移过，正是删它的原因）。
	fails += _check("well footprint = 2×2（P2 分档缩小，compose 读同源不再漂移）", ItemCatalog.footprint("well", 0), Vector2i(2, 2))

	print("test_furniture_footprint: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
