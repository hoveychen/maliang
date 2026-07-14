extends SceneTree
## P3：_bootstrap 拆 fetch/apply 两阶段的契约测试。
##   fetch 半段：get_world + 素材预取，**只落缓存/数据，不动场景节点**——离线占位村民仍在、online 仍 false。
##   apply 半段：清占位 + 降生服务端村民 + online=true——场景在这里才变。
## 手法：main.tscn 起来（离线自跑一遍 _bootstrap 保留占位）后换 StubApi（get_world 回假在线世界），
## 手动依次驱动 _bootstrap_fetch / _bootstrap_apply，断言两段各自的可见/不可见副作用。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 60 --script res://test/test_bootstrap_split.gd

const STUB_ID := "stub-villager"

var scene: Node
var frame := 0
var fails := 0
var done := false

class StubApi extends Api:
	func get_world(_id: String) -> Dictionary:
		return {
			"id": "default",
			"items": [],
			"scenes": [], # 空 scenes → _load_server_terrain 早返回，不改地形（隔离本测）
			"characters": [
				{ "id": STUB_ID, "name": "存根村民", "sceneId": "village",
				  "appearance": { "spriteAsset": "spriteX" } },
			],
		}
	func fetch_texture(_asset_hash: String, _gpu_compress := false) -> Texture2D:
		var img := Image.create(40, 60, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 1, 0, 1))
		return ImageTexture.create_from_image(img)
	func fetch_sprite_anim(_sprite_hash: String) -> Dictionary:
		return { "status": "ready", "animAsset": "fakeatlas", "meta": {
			"cols": 2, "rows": 2, "frameCount": 3, "fps": 8, "cellW": 20, "cellH": 30 } }

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null or done:
		return
	frame += 1
	if frame == 12:
		done = true
		_drive() # async 驱动（fire-and-forget，内部 await 两段）

func _count_demos() -> int:
	var n := 0
	for d in (scene.get("npcs") as Array):
		if String(d.get("id", "")).begins_with("demo_"):
			n += 1
	return n

func _has_npc(id: String) -> bool:
	for d in (scene.get("npcs") as Array):
		if String(d.get("id", "")) == id:
			return true
	return false

func _drive() -> void:
	# 换上返回假在线世界的 StubApi
	var stub := StubApi.new()
	stub.name = "StubApi"
	scene.add_child(stub)
	var old: Node = scene.get("api")
	scene.set("api", stub)
	if old != null:
		old.queue_free()

	# 前置：离线自跑的 _bootstrap 已完成，占位村民（demo_）仍在、online=false
	_check("离线态有 demo 占位村民", _count_demos() >= 3, true)
	_check("离线态 online=false", bool(scene.get("online")), false)

	# ── fetch 半段：拉数据/预取，不动场景 ──
	var fetched: Dictionary = await scene.call("_bootstrap_fetch")
	_check("fetch 返回非空（在线）", not fetched.is_empty(), true)
	_check("fetch 带回 world", (fetched.get("world", {}) as Dictionary).has("id"), true)
	_check("fetch 带回 chars", (fetched.get("chars", []) as Array).size() >= 1, true)
	_check("fetch 不动场景：demo 占位仍在", _count_demos() >= 3, true)
	_check("fetch 不动场景：服务端村民尚未降生", _has_npc(STUB_ID), false)
	_check("fetch 不动场景：online 仍 false", bool(scene.get("online")), false)

	# ── apply 半段：转正，清占位+降生服务端村民 ──
	await scene.call("_bootstrap_apply", fetched)
	_check("apply 后 online=true", bool(scene.get("online")), true)
	_check("apply 清掉 demo 占位", _count_demos(), 0)
	_check("apply 降生服务端村民", _has_npc(STUB_ID), true)

	if fails == 0:
		print("bootstrap_split tests PASS")
	else:
		printerr("bootstrap_split tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
	else:
		printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
		fails += 1
