extends SceneTree
## 远端玩家跨端锚点(remote-player-anchors P2,docs/character-anchors-design.md §5):
## presence 里带的 anchors 要灌进远端玩家副本节点,让「别人看到的我」贴纸位也精准(而非 alpha 兜底)。
## 此前 _spawn_remote_actor 只传 sprite 不传 anchors → 远端副本永远走客户端兜底。
## 只验「presence.anchors → 远端节点 _anchors」这段(spriteAsset 留空,离线不拉图,与贴图解耦)。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 --quit-after 30 \
##       --script res://test/test_remote_player_anchors.gd

var scene: Node
var frame := 0
var fails := 0
const ANCHORS := {
	"headTop": { "x": 0.5, "y": 0.08 },
	"handL": { "x": 0.2, "y": 0.6 },
	"handR": { "x": 0.8, "y": 0.6 },
	"source": "vision",
}

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if (scene.get("player") as Dictionary).is_empty():
		return
	if frame < 4:
		return
	# 注入一个带 anchors 的在场玩家(spriteAsset 空:离线不拉图,只验锚点灌入)
	scene.call("_upsert_presence", { "playerId": "remoteX", "name": "小明", "spriteAsset": "", "anchors": ANCHORS })
	var remotes: Dictionary = scene.get("_remote_actors")
	var ra: Dictionary = remotes.get("remoteX", {})
	if ra.is_empty():
		fails += 1
		printerr("  FAIL 远端副本未建立")
	else:
		var node: PaperCharacter = ra.get("node")
		var got: Dictionary = node.get("_anchors")
		_near("headTop.x", got, "headTop", "x", 0.5)
		_near("headTop.y", got, "headTop", "y", 0.08)
		_near("handR.x", got, "handR", "x", 0.8)
	if fails == 0:
		print("remote_player_anchors PASS")
	else:
		printerr("remote_player_anchors FAILED: %d" % fails)
	quit(fails)

func _near(name: String, got: Dictionary, slot: String, axis: String, want: float) -> void:
	var p: Variant = got.get(slot)
	var ok := typeof(p) == TYPE_DICTIONARY and absf(float((p as Dictionary).get(axis, -999.0)) - want) < 0.001
	if ok:
		print("  ok %s" % name)
	else:
		fails += 1
		printerr("  FAIL %s: got=%s want=%f" % [name, str(p), want])
