class_name AdaptiveQuality
extends Node
## 移动端自适应画质：进世界后按真机实测帧时定档一次，持久化到 user://quality.cfg。
## 桌面不挂本节点（天然满配）。档位与旋钮（按真机分解扫频账单排序）：
##   T0 强机:  3D 原生分辨率、SDF 吸附 4/4、地形全细节
##   T1 默认:  0.7 降采样、吸附 2/1、地形全细节
##   T2 弱机:  0.6 降采样、吸附 2/1、地形低细节（路/崖壁免第二张细节贴图采样）
## 定档：无存档时忽略前 WARMUP 秒（加载/首帧 shader 编译尖峰），随后 WINDOW 秒
## 平均帧时 >T2_MS 落 T2、<T0_MS 升 T0，否则 T1；应用后存档，之后每次启动直接用
## 存档档位不再测（删 user://quality.cfg 可重新基准测试）。

const CFG_PATH := "user://quality.cfg"
## 移动端全局帧率上限（menu 入口设置，跨场景持久）。水彩世界大部分画面静止，
## 60fps 满速重绘是长期运行发热主因；30fps 单帧功耗近乎减半、观感损失极小。
## 低处理器模式无效——仙子/天空/水面永远在动，达不到"无重绘"条件，只能 cap。
const FPS_CAP := 30
const WARMUP := 6.0
const WINDOW := 4.0
const T2_MS := 55.0   ## 平均帧时超此值落 T2（≈18fps 以下）
const T0_MS := 26.0   ## 平均帧时低于此值升 T0（≈38fps 以上，余量给原生分辨率）
const SCALES := [1.0, 0.7, 0.6]

var _world: Node3D
var _chunks: ChunkManager
var _t := 0.0
var _frames := 0
var _done := false

static func make(world: Node3D, chunks: ChunkManager) -> AdaptiveQuality:
	var a := AdaptiveQuality.new()
	a.name = "AdaptiveQuality"
	a._world = world
	a._chunks = chunks
	return a

func _ready() -> void:
	var saved := _load_tier()
	if saved >= 0:
		_apply(saved)
		_done = true
	else:
		# 首次基准测量：临时解除帧率上限，否则平均帧时被 cap 钳在 33ms 以上，
		# T0 阈值(26ms)永远够不着、强机被误判。测完 _process 里恢复。
		Engine.max_fps = 0

func _process(delta: float) -> void:
	if _done:
		return
	_t += delta
	if _t <= WARMUP:
		return
	_frames += 1
	if _t < WARMUP + WINDOW:
		return
	var avg_ms := WINDOW * 1000.0 / maxf(float(_frames), 1.0)
	var tier := 1
	if avg_ms > T2_MS:
		tier = 2
	elif avg_ms < T0_MS:
		tier = 0
	print("ADAPTIVE avg=%.1fms -> tier T%d" % [avg_ms, tier])
	if tier != 1:  # T1 就是当前状态，不必重复应用
		_apply(tier)
	_save_tier(tier)
	Engine.max_fps = FPS_CAP  # 基准测量结束，恢复上限（见 _ready 的临时解除）
	_done = true

func _apply(tier: int) -> void:
	_world.get_viewport().scaling_3d_scale = SCALES[tier]
	SdfProp.set_snap_iters(4 if tier == 0 else 2, 4 if tier == 0 else 1, get_tree())
	_chunks.set_terrain_low_detail(tier == 2)

func _load_tier() -> int:
	if not FileAccess.file_exists(CFG_PATH):
		return -1
	var f := FileAccess.open(CFG_PATH, FileAccess.READ)
	var tier := int(f.get_line())
	return tier if tier >= 0 and tier <= 2 else -1

func _save_tier(tier: int) -> void:
	var f := FileAccess.open(CFG_PATH, FileAccess.WRITE)
	f.store_line(str(tier))
