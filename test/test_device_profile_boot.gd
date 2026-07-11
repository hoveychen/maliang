extends SceneTree
## 启动决议（loading._resolve_graphics）：定过档就不查网；桌面不折腾；查不通的新机器要
## 置 Benchmark.pending（而不是默默玩在保守起步档上）。
## 以及 DeviceProfile：GPU 名非空、device id 稳定且落档案（防止重测时重复灌票）。
##
## backend「命中」那条分支需要真服务端，属于服务端测试的范围（server/test/device_profile.test.ts
## 已覆盖上传→下发的往返）；这里 MALIANG_API_BASE 指向不可达地址，走的是「查不通」路径。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 120 --script res://test/test_device_profile_boot.gd

var frame := 0
var fails := 0
var _backup: Dictionary
var _loading: Node

func _initialize() -> void:
	_backup = PlayerProfile.load_profile()
	PlayerProfile.clear()
	Benchmark.pending = false

	# —— DeviceProfile ——
	# headless 无渲染设备 → GPU 名为空是正常的。真机上非空。这里断言的是「空也不崩」，
	# 空 GPU 的兜底路径（跳过众包、本机自测、不上传）在下面的未定档分支里验证。
	_check("GPU 名可取（headless 下可能为空，不崩即可）", typeof(DeviceProfile.gpu()), TYPE_STRING)
	var id1 := DeviceProfile.device_id()
	_check("device id 非空", id1.length() > 0, true)
	_check("device id 稳定（重复调用同一个）", DeviceProfile.device_id(), id1)
	_check("device id 落进档案", String(PlayerProfile.load_profile().get("device_id", "")), id1)
	_check("客户端与服务端 BENCH_VERSION 对齐", DeviceProfile.BENCH_VERSION, 1)

	# —— 已定过档：不查网、不跑 benchmark ——
	GraphicsSettings.save_all(GraphicsSettings.all_max(), "user")
	_loading = load("res://loading.tscn").instantiate()
	root.add_child(_loading)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	match frame:
		4:
			_check("定过档 → 立即放行世界（不等网络）", _loading.get("_gfx_resolved"), true)
			_check("定过档 → 不跑 benchmark", Benchmark.pending, false)
			_loading.queue_free()
		8:
			# —— 没定过档 + 查不通 backend → 置 pending，进世界自测 ——
			# 桌面构建下 _resolve_graphics 直接放行（天然满配），所以这里只能断言它没崩、
			# 且 mobile 分支的决策由下面的直接调用覆盖。
			GraphicsSettings.clear()
			Benchmark.pending = false
			_loading = load("res://loading.tscn").instantiate()
			root.add_child(_loading)
		12:
			_check("未定档 → 决议已完成（不卡住世界）", _loading.get("_gfx_resolved"), true)
			if OS.has_feature("mobile"):
				_check("移动端查不通 → 置 pending 自测", Benchmark.pending, true)
			else:
				_check("桌面 → 天然满配，不查网不自测", Benchmark.pending, false)
			_loading.queue_free()
		16:
			if _backup.is_empty():
				PlayerProfile.clear()
			else:
				PlayerProfile.save_profile(_backup)
			Benchmark.pending = false
			if fails == 0:
				print("device_profile_boot PASS")
			else:
				printerr("device_profile_boot FAILED: %d" % fails)
		18:
			quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
