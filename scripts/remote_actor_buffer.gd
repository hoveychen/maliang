class_name RemoteActorBuffer
extends RefCounted
## 远端演员位置插值缓冲：收 positions_relay 的带时戳采样，按 ~200ms 延迟插值出平滑渲染位置。
## 时戳为服务端钟毫秒（发送端本地钟 + 时间偏移）；渲染时把本地钟同样换算到服务端钟再减延迟采样，
## 双端读同一条时间轴，抖动/丢包被延迟窗吸收。
## 环面坐标：用 WorldGrid.shortest_delta 走最短弧插值，避免跨接缝瞬移。
## 纯逻辑（不持节点），便于 headless 单测。设计文档: docs/script-runtime-design.md

const DELAY_MS := 200          ## 插值延迟：留一个缓冲窗吸收网络抖动/丢包（约 1-2 个流间隔）
const MAX_SAMPLES := 24        ## 采样上限（~4s @6Hz），防无界增长
const STALE_MS := 3000         ## 本地钟超过此时长没收到新采样 → 视作离线（拥有者掉线/停流）

var _samples: Array = []       ## [{ t:int(服务端钟), pos:Vector2 }]，按 t 严格升序
var last_recv_ms := 0          ## 最近一次收到采样的本地钟（离线判定用）

## 收一条采样。t 为服务端钟毫秒，pos 为世界坐标。now_local_ms 为收到时的本地钟。
## 迟到（时戳不新于队尾）直接丢，保持单调升序。
func push(t: int, pos: Vector2, now_local_ms: int) -> void:
	last_recv_ms = now_local_ms
	if not _samples.is_empty() and t <= int(_samples[-1]["t"]):
		return
	_samples.append({ "t": t, "pos": pos })
	if _samples.size() > MAX_SAMPLES:
		_samples.pop_front()

## 在渲染时刻（服务端钟毫秒）插值出位置。空缓冲返回 fallback。
## 早于最早采样 → 定在最早；晚于最新采样 → 定在最新（短暂 hold，不外推，避免飘）。
func sample(render_server_ms: int, fallback: Vector2) -> Vector2:
	if _samples.is_empty():
		return fallback
	var target := render_server_ms - DELAY_MS
	if target <= int(_samples[0]["t"]):
		return _samples[0]["pos"]
	if target >= int(_samples[-1]["t"]):
		return _samples[-1]["pos"]
	for i in range(_samples.size() - 1):
		var a: Dictionary = _samples[i]
		var b: Dictionary = _samples[i + 1]
		var ta := int(a["t"])
		var tb := int(b["t"])
		if target >= ta and target <= tb:
			var k := 0.0 if tb == ta else float(target - ta) / float(tb - ta)
			var seg := WorldGrid.shortest_delta(a["pos"], b["pos"])
			return WorldGrid.wrap_pos(a["pos"] + seg * k)
	return _samples[-1]["pos"]

## 拥有者是否已停流/掉线（本地钟距上次收样超过 STALE_MS）。空缓冲也算陈旧。
func is_stale(now_local_ms: int) -> bool:
	if _samples.is_empty():
		return true
	return now_local_ms - last_recv_ms > STALE_MS

func has_samples() -> bool:
	return not _samples.is_empty()
