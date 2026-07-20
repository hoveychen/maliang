extends SceneTree
## bootstrap 世界选择（世界模板架构 v2 P4）：MALIANG_WORLD 覆盖 → get_world(指定世界)；
## 否则 → get_my_world(playerId)。harness「开沙箱 → 指它跑整册」靠这个钩子把客户端指向 sandbox_<uuid>。
## 用 RecordApi 记录派发到哪个方法，不起真网。
## 运行: godot --headless --path . --script res://test/test_bootstrap_world_select.gd

class RecordApi extends Api:
	var calls: Array = []
	func get_world(id: String) -> Dictionary:
		calls.append(["get_world", id])
		return { "id": id }
	func get_my_world(player_id: String) -> Dictionary:
		calls.append(["get_my_world", player_id])
		return { "id": "w_" + player_id }

var _fails := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var rec := RecordApi.new()

	# 无覆盖 → 每人一世界
	OS.set_environment("MALIANG_WORLD", "")
	rec.calls.clear()
	var w1: Dictionary = await rec.get_bootstrap_world("pid1")
	_check("无覆盖派发到 get_my_world", rec.calls, [["get_my_world", "pid1"]])
	_check("无覆盖返回每人一世界", String(w1.get("id", "")), "w_pid1")

	# 有覆盖 → 拉指定世界（沙箱）
	OS.set_environment("MALIANG_WORLD", "sandbox_abc")
	rec.calls.clear()
	var w2: Dictionary = await rec.get_bootstrap_world("pid1")
	_check("有覆盖派发到 get_world(指定)", rec.calls, [["get_world", "sandbox_abc"]])
	_check("有覆盖返回指定世界", String(w2.get("id", "")), "sandbox_abc")

	OS.set_environment("MALIANG_WORLD", "") # 复位，别泄漏给后续测试
	rec.free() # RecordApi 未挂进树，手动释放免「resources still in use」告警
	quit(_fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok ", name)
	else:
		printerr("  FAIL ", name, " got=", got, " want=", want)
		_fails += 1
