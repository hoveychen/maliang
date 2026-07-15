class_name Api
extends Node
## 后端 HTTP 客户端：引导世界、拉取生成的 sprite 资源。

## 默认指向 muvee 生产后端；本地开发用 MALIANG_API_BASE 环境变量覆盖。
@export var base := "https://maliang-api.muveeai.com"

## 引导世界的网络超时。必须严格 < World.READY_TIMEOUT_SEC，保证慢网也在 loading 揭幕前定音
## （成功走正常路径 / 超时走离线），杜绝「揭幕后 get_world 才返回、玩家被硬拽到仙子旁」的启动瞬移。
## 该不变量由 test_loading_progress 守护。
const GET_WORLD_TIMEOUT_SEC := 18.0

## 其余请求（POST /onboarding/intro、拉 TTS 音频等）的超时。HTTPRequest.timeout 默认 0 = 无限，
## 服务端 hang 住时界面会永远停在等待图标（onboarding 没有 world.gd 的 _think_timer 兜底）。
## 超时 → request_completed 带非 200 → 调用方拿到空结果走既有的重试/降级路径。
const REQUEST_TIMEOUT_SEC := 40.0

## 资产磁盘缓存目录。资产是内容寻址（hash 即内容摘要，永不变），故缓存永久有效、无需失效——
## 命中即免网络往返，重复进世界不再逐个村民重下贴图/音频。文件名 = hash（十六进制，天然文件名安全）。
const CACHE_DIR := "user://asset_cache"

## 内存里已解码的纹理缓存（本次会话内）：同一 hash 免磁盘读+免重复解码（如仙子 idle 轮询反复取同图）。
var _tex_mem: Dictionary = {}

func _ready() -> void:
	var env := OS.get_environment("MALIANG_API_BASE")
	if not env.is_empty():
		base = env

## hash → 磁盘缓存文件路径（user://asset_cache/<hash>）。
func _cache_path(asset_hash: String) -> String:
	return CACHE_DIR.path_join(asset_hash)

## 读磁盘缓存的裸字节；未命中/读失败返回空 PackedByteArray。
func _cache_read(asset_hash: String) -> PackedByteArray:
	var path := _cache_path(asset_hash)
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var buf := f.get_buffer(f.get_length())
	f.close()
	return buf

## 把裸字节写进磁盘缓存（缺目录先建）。写失败静默（缓存只是加速，失败退化为每次下载）。
func _cache_write(asset_hash: String, buf: PackedByteArray) -> void:
	if asset_hash.is_empty() or buf.is_empty():
		return
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var f := FileAccess.open(_cache_path(asset_hash), FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(buf)
	f.close()

## 按 magic bytes 把图像字节解码成 Image：静态立绘是 PNG，idle 动画图集是 WebP（体积小），
## 亦容 JPG。无法解码返回 null。（fetch_texture 与缓存命中路径共用，避免解码逻辑两处漂移。）
func _load_image_buf(buf: PackedByteArray) -> Image:
	var img := Image.new()
	var e := ERR_INVALID_DATA
	if buf.size() >= 12 and buf[0] == 0x52 and buf[1] == 0x49 and buf[2] == 0x46 and buf[3] == 0x46 \
			and buf[8] == 0x57 and buf[9] == 0x45 and buf[10] == 0x42 and buf[11] == 0x50:
		e = img.load_webp_from_buffer(buf)
	elif buf.size() >= 2 and buf[0] == 0xFF and buf[1] == 0xD8:
		e = img.load_jpg_from_buffer(buf)
	else:
		e = img.load_png_from_buffer(buf)
	return null if e != OK else img

## 同步解码（测试/小图用）。
func _decode_image(buf: PackedByteArray, gpu_compress := false) -> Texture2D:
	var img := _load_image_buf(buf)
	if img == null:
		return null
	if gpu_compress:
		_compress_for_gpu(img)
	return ImageTexture.create_from_image(img)

## 异步解码：PNG/WebP 解码搬 WorkerThreadPool——大图集解码几十 ms 级，主线程做
## 会在下载完成/缓存命中瞬间卡帧。线程里只做 Image 解码 + 块压缩（都是纯 CPU、线程安全），
## ImageTexture.create_from_image 回主线程（涉及 RenderingServer 上传）。
func _decode_image_async(buf: PackedByteArray, gpu_compress := false) -> Texture2D:
	var out: Array = [null]
	var task := WorkerThreadPool.add_task(func() -> void:
		var im := _load_image_buf(buf)
		if im != null and gpu_compress:
			_compress_for_gpu(im)
		out[0] = im)
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)  # 完成后仍需 wait 回收任务句柄
	var img: Image = out[0]
	return null if img == null else ImageTexture.create_from_image(img)

