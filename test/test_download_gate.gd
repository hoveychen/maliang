extends SceneTree
## 全量预下载门 UI 冒烟（world-full-predownload-gate P3，headless 不崩）：build → begin → 进度更新
## → 全挂 finished(true) → 淡出触发 done + 释放。不截图（headless dummy renderer），只锁「不崩 + 进度
## 文案 + 收尾放行」。运行: godot --headless --path . --script res://test/test_download_gate.gd

const GATE := preload("res://scripts/download_gate.gd")
const WP := preload("res://scripts/world_predownload.gd")

var _fails := 0
var _gate: Node = null
var _pd: WorldPredownload = null
var _done := false
var _frame := 0
var _retry_calls := 0

func _initialize() -> void:
	root.size = Vector2i(1280, 720)
	_pd = WP.new()
	_pd.total_packs = 4
	_pd.total_bytes = 20 * 1024 * 1024
	_gate = GATE.new()
	root.add_child(_gate)
	_gate.connect("done", func(): _done = true)
	# retry_cb 记录被调次数（begin 会调一次确保有一轮在跑）
	_gate.begin(_pd, func(): _retry_calls += 1)
	process_frame.connect(_tick)

func _tick() -> void:
	_frame += 1
	if _frame == 3:
		_check("begin 调了一次 retry（确保起下载）", _retry_calls >= 1, true)
		# 推一个中途进度
		_pd.done_packs = 2
		_pd.done_bytes = 11 * 1024 * 1024
		_pd.progress_changed.emit(2, 4, 11 * 1024 * 1024, 20 * 1024 * 1024)
	if _frame == 5:
		var info := _find_label_with(_gate, "已准备 2/4")
		_check("进度文案含 已准备 2/4", info != null, true)
		_check("进度文案含 MB", info != null and String(info.text).contains("MB"), true)
	if _frame == 18:
		# 现身宽限已过（18 帧 @30fps=0.6s > GRACE 0.4），gate 仍在树、未崩
		_check("gate 现身宽限后仍存活", is_instance_valid(_gate), true)
		# 全挂 → 收尾
		_pd.done_packs = 4
		_pd.done_bytes = 20 * 1024 * 1024
		_pd.all_mounted = true
		_pd.finished.emit(true)
	if _frame == 40:
		# 淡出（FADE_OUT 0.4s）后应已 emit done 并 queue_free
		_check("全挂后触发 done（放行）", _done, true)
		_check("gate 已释放", not is_instance_valid(_gate), true)
		_finish()

func _find_label_with(n: Node, needle: String) -> Label:
	if n is Label and String((n as Label).text).contains(needle):
		return n as Label
	for c in n.get_children():
		var r := _find_label_with(c, needle)
		if r != null:
			return r
	return null

func _check(name: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
		_fails += 1

func _finish() -> void:
	if _fails == 0:
		print("download_gate tests PASS")
	else:
		printerr("download_gate tests FAILED: %d" % _fails)
	quit(_fails)
