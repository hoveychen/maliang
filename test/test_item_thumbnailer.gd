extends SceneTree
## ItemThumbnailer(背包物品缩略图混合来源服务)单测。headless 可跑：服务端已烧图路径用桩 api
## 不触发渲染;不可渲染项在 headless 假视口下正好走 null 回退,验证兜底。
## 运行: godot --headless --script res://test/test_item_thumbnailer.gd

var _fails := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		printerr("  ✗ ", msg)
		_fails += 1

## 桩 Api：fetch_texture 为协程(与真 api 一致),按 hash 回预置纹理并计数。
class StubApi extends Node:
	var tex_for := {}
	var calls := 0
	func fetch_texture(hash: String) -> Texture2D:
		calls += 1
		await get_tree().process_frame
		return tex_for.get(hash, null)

func _initialize() -> void:
	# _initialize 阶段节点尚未进树(get_tree() 为 null),与 test_paper_phone 同法:挂进 root 后
	# 等 ready 再跑断言,否则桩 api 的 await get_tree().process_frame 拿到 null 实例。
	var host := Node.new()
	root.add_child(host)
	var api := StubApi.new()
	root.add_child(api)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	var dummy := ImageTexture.create_from_image(img)
	api.tex_for["hashX"] = dummy

	var thumb := ItemThumbnailer.new()
	thumb.setup(host, api)
	thumb.set_server_icons({ "srv_item": "hashX" })
	host.ready.connect(func() -> void: _run(thumb, api, dummy))

## 收集器：真实调用方(phone_ui)是持久连接一次、按 id 收结果——而非 await-per-call
## (同步失败路径会在 request() 内同步 emit,await-per-call 会漏接)。测试照此模式。
var _got := {}          ## id -> tex(可为 null)
var _resolved := {}     ## id -> true(已 emit,区分 null 与未决)

func _on_thumb(id: String, tex: Texture2D) -> void:
	_got[id] = tex
	_resolved[id] = true

func _await_id(id: String) -> void:
	var guard := 0
	while not _resolved.has(id):
		await process_frame
		guard += 1
		if guard > 600:
			printerr("  ✗ 等 %s 超时(600 帧未 emit)" % id)
			_fails += 1
			return

func _run(thumb: ItemThumbnailer, api: StubApi, dummy: Texture2D) -> void:
	thumb.thumbnail_ready.connect(_on_thumb)

	# 1) 服务端已烧图命中：request → 拉图 → emit 该纹理 → 入缓存
	thumb.request("srv_item", { "renderRef": "baked:whatever" })
	await _await_id("srv_item")
	_check(_got.get("srv_item") == dummy, "服务端已烧图命中 → 返回该纹理")
	_check(thumb.has_cached("srv_item"), "结果入缓存")
	_check(api.calls == 1, "拉了一次服务端图")

	# 2) 二次请求走缓存(立即 deferred emit),不重复拉图
	_resolved.erase("srv_item")
	thumb.request("srv_item", {})
	await _await_id("srv_item")
	_check(_got.get("srv_item") == dummy, "二次请求走缓存返回同纹理")
	_check(api.calls == 1, "缓存命中不重复拉图")

	# 3) 无服务端图 + 不可渲染 renderRef → null(调用方回退礼盒)。同步失败路径也能被持久连接接住。
	thumb.request("bad", { "renderRef": "nope:xyz" })
	await _await_id("bad")
	_check(_resolved.has("bad") and _got.get("bad") == null, "无服务端图 + 不可渲染 → null 回退")
	_check(not thumb.has_cached("bad"), "失败项不入缓存(下次可重试)")

	# 4) 空 id 直接忽略,不崩不 emit
	thumb.request("", {})
	_check(true, "空 id 请求不崩")

	thumb.teardown()
	print("item_thumbnailer: fails=%d" % _fails)
	quit(_fails)