## 动画图集的显存块压缩。
##
## 为什么必须压：一张三段图集是 93 帧 × ~200×256，未压缩 RGBA8 上传 ≈ 17MB 显存/角色。
## 一个场景八九个村民就是 150MB——老 Mali 平板扛不住。块压缩到 1 字节/像素（4×），
## 三套动画反而比压缩前的一套（~6MB）还省。实测 996×1536 的图集压一次只要 4ms。
##
## cell 宽高在服务端已对齐到 4 的倍数（sprite_sheet.ts）：块压缩以 4×4 为块，不对齐的话
## 一个块会横跨相邻两格的边界，压完帧与帧串色。
##
## 格式按平台选：移动端 GLES3/Vulkan 一律有 ETC2；桌面 GPU 一律有 S3TC/BC。反过来都不保证
## （桌面对 ETC2 的支持很参差）。都没有就不压——退回未压缩，只是费显存，不会坏。
func _compress_for_gpu(img: Image) -> void:
	if img.is_compressed():
		return
	var mode := -1
	if OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios"):
		if OS.has_feature("etc2"):
			mode = Image.COMPRESS_ETC2
	elif OS.has_feature("s3tc"):
		mode = Image.COMPRESS_S3TC
	if mode < 0:
		return
	# 失败（尺寸不合法/格式不支持）只是没压成，img 保持未压缩可用——不让它把整张贴图弄丢。
	if img.compress(mode as Image.CompressMode, Image.COMPRESS_SOURCE_SRGB) != OK:
		push_warning("图集显存压缩失败（回退未压缩）：%dx%d" % [img.get_width(), img.get_height()])

## 新建世界（后端会种入点点）。失败返回空字典。
func create_world() -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(base + "/worlds", [], HTTPClient.METHOD_POST)
	if err != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return {}
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else {}

