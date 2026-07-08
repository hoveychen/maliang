extends SceneTree
## 加载过场验证：Loading 场景线程加载世界→高层遮罩盖住→world_ready 后淡出交还。
## 断言（离线跑，MALIANG_API_BASE 指向连不上地址，世界走本地占位、bootstrap 提前返回）：
##   1) 过场遮罩就位：Loading 下有 CanvasLayer 且 layer==128（压过世界 HUD 的 layer=1）。
##   2) 世界被线程加载并接管：current_scene 变为 "World"，且此时过场仍在（遮罩盖着）。
##   3) 世界就绪后揭开：Loading 节点被 free，current_scene 仍是存活的 "World"。
## 用轮询标志而非硬帧号，避开首屏铺设/淡出时长的时序抖动。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 90 --script res://test/test_visual_loading.gd

var frame := 0
var fails := 0
var loading: Node

var _saw_overlay := false
var _saw_world_while_covered := false
var _saw_revealed := false

func _initialize() -> void:
	Loading.next_scene = "res://main.tscn"
	loading = load("res://loading.tscn").instantiate()
	root.add_child(loading)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1

	# 1) 过场遮罩就位（趁 Loading 还活着抓一次）
	if not _saw_overlay and is_instance_valid(loading):
		var layers: Array[Node] = loading.find_children("*", "CanvasLayer", true, false)
		if not layers.is_empty():
			_saw_overlay = true
			_check("过场遮罩 CanvasLayer 存在", layers.size() >= 1, true)
			_check("遮罩 layer==128 压过世界 HUD", (layers[0] as CanvasLayer).layer, 128)

	# 2) 世界被线程加载并接管，且此刻过场仍盖着（遮住首屏铺设/网络弹入）
	var cur := current_scene
	if not _saw_world_while_covered and cur != null and cur.name == "World":
		_saw_world_while_covered = true
		_check("世界接管 current_scene 时过场仍在", is_instance_valid(loading), true)

	# 3) 就绪后揭开：Loading 被 free，世界仍存活
	if _saw_world_while_covered and not _saw_revealed and not is_instance_valid(loading):
		_saw_revealed = true
		_check("揭开后 current_scene 仍是存活的 World",
			current_scene != null and current_scene.name == "World", true)

	# 给足首屏铺设(~9帧)+最短显示(600ms)+淡出(0.45s)：fps10 下 ~20 帧内应揭开，留到 70 收口
	if frame == 70:
		_check("过场遮罩曾就位", _saw_overlay, true)
		_check("世界曾被过场盖住接管", _saw_world_while_covered, true)
		_check("世界就绪后过场已揭开(free)", _saw_revealed, true)
		if fails == 0:
			print("visual_loading PASS")
		else:
			printerr("visual_loading FAILED: %d" % fails)
	if frame >= 75:
		quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
