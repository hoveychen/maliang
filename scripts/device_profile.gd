class_name DeviceProfile
extends RefCounted
## 本机标识：GPU 名 + 稳定 device id。用于画质档的众包（见 server/src/device_profile.ts）。
##
## 为什么按 GPU 分桶：市面上 GPU 型号远少于机型，命中率高——绝大多数机器一启动就拿到
## 同型号别人测好的档，全程无感，只有真正的新 GPU 才需要跑一次 benchmark。
##
## device id：一台设备一个稳定 id，让它重测时覆盖自己那票，而不是往众包里重复灌票。
## 存在 profile.json（跟着设备走，不跟着账号走——画质是设备属性）。

## benchmark 口径版本。渲染管线 / 负载场景 / 旋钮集合变了就 +1，让旧样本自然作废。
## 必须与 server/src/device_profile.ts 的 BENCH_VERSION 一致（跨语言，只能靠这行注释互相看住）。
## v2（P5）：压测负载从染色 critter 换成 seed 村民图集（真立绘纹理+idle 动画）、采样期冻结世界动态，
##          渲染成本口径变了 → 旧 v1 众包样本作废。
## v3（benchmark-story-ramp）：采样期不再冻结村民——负载角色注册占用 + ambient wander，村民 wander
##          （A* 寻路 + 走动 CPU）全程计入 p95。旧 v2 冻结口径系统性偏轻、测出全最高，样本作废。
const BENCH_VERSION := 3

const DEVICE_ID_KEY := "device_id"

## 本机 GPU 名（如 "Mali-G57 MC2" / "Adreno (TM) 610" / "Apple A15 GPU"）。
## 服务端会做厂商噪声归一（normalizeGpu），这里原样上报即可。
static func gpu() -> String:
	return RenderingServer.get_video_adapter_name()

## 稳定的设备 id（首次调用时生成并落档案）。
static func device_id() -> String:
	var p := PlayerProfile.load_profile()
	var id := String(p.get(DEVICE_ID_KEY, ""))
	if not id.is_empty():
		return id
	id = Crypto.new().generate_random_bytes(16).hex_encode()
	p[DEVICE_ID_KEY] = id
	PlayerProfile.save_profile(p)
	return id