## GET JSON → JSON（path 自带 query）。失败/非 200 返回空字典。
func get_json(path: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_SEC # 服务端 hang 时不让界面永久转圈
	add_child(http)
	var err := http.request(base + path)
	if err != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return {}
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else {}

## 物品缩略图映射（item_id → 资产 hash）：公开只读端点，背包物品页混合来源的「服务端已烧图」半边
## （docs/backpack-page-redesign-design.md §2）。失败/无图返回空字典，调用方回退客户端现场渲染。
func fetch_item_icons() -> Dictionary:
	var data := await get_json("/item-icons")
	var icons: Variant = data.get("icons", {})
	return icons if typeof(icons) == TYPE_DICTIONARY else {}

## 拉取指定世界状态（含角色）。失败返回空字典。
func get_world(id: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = GET_WORLD_TIMEOUT_SEC # 超时 → request_completed 带 res[1]!=200 → 返回 {} 走离线（见常量注释）
	add_child(http)
	var err := http.request(base + "/worlds/" + id)
	if err != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return {}
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else {}

## POST JSON → JSON。失败/非 200 返回空字典。
## timeout_sec 可按调用方收紧（如 onboarding 对话一轮 15s 就该降级，不值得陪满 40s）。
func post_json(path: String, body: Dictionary, timeout_sec := REQUEST_TIMEOUT_SEC) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = timeout_sec # 服务端 hang 时不让界面永久转圈（见常量注释）
	var err := http.request(base + path, PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return {}
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else {}

## 拉取资源 hash → 原始字节（地形 .mltr 等非图片资产）。失败返回空 PackedByteArray。
## 与 fetch_texture 同样先查磁盘缓存再下载（内容寻址，缓存永不失效）。
func fetch_bytes(asset_hash: String) -> PackedByteArray:
	if asset_hash.is_empty():
		return PackedByteArray()
	var cached := _cache_read(asset_hash)
	if not cached.is_empty():
		return cached
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(base + "/assets/" + asset_hash)
	if err != OK:
		http.queue_free()
		return PackedByteArray()
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return PackedByteArray()
	var buf := res[3] as PackedByteArray
	_cache_write(asset_hash, buf) # 落盘供下次免下载
	return buf

## 拉取场景地形矩阵（v2 blob）。返回 { bytes: PackedByteArray, version: int }；
## 失败 bytes 为空。version 已知（scene.terrainVersion）时按 (world,scene,version)
## 磁盘缓存；version<=0（patch 版本对不上后的全量重拉）时跳缓存直连，
## 以响应头 x-terrain-version 为准。
func fetch_terrain(world_id: String, scene_id: String, version := 0) -> Dictionary:
	var none := { "bytes": PackedByteArray(), "version": 0 }
	var cache_key := "terrain_%s_%s_v%d" % [world_id, scene_id, version]
	if version > 0:
		var cached := _cache_read(cache_key)
		if not cached.is_empty():
			return { "bytes": cached, "version": version }
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = REQUEST_TIMEOUT_SEC
	var err := http.request("%s/worlds/%s/scenes/%s/terrain" % [base, world_id, scene_id])
	if err != OK:
		http.queue_free()
		return none
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return none
	var got_version := 0
	for h in res[2] as PackedStringArray:
		var hs := String(h)
		if hs.to_lower().begins_with("x-terrain-version:"):
			got_version = int(hs.get_slice(":", 1).strip_edges())
	var buf := res[3] as PackedByteArray
	if got_version > 0:
		_cache_write("terrain_%s_%s_v%d" % [world_id, scene_id, got_version], buf)
	return { "bytes": buf, "version": got_version }

## 拉取资源 hash → Texture2D（PNG/WebP/JPG）。失败返回 null。
## 三级取源：内存已解码缓存 → 磁盘缓存（免网络）→ 下载后落盘+进内存。资产内容寻址故缓存永不失效。
##
## gpu_compress：解码后做显存块压缩（见 _compress_for_gpu）。动画图集走 true——它是显存大头
## （三段 93 帧，未压缩 ~17MB/角色）。静态立绘/图标走 false：它们小，且会被放大了给孩子看，
## 块压缩的色块瑕疵在大尺寸上更容易被看出来。
func fetch_texture(asset_hash: String, gpu_compress := false) -> Texture2D:
	if asset_hash.is_empty():
		return null
	if _tex_mem.has(asset_hash):
		return _tex_mem[asset_hash]
	# 磁盘缓存命中：解码后进内存，直接返回，不发网络请求
	var cached := _cache_read(asset_hash)
	if not cached.is_empty():
		var ctex := await _decode_image_async(cached, gpu_compress)
		if ctex != null:
			_tex_mem[asset_hash] = ctex
			return ctex
		# 缓存文件损坏（解码失败）：往下走重新下载覆盖
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(base + "/assets/" + asset_hash)
	if err != OK:
		http.queue_free()
		return null
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return null
	var buf := res[3] as PackedByteArray
	var tex := await _decode_image_async(buf, gpu_compress)
	if tex == null:
		return null
	_cache_write(asset_hash, buf) # 落盘供下次免下载（内容寻址，永久有效）
	_tex_mem[asset_hash] = tex
	return tex

## 轮询立绘 idle 动画状态。返回 { status, animAsset?, meta? }；
## status: none(未触发)/pending(生成中)/ready(带 animAsset 图集 hash + meta)/failed。
func fetch_sprite_anim(sprite_hash: String) -> Dictionary:
	if sprite_hash.is_empty():
		return { "status": "none" }
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(base + "/sprite-anim/" + sprite_hash)
	if err != OK:
		http.queue_free()
		return { "status": "none" }
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return { "status": "none" }
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else { "status": "none" }

## 拉取音频资源 hash → { "bytes": PackedByteArray, "rate": int }。
## 采样率从 content-type 解析（audio/L16;rate=24000 —— local Kokoro 24k / 讯飞 16k），缺失回落 16k。
func fetch_audio(asset_hash: String) -> Dictionary:
	var empty := { "bytes": PackedByteArray(), "rate": 16000 }
	if asset_hash.is_empty():
		return empty
	# 磁盘缓存命中：裸 PCM 无自带采样率，rate 存在同名 .rate 旁文件里，两者齐备才算命中
	var cached := _cache_read(asset_hash)
	if not cached.is_empty():
		var rate_buf := _cache_read(asset_hash + ".rate")
		if not rate_buf.is_empty():
			var cr := int(rate_buf.get_string_from_utf8())
			if cr > 0:
				return { "bytes": cached, "rate": cr }
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = REQUEST_TIMEOUT_SEC # 同 post_json：拉音频卡住不能让确认页永久等待
	var err := http.request(base + "/assets/" + asset_hash)
	if err != OK:
		http.queue_free()
		return empty
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return empty
	var rate := 16000
	for h in res[2] as PackedStringArray:
		var line := String(h).to_lower()
		if line.begins_with("content-type:"):
			var idx := line.find("rate=")
			if idx >= 0:
				var parsed := int(line.substr(idx + 5))
				if parsed > 0:
					rate = parsed
			break
	var buf := res[3] as PackedByteArray
	_cache_write(asset_hash, buf) # 落盘 PCM
	_cache_write(asset_hash + ".rate", str(rate).to_utf8_buffer()) # 采样率旁文件
	return { "bytes": buf, "rate": rate }
