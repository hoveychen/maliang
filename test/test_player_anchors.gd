extends SceneTree
## 玩家立绘锚点接线(player-fairy-anchors P1,docs/character-anchors-design.md §2.2/§2.3):
## 服务端 /player-sprite 返回体带 anchors,客户端须存进设备档案并在 _apply_player_sprite
## 时灌进玩家 PaperCharacter——此前三处写档只取 spriteAsset、_apply_player_sprite_to 从不
## set_anchors,anchors 被整个丢弃(本测试即为堵这条漏接)。
## 只验「档案里的 anchors → 玩家节点 _anchors」这段接线,与贴图加载解耦(离线拉不到图也应灌入)。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 30 \
##       --script res://test/test_player_anchors.gd

var scene: Node
var frame := 0
var fails := 0
const ANCHORS := {
	"headTop": { "x": 0.5, "y": 0.08 },
	"handL": { "x": 0.2, "y": 0.6 },
	"handR": { "x": 0.8, "y": 0.6 },
}

func _initialize() -> void:
	# 先落一份带 anchors 的档案(模拟造角色时服务端返回体已存档),再启世界。
	# sprite_asset 特意留空:离线无法拉图,只验锚点灌入这段(与贴图解耦)。
	var prof := PlayerProfile.load_profile()
	prof["sprite_asset"] = ""
	prof["anchors"] = ANCHORS.duplicate(true)
	PlayerProfile.save_profile(prof)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if (scene.get("player") as Dictionary).is_empty():
		return
	if frame < 4:
		return
	scene.call("_apply_player_sprite")
	var node: PaperCharacter = (scene.get("player") as Dictionary).get("node")
	var got: Dictionary = node.get("_anchors")
	_near("headTop.x", got, "headTop", "x", 0.5)
	_near("headTop.y", got, "headTop", "y", 0.08)
	_near("handL.x", got, "handL", "x", 0.2)
	_near("handR.x", got, "handR", "x", 0.8)
	if fails == 0:
		print("player_anchors PASS")
	else:
		printerr("player_anchors FAILED: %d" % fails)
	quit(fails)

func _near(name: String, got: Dictionary, slot: String, axis: String, want: float) -> void:
	var p: Variant = got.get(slot)
	var ok := typeof(p) == TYPE_DICTIONARY and absf(float((p as Dictionary).get(axis, -999.0)) - want) < 0.001
	if ok:
		print("  ok %s" % name)
	else:
		fails += 1
		printerr("  FAIL %s: got=%s want=%f" % [name, str(p), want])
