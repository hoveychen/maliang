extends SceneTree
## P7 验证（需本地 mock 服务端）：档案(称呼+生成形象 hash) → 进世界 →
## 玩家角色应用档案形象（贴图替换+5 单位归一）与称呼。
## 运行: MALIANG_API_BASE=http://127.0.0.1:8095 godot --headless --script res://test/test_visual_world_profile.gd

var fails := 0
var world: Node = null
var _t0 := 0

func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	_run()

func _run() -> void:
	# 1) 通过 mock 服务端生成一张玩家形象（1x1 stub）
	var api := Api.new()
	root.add_child(api)
	await process_frame # 等 api._ready 读环境变量（SceneTree 自身信号）
	var res: Dictionary = await api.post_json("/player-sprite", { "visualDescription": "一个可爱的小女孩形象" })
	var hash := String(res.get("spriteAsset", ""))
	_check("sprite generated", hash.length() > 0, true)
	# 2) 档案落盘
	PlayerProfile.save_profile({ "name": "朵朵", "nickname": "朵朵", "sprite_asset": hash })
	# 3) 进世界
	world = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(world)
	process_frame.connect(_tick)

func _tick() -> void:
	if world == null:
		return
	var player: Dictionary = world.get("player")
	if not player.is_empty():
		var node: Sprite3D = player["node"]
		var applied: bool = node.texture != null and node.texture.get_height() == 1 # mock 1x1 stub
		if applied:
			_check("player sprite applied", applied, true)
			_check("pixel_size normalized to 5", absf(node.pixel_size - 5.0) < 0.01, true)
			_check("player name from profile", node.get("char_name"), "朵朵")
			_done()
			return
	if Time.get_ticks_msec() - _t0 > 15000:
		fails += 1
		printerr("  FAIL sprite never applied")
		_done()

func _done() -> void:
	PlayerProfile.clear()
	if fails == 0:
		print("visual_world_profile PASS")
	else:
		printerr("visual_world_profile FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
