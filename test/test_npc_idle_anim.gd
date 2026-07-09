extends SceneTree
## bug 回归：村民（非仙子）NPC 拿到静态立绘后必须后台轮询 idle 动画，ready 后切图集播放。
## 此前 _spawn_server_character 只给仙子分支接了 _poll_idle_anim，村民分支漏接——
## 服务端图集全部就绪，真机上玩家/仙子会动、村民永远静止。
## 手法：把 world.api 换成 StubApi（fetch_texture/fetch_sprite_anim 立即返回假图/ready），
## 直接调 _spawn_server_character 造一个带 spriteAsset 的村民，断言其 _sheet 被置位（=已切动画）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 80 --script res://test/test_npc_idle_anim.gd

const NPC_ID := "npc-anim-test"

var scene: Node
var frame := 0
var fails := 0

class StubApi extends Api:
	## 静态立绘/图集都回一张 40×60 假图（测试只看 _sheet 是否置位，不看内容）
	func fetch_texture(_asset_hash: String) -> Texture2D:
		var img := Image.create(40, 60, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 1, 0, 1))
		return ImageTexture.create_from_image(img)

	func fetch_sprite_anim(_sprite_hash: String) -> Dictionary:
		return { "status": "ready", "animAsset": "fakeatlas", "meta": {
			"cols": 2, "rows": 2, "frameCount": 3, "fps": 8, "cellW": 20, "cellH": 30,
		} }

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	match frame:
		6:
			_swap_api_and_spawn()
		40:
			_check_npc_animated()
			quit(fails)

func _swap_api_and_spawn() -> void:
	var stub := StubApi.new()
	stub.name = "StubApi"
	scene.add_child(stub)
	var old: Node = scene.get("api")
	scene.set("api", stub)
	if old != null:
		old.queue_free()
	scene.call("_spawn_server_character", {
		"id": NPC_ID,
		"name": "测试熊",
		"appearance": { "spriteAsset": "cafebabe" },
	}, Vector2(10.0, 10.0))

func _check_npc_animated() -> void:
	var node: Node = null
	for d in (scene.get("npcs") as Array):
		if String((d as Dictionary).get("id", "")) == NPC_ID:
			node = (d as Dictionary)["node"]
			break
	if node == null:
		printerr("  FAIL 没找到测试村民 %s" % NPC_ID)
		fails += 1
		return
	var sheet: Dictionary = node.get("_sheet")
	if sheet.is_empty():
		printerr("  FAIL 村民静态立绘未切 idle 动画（_sheet 为空，未接 _poll_idle_anim）")
		fails += 1
	else:
		print("  ok 村民已切 idle 动画（_sheet 置位）")
	if fails == 0:
		print("npc_idle_anim PASS")
	else:
		printerr("npc_idle_anim FAILED: %d" % fails)
