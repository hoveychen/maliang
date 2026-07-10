extends SceneTree
## AdaptiveQuality 帧率上限行为单测：
##   1) 无存档（首次基准测量）时 _ready 解除限帧（=0 不封顶），定档后恢复 FPS_CAP；
##   2) 有存档时读档直接应用，menu 设的上限全程不动。
## 节点 _ready 要等首帧，所以用 _initialize + process_frame one-shot（同 test_game_audio）。
## 运行: godot --headless --path . --script res://test/test_adaptive_fps_cap.gd

var _fails := 0
var _world: Node3D
var _chunks: ChunkManager

func _initialize() -> void:
	if FileAccess.file_exists(AdaptiveQuality.CFG_PATH):
		DirAccess.remove_absolute(AdaptiveQuality.CFG_PATH)
	Engine.max_fps = AdaptiveQuality.FPS_CAP  # 模拟 menu 入口已限帧
	_world = Node3D.new()
	root.add_child(_world)
	_chunks = ChunkManager.new()  # 裸实例即可：set_terrain_low_detail 有 null 材质守卫
	var aq := AdaptiveQuality.make(_world, _chunks)
	root.add_child(aq)
	process_frame.connect(func() -> void: _stage_benchmark(aq), CONNECT_ONE_SHOT)

## 基准测量路径：进场解除 → 定档后恢复
func _stage_benchmark(aq: AdaptiveQuality) -> void:
	_fails += _check("benchmark uncaps", Engine.max_fps, 0)
	# 手动喂帧：平均 30ms（落 T1 区间，_apply 不触发场景依赖）直到测量窗结束
	aq._process(AdaptiveQuality.WARMUP + 0.001)
	while not aq._done:
		aq._process(0.03)
	_fails += _check("cap restored after tiering", Engine.max_fps, AdaptiveQuality.FPS_CAP)
	_fails += _check("tier saved", 1 if FileAccess.file_exists(AdaptiveQuality.CFG_PATH) else 0, 1)
	# 存档路径：读档直接应用，不再解除限帧
	var aq2 := AdaptiveQuality.make(_world, _chunks)
	root.add_child(aq2)
	process_frame.connect(func() -> void: _stage_saved(aq2), CONNECT_ONE_SHOT)

func _stage_saved(aq2: AdaptiveQuality) -> void:
	_fails += _check("saved tier keeps cap", Engine.max_fps, AdaptiveQuality.FPS_CAP)
	_fails += _check("saved tier done immediately", 1 if aq2._done else 0, 1)
	DirAccess.remove_absolute(AdaptiveQuality.CFG_PATH)
	_chunks.free()
	if _fails == 0:
		print("adaptive_fps_cap tests PASS (5/5)")
	else:
		printerr("adaptive_fps_cap tests FAILED: %d" % _fails)
	quit(_fails)

func _check(name: String, got: int, want: int) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %d want %d" % [name, got, want])
	return 1
