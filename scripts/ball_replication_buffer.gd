class_name BallReplicationBuffer
extends RefCounted
## C 档球的位置复制缓冲：比 RemoteActorBuffer（A 档闲逛，200ms 插值、到头 hold）更适合反射球——
## 更短延迟窗 + 到头按速度【外推】（dead reckoning）而非 hold，避免球在两拍之间僵住。
## 见 realtime-game-primitives-design §5 网码杠杆 1（客户端预测/外推）+ 杠杆 3（快实体单独调网码）。
## 具体延迟/外推上限/纠偏阈值＝真机量测参数（P3）；此处给保守缺省，纯逻辑便于 headless 单测。
## 环面坐标：位移一律走 WorldGrid.shortest_delta 最短弧，避免跨接缝瞬移。

const DELAY_MS := 80            ## 插值延迟窗（比 A 档 200ms 短，反射手感优先）；P3 真机调
const EXTRAP_MAX_MS := 250      ## 外推上限：超过就不再往前推（owner 掉线/停流，球别一直飞）
const MAX_SAMPLES := 24         ## 采样上限（防无界增长）
const STALE_MS := 1500          ## 比 A 档 3000 短：球停流更快判失联（交回 host 兜底）
const SNAP_DIST := 4.0          ## 纠偏：目标与当前渲染差超此距离→直接 snap（大误差硬纠，幼儿园容忍瞬移）
const SMOOTH_RATE := 18.0       ## 平滑纠偏速率（世界单位/秒）：小误差每帧朝目标逼近这么多，不硬跳

var _samples: Array = []        ## [{ t:int(服务端钟), pos:Vector2, vel:Vector2 }]，按 t 严格升序
var last_recv_ms := 0           ## 最近收样的本地钟（失联判定）

## 收一条采样（带速度供外推）。迟到（时戳不新于队尾）直接丢，保持单调升序。
func push(t: int, pos: Vector2, vel: Vector2, now_local_ms: int) -> void:
	last_recv_ms = now_local_ms
	if not _samples.is_empty() and t <= int(_samples[-1]["t"]):
		return
	_samples.append({ "t": t, "pos": pos, "vel": vel })
	if _samples.size() > MAX_SAMPLES:
		_samples.pop_front()

## 权威时间轴位置：窗内插值；早于最早→定最早；晚于最新→按最新速度【外推】（上限 EXTRAP_MAX_MS）。
## 空缓冲返回 fallback。这是「权威目标」，渲染前还要过 reconcile 平滑。
func sample(render_server_ms: int, fallback: Vector2) -> Vector2:
	if _samples.is_empty():
		return fallback
	var target := render_server_ms - DELAY_MS
	if target <= int(_samples[0]["t"]):
		return _samples[0]["pos"]
	var last: Dictionary = _samples[-1]
	if target >= int(last["t"]):
		# 外推：owner 的球在两拍之间仍在滚，按最新速度线性外推（上限截断防飞出）
		var dt_ms: int = mini(target - int(last["t"]), EXTRAP_MAX_MS)
		var vel: Vector2 = last["vel"]
		return WorldGrid.wrap_pos(last["pos"] + vel * (float(dt_ms) / 1000.0))
	for i in range(_samples.size() - 1):
		var a: Dictionary = _samples[i]
		var b: Dictionary = _samples[i + 1]
		var ta := int(a["t"])
		var tb := int(b["t"])
		if target >= ta and target <= tb:
			var k := 0.0 if tb == ta else float(target - ta) / float(tb - ta)
			var seg := WorldGrid.shortest_delta(a["pos"], b["pos"])
			return WorldGrid.wrap_pos(a["pos"] + seg * k)
	return last["pos"]

## 和解/纠偏（§5）：把当前渲染位置朝权威 target 收敛。误差大→snap（观感容忍瞬移），
## 误差小→按 SMOOTH_RATE 平滑逼近（不硬跳，观感优先）。current==INF 表示首帧→直接落 target。
func reconcile(current: Vector2, target: Vector2, delta: float) -> Vector2:
	if current == Vector2.INF or delta <= 0.0:
		return target
	var err := WorldGrid.shortest_delta(current, target)  # current→target 最短环面位移
	var dist := err.length()
	if dist >= SNAP_DIST:
		return target
	var step := SMOOTH_RATE * delta
	if dist <= step:
		return target
	return WorldGrid.wrap_pos(current + err.normalized() * step)

## 拥有者是否已停流/掉线（本地钟距上次收样超过 STALE_MS）。空缓冲也算陈旧。
func is_stale(now_local_ms: int) -> bool:
	if _samples.is_empty():
		return true
	return now_local_ms - last_recv_ms > STALE_MS

func has_samples() -> bool:
	return not _samples.is_empty()
