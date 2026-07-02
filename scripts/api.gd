class_name Api
extends Node
## 后端 HTTP 客户端：引导世界、拉取生成的 sprite 资源。

## 默认指向 muvee 生产后端；本地开发用 MALIANG_API_BASE 环境变量覆盖。
@export var base := "https://maliang-api.muveeai.com"

func _ready() -> void:
	var env := OS.get_environment("MALIANG_API_BASE")
	if not env.is_empty():
		base = env

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

## 拉取资源 hash → Texture2D（PNG）。失败返回 null。
func fetch_texture(asset_hash: String) -> Texture2D:
	if asset_hash.is_empty():
		return null
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
	var img := Image.new()
	if img.load_png_from_buffer(res[3] as PackedByteArray) != OK:
		return null
	return ImageTexture.create_from_image(img)

## 拉取音频资源 hash → { "bytes": PackedByteArray, "rate": int }。
## 采样率从 content-type 解析（audio/L16;rate=24000 —— local Kokoro 24k / 讯飞 16k），缺失回落 16k。
func fetch_audio(asset_hash: String) -> Dictionary:
	var empty := { "bytes": PackedByteArray(), "rate": 16000 }
	if asset_hash.is_empty():
		return empty
	var http := HTTPRequest.new()
	add_child(http)
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
	return { "bytes": res[3] as PackedByteArray, "rate": rate }
