extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：物品摆放+背包全链路演练。
## 离线 demo 世界直驱内部接口：造物落地 → 长按拾起（悬空）→ 拖拽跟指 →
## 松手落新位 → 再拾起拖到收集册按钮收纳 → 打开物品页 → 点 🎁 摆出。
## 运行（带窗录像，勿改 root.size——会冻结截帧）:
##   MALIANG_API_BASE=http://127.0.0.1:1 godot --path . --write-movie <目录>/props.png \
##     --fixed-fps 8 --quit-after 240 --script res://test/test_visual_props_shot.gd

const SPEC := {
	"name": "小盒子", "palette": ["#e8b04b", "#f4ead4"], "blend": 0.25, "outline": 0.04,
	"parts": [
		{ "shape": "box", "pos": [0, 0.5, 0], "size": [0.7, 0.6, 0.6], "color": 0 },
		{ "shape": "sphere", "pos": [0, 1.0, 0.15], "r": 0.2, "color": 1, "blend": 0.15 },
	],
	"locomotion": { "type": "none" }, "ropes": [],
}
const DRAG_SCREEN := Vector2(760, 380) ## 拖拽目标屏幕点（中偏右的地面）

var scene: Node
var frame := 0

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _pickup() -> void:
	scene.set("_prop_press_id", "p1")
	scene.call("_step_prop_press", 0.7)
	print("[qa] f%d 拾起 drag=%s" % [frame, str(not (scene.get("_prop_drag") as Dictionary).is_empty())])

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	match frame:
		20:
			scene.call("_on_prop_created", { "id": "p1", "spec": SPEC })
			print("[qa] f20 造物落地 tile=", (scene.get("world_props") as Dictionary).get("p1", {}).get("tile"))
		60:
			_pickup() # 长按拾起：悬空拎起
		70:
			(scene.get("_prop_drag") as Dictionary)["screen"] = DRAG_SCREEN # 拖到中偏右地面
		110:
			scene.call("_end_prop_drag", DRAG_SCREEN)
			print("[qa] f110 落新位 tile=", (scene.get("world_props") as Dictionary).get("p1", {}).get("tile"))
		140:
			_pickup()
		150:
			var btn := scene.get("album_button") as Button
			scene.call("_end_prop_drag", btn.get_global_rect().get_center())
			print("[qa] f150 收纳 state=", (scene.get("world_props") as Dictionary).get("p1", {}).get("state"))
		175:
			scene.call("_toggle_album")
			scene.call("_open_app", "items") # 手机物品 app
		205:
			scene.call("_take_prop_out", "p1")
			print("[qa] f205 摆出 tile=", (scene.get("world_props") as Dictionary).get("p1", {}).get("tile"))
