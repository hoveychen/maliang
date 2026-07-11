extends SceneTree
## DeviceProfile 不变量：GPU 名可取（headless 下可能为空）、device id 稳定且落档案
## （防止 benchmark 重测时往众包重复灌票）、客户端 BENCH_VERSION 与服务端对齐。
##
## 注：画质档的「启动决议」（查 backend 众包档 / 未命中跑 benchmark）曾经在 loading._ready
## 里做，但那把网络往返变成了进世界的阻塞前置——网络一慢加载页就永远不关（真机实测卡死）。
## 决议已移出 loading，改由 menu 后的独立「建造小世界」前置阶段处理（world-building-intro
## plan），那里的行为由该阶段自己的测试覆盖，不再在这里测。
## 运行: godot --headless --script res://test/test_device_profile_boot.gd

func _init() -> void:
	var fails := 0
	var backup := PlayerProfile.load_profile()
	PlayerProfile.clear()

	# GPU 名：headless 无渲染设备时为空是正常的，真机上非空；这里只断言「取得到、不崩」。
	fails += _check("GPU 名类型为 String", typeof(DeviceProfile.gpu()), TYPE_STRING)

	# device id：首次生成即落档案，之后每次调用返回同一个（众包按 device id 去重）。
	var id1 := DeviceProfile.device_id()
	fails += _check("device id 非空", id1.length() > 0, true)
	fails += _check("device id 稳定（重复调用同一个）", DeviceProfile.device_id(), id1)
	fails += _check("device id 落进档案", String(PlayerProfile.load_profile().get("device_id", "")), id1)

	# 跨语言常量对齐：改了旋钮集合/口径必须两处同步 bump，否则旧样本会串桶。
	# v2（P5）：压测负载换 seed 村民图集 + 采样期冻结世界（server/src/device_profile.ts 同步为 2）。
	fails += _check("客户端 BENCH_VERSION 与服务端对齐", DeviceProfile.BENCH_VERSION, 2)

	if backup.is_empty():
		PlayerProfile.clear()
	else:
		PlayerProfile.save_profile(backup)

	if fails == 0:
		print("device_profile_boot PASS")
	else:
		printerr("device_profile_boot FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
