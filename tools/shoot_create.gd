extends SceneTree
## 全链验证：加载主场景(自动引导)，等 WS 连上后触发小神仙造角色，监听 gen 事件，按墙钟时间等生成后截图。
## 运行: MALIANG_API_BASE=http://127.0.0.1:8128 Godot --path . --script res://tools/shoot_create.gd

var world: Node = null
var wired := false
var connected := false
var requested := false
var done_ms := -1
var start_ms := 0

func _initialize() -> void:
	world = load("res://main.tscn").instantiate()
	get_root().add_child(world)
	start_ms = Time.get_ticks_msec()

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	if not wired and world.backend != null:
		wired = true
		world.backend.connected.connect(func() -> void:
			connected = true
			printerr("WS CONNECTED"))
		world.backend.gen_complete.connect(func(c: Dictionary) -> void:
			done_ms = Time.get_ticks_msec()
			printerr("GEN_COMPLETE name=%s" % str(c.get("name", "?"))))
		world.backend.failed.connect(func(r: String) -> void: printerr("GEN_FAILED %s" % r))
	if connected and world.online and not requested:
		requested = true
		printerr("→ 触发造角色 (npcs=%d)" % world.npcs.size())
		world._request_create("一只戴黄帽子的小猫")
	# 完成后等 2s 让 sprite 下载+落位；或最长 40s 墙钟
	if (done_ms >= 0 and now - done_ms >= 2000) or (now - start_ms >= 40000):
		var img := get_root().get_viewport().get_texture().get_image()
		img.save_png("res://_m2real.png")
		printerr("FINAL npcs=%d online=%s done=%s" % [world.npcs.size(), str(world.online), str(done_ms >= 0)])
		printerr("SHOT saved")
		return true
	return false
