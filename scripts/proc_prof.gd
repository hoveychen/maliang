class_name ProcProf
extends Object
## 跨脚本 _process 计时账本（debug 定位用）：各处 add() 累计 usec，
## world._prof_flush 统一 take() 并入 PERF 输出行。
## Sentinel 对（process_priority 全局排序的最前/最后）测出**整棵场景树**
## 所有节点 _process 的时间跨度（allproc）——与引擎口径 TIME_PROCESS 的差
## 即「不在任何节点 _process 里」的主循环内部耗时。

static var acc := {}
static var _frame_t0 := 0

static func add(key: String, usec: int) -> void:
	acc[key] = int(acc.get(key, 0)) + usec

static func take() -> Dictionary:
	var out := acc
	acc = {}
	return out

class Sentinel extends Node:
	var is_start := false

	static func make(start: bool) -> Sentinel:
		var s := Sentinel.new()
		s.is_start = start
		s.name = "ProfSentinelStart" if start else "ProfSentinelEnd"
		s.process_priority = -100000 if start else 100000
		return s

	func _process(_delta: float) -> void:
		if is_start:
			ProcProf._frame_t0 = Time.get_ticks_usec()
		else:
			ProcProf.add("allproc", Time.get_ticks_usec() - ProcProf._frame_t0)
