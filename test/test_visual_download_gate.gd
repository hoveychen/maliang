extends SceneTree
## 全量预下载门 人眼 QA（带窗，无断言）：截图看童话书风 + 点点陪伴 + 「正在准备你的小世界…」+
## 真进度条 + 信息行；再截弱网提示态「要联网才能准备好哦~」。
## 运行: /Applications/Godot.app/Contents/MacOS/Godot --path . --script res://test/test_visual_download_gate.gd
## 产物: screenshots/download_gate_mid.png（下载中）、download_gate_weaknet.png（弱网提示）

const GATE := preload("res://scripts/download_gate.gd")
const WP := preload("res://scripts/world_predownload.gd")

var _gate: Node = null
var _pd: WorldPredownload = null
var _frame := 0

func _initialize() -> void:
	root.size = Vector2i(1280, 720)
	_pd = WP.new()
	_pd.total_packs = 6
	_pd.total_bytes = 42 * 1024 * 1024
	_gate = GATE.new()
	root.add_child(_gate)
	_gate.begin(_pd, func(): pass) # 手动驱动进度，retry 空转
	process_frame.connect(_tick)

func _tick() -> void:
	_frame += 1
	if _frame == 20:
		_pd.done_packs = 3
		_pd.done_bytes = 23 * 1024 * 1024
		_pd.progress_changed.emit(3, 6, 23 * 1024 * 1024, 42 * 1024 * 1024)
	if _frame == 70:
		_shot("download_gate_mid")
	if _frame == 74:
		_pd.finished.emit(false) # 一轮没下齐 → 弱网提示现身
	if _frame == 120:
		_shot("download_gate_weaknet")
		quit(0)

func _shot(name: String) -> void:
	var img := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://screenshots")
	img.save_png("res://screenshots/%s.png" % name)
	print("saved screenshots/%s.png" % name)
