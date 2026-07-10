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

## 按 magic bytes 把图像字节解码成 Texture2D：静态立绘是 PNG，idle 动画图集是 WebP（体积小），
## 亦容 JPG。无法解码返回 null。（fetch_texture 与缓存命中路径共用，避免解码逻辑两处漂移。）
func _decode_image(buf: PackedByteArray) -> Texture2D:
	var img := Image.new()
	var e := ERR_INVALID_DATA
	if buf.size() >= 12 and buf[0] == 0x52 and buf[1] == 0x49 and buf[2] == 0x46 and buf[3] == 0x46 \
			and buf[8] == 0x57 and buf[9] == 0x45 and buf[10] == 0x42 and buf[11] == 0x50:
		e = img.load_webp_from_buffer(buf)
	elif buf.size() >= 2 and buf[0] == 0xFF and buf[1] == 0xD8:
		e = img.load_jpg_from_buffer(buf)
	else:
		e = img.load_png_from_buffer(buf)
	if e != OK:
		return null
	return ImageTexture.create_from_image(img)

## 新建世界（后端会种入小神仙）。失败返回空字典。
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
func post_json(path: String, body: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = REQUEST_TIMEOUT_SEC # 服务端 hang 时不让界面永久转圈（见常量注释）
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

## 拉取资源 hash → Texture2D（PNG/WebP/JPG）。失败返回 null。
## 三级取源：内存已解码缓存 → 磁盘缓存（免网络）→ 下载后落盘+进内存。资产内容寻址故缓存永不失效。
func fetch_texture(asset_hash: String) -> Texture2D:
	if asset_hash.is_empty():
		return null
	if _tex_mem.has(asset_hash):
		return _tex_mem[asset_hash]
	# 磁盘缓存命中：解码后进内存，直接返回，不发网络请求
	var cached := _cache_read(asset_hash)
	if not cached.is_empty():
		var ctex := _decode_image(cached)
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
	var tex := _decode_image(buf)
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
