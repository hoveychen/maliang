extends SceneTree
## 客户端↔后端 WS 联调：连接 server，发 create_character_request，等 gen_complete。
## 运行: WORLD_ID=<id> Godot --path . --script res://tools/test_backend_ws.gd

var backend: Backend
var frames := 0
var got := false
var sent := false

func _initialize() -> void:
	backend = Backend.new()
	backend.url = "ws://127.0.0.1:8127/ws"
	backend.gen_complete.connect(func(c: Dictionary) -> void:
		printerr("GEN_COMPLETE name=%s" % str(c.get("name", "?")))
		got = true)
	backend.failed.connect(func(r: String) -> void: printerr("FAILED %s" % r))
	get_root().add_child(backend)
	backend.connect_to_server()

func _process(_delta: float) -> bool:
	frames += 1
	if frames == 30 and not sent:
		sent = true
		backend.send_create_character(OS.get_environment("WORLD_ID"), "我想要一只小猫")
	if got or frames > 600:
		printerr("WS EXCHANGE OK" if got else "WS TIMEOUT")
		return true
	return false
