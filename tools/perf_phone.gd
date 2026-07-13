extends SceneTree
## PaperPhone 性能量测：dock/front/spread 三态各采样 N 帧的视口渲染耗时（CPU/GPU）
## 与 draw call 数，printerr 汇报。跑法（带窗，headless 假视口无意义）：
##   $GODOT --path <绝对路径> --script res://tools/perf_phone.gd
## 用于观感改版前后 A/B（同机同窗口对比差值，绝对值受桌面 GPU 影响不代表真机）。

const WARM := 70    ## 每态先热身的帧数
const SAMPLE := 180 ## 每态采样帧数

var _frames := 0
var _world: Node
var _phase := 0
var _t0 := 0
var _cpu := 0.0
var _gpu := 0.0
var _dc := 0.0
var _n := 0

func _initialize() -> void:
	var scene: PackedScene = load("res://main.tscn")
	_world = scene.instantiate()
	get_root().add_child(_world)

func _begin(label: String) -> void:
	_cpu = 0.0
	_gpu = 0.0
	_dc = 0.0
	_n = 0
	printerr("PHASE %s" % label)

func _sample() -> void:
	var rid := get_root().get_viewport_rid()
	_cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	_gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	_dc += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_n += 1

func _report(label: String) -> void:
	printerr("PERFPHONE %s cpu=%.3fms gpu=%.3fms dc=%.0f (n=%d)" %
		[label, _cpu / _n, _gpu / _n, _dc / _n, _n])

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		# Window 本身就是 Viewport；_initialize 阶段 RID 还没就绪，首帧再开量测
		RenderingServer.viewport_set_measure_render_time(get_root().get_viewport_rid(), true)
	match _frames:
		WARM:
			_begin("dock")
		WARM + SAMPLE:
			_report("dock")
			_world._open_phone()
		WARM * 2 + SAMPLE:
			_begin("front")
		WARM * 2 + SAMPLE * 2:
			_report("front")
			_world.phone_ui.open_app("flowers")
		WARM * 3 + SAMPLE * 2:
			_begin("spread")
		WARM * 3 + SAMPLE * 3:
			_report("spread")
			return true
	if _n >= 0 and _frames > WARM and _phase_sampling():
		_sample()
	return false

func _phase_sampling() -> bool:
	return (_frames > WARM and _frames < WARM + SAMPLE) \
		or (_frames > WARM * 2 + SAMPLE and _frames < WARM * 2 + SAMPLE * 2) \
		or (_frames > WARM * 3 + SAMPLE * 2 and _frames < WARM * 3 + SAMPLE * 3)
