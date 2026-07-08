class_name PerfSweep
extends Node
## 真机性能分解扫频（debug 诊断）：world 在 debug 构建且 user://perf_sweep 标记
## 文件存在时挂载。每个状态驻留 DWELL 秒（前半程稳态、后半程计帧），逐项隐藏
## 一类渲染负载并打印该状态的实测 fps 到 stdout/logcat（grep SWEEP），
## 得到「谁吃掉多少毫秒」的分解账单。跑完自动删标记并恢复现场。
##
## 启动方式（debug 包可 run-as）：
##   adb shell run-as com.hoveychen.maliang touch files/perf_sweep && 重启应用进世界
## 读数：adb logcat -s godot | grep SWEEP

const DWELL := 6.0     ## 每状态驻留秒数（前 3s 让管线稳态，后 3s 计帧）
const STATES := [
	"base",        # 现状基线（阴影关/0.7 降采样）
	"no_scatter",  # 隐藏树/灌木/石/草 MultiMesh（散布顶点吞吐）
	"no_props",    # 隐藏 SDF 可动物件（重顶点 shader：逐顶点 smooth-min 吸附）
	"no_terrain",  # 隐藏地面/崖壁（水彩多层 fragment）
	"no_water",    # 隐藏水面（透明混合 + 泡沫）
	"no_sky",      # 程序化天空换纯色（全屏天空 fragment）
	"scale_05",    # 3D 降采样 0.5（像素填充率余量）
	"scale_10",    # 3D 原生分辨率（像素填充率上限）
]

var _world: Node3D
var _env: Environment
var _i := -1
var _t := 0.0
var _frames := 0

static func make(world: Node3D, env: Environment) -> PerfSweep:
	var s := PerfSweep.new()
	s.name = "PerfSweep"
	s._world = world
	s._env = env
	return s

func _process(delta: float) -> void:
	if _i >= STATES.size():
		return
	_t += delta
	if _i >= 0 and _t > DWELL * 0.5:
		_frames += 1  # 后半程计帧
	if _t < DWELL and _i >= 0:
		return
	if _i >= 0:
		var fps := float(_frames) / (DWELL * 0.5)
		print("SWEEP %-10s fps=%.1f frame_ms=%.1f" % [STATES[_i], fps, 1000.0 / maxf(fps, 0.1)])
		_apply(STATES[_i], false)
	_i += 1
	_t = 0.0
	_frames = 0
	if _i >= STATES.size():
		print("SWEEP done")
		DirAccess.remove_absolute("user://perf_sweep")  # 一次性：跑完自动摘标记
		return
	_apply(STATES[_i], true)

func _apply(state: String, on: bool) -> void:
	var hide := on
	match state:
		"no_scatter":
			for n in get_tree().get_nodes_in_group("perf_scatter"):
				(n as Node3D).visible = not hide
		"no_props":
			for n in get_tree().get_nodes_in_group("perf_props"):
				(n as Node3D).visible = not hide
		"no_terrain":
			for n in get_tree().get_nodes_in_group("perf_terrain"):
				(n as Node3D).visible = not hide
		"no_water":
			for n in get_tree().get_nodes_in_group("perf_water"):
				(n as Node3D).visible = not hide
		"no_sky":
			if on:
				_env.background_mode = Environment.BG_COLOR
				_env.background_color = Color(0.62, 0.81, 0.94)
			else:
				_env.background_mode = Environment.BG_SKY
		"scale_05":
			_world.get_viewport().scaling_3d_scale = 0.5 if on else 0.7
		"scale_10":
			_world.get_viewport().scaling_3d_scale = 1.0 if on else 0.7
