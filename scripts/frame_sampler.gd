class_name FrameSampler
extends RefCounted
## 帧时采样器：丢掉 warmup 段（管线稳态 + 首次 shader 编译尖峰 + 换档后的重建），随后收集
## window 秒内每帧耗时，给出 p95 帧时（毫秒）。
##
## 为什么看 p95 不看均值：「跑稳 30fps」要的是不掉帧。一段 90% 轻帧 + 10% 卡顿的序列，
## 均值可能只有 20ms（看着达标），p95 却是 50ms（实际每秒都在掉帧、孩子看得见）。
## benchmark 的达标线 GraphicsSettings.TARGET_FRAME_MS 就是拿 p95 去比的。
##
## 纯逻辑、不碰渲染：真机上由 benchmark 把 _process 的 delta 喂进来；单测直接喂构造好的
## 帧时序列，因此贪心求解的正确性不依赖有没有 GPU。

const WARMUP := 1.2   ## 换档后丢弃的秒数（材质重建/管线回稳）
const WINDOW := 2.4   ## 计入统计的秒数

var _warmup: float
var _window: float
var _t := 0.0
var _ms: Array[float] = []

func _init(warmup: float = WARMUP, window: float = WINDOW) -> void:
	_warmup = warmup
	_window = window

## 喂一帧（秒）。warmup 段只走时钟不记账；窗口满后不再收样本。
func feed(delta: float) -> void:
	if is_done():
		return
	_t += delta
	if _t <= _warmup:
		return
	_ms.append(delta * 1000.0)

## 窗口是否采满（贪心据此推进到下一档）。
func is_done() -> bool:
	return _t > _warmup + _window

## 是否还在 warmup 段（这段帧被丢弃、不计 p95）。embedded benchmark 据此把「世界成形」的动静
## 安排在采样窗【间隙】（warmup）里，让计入统计的 window 段保持静止（可复现帧）。纯读取，不改采样。
func is_warming() -> bool:
	return _t <= _warmup

## p95 帧时（毫秒）；还没有样本时返回 0。
func p95_ms() -> float:
	if _ms.is_empty():
		return 0.0
	var s := _ms.duplicate()
	s.sort()
	var idx := int(ceil(0.95 * float(s.size()))) - 1
	return s[clampi(idx, 0, s.size() - 1)]

## 采到的帧数（样本太少说明窗口内根本没几帧——本身就是「非常卡」的信号）。
func sample_count() -> int:
	return _ms.size()

## 换下一档前复位（复用同一个采样器，不必重建）。
func reset() -> void:
	_t = 0.0
	_ms.clear()
