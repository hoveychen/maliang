extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：背包物品页 4×4 纵向翻页（backpack-redesign P2）。
## 掏出手机 → 塞 20 件物品 → 开「物品」app → 看跨页里 4 列大格、纵向翻页圆点、第一页 16 格铺满。
## 中段拨到第 2 页看剩余 4 格 + snap 吸附。
##
## 运行: godot --write-movie <目录>/f.png --fixed-fps 12 --quit-after 90 \
##       --script res://test/test_visual_backpack_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	match frame:
		8:
			(scene.get("album_button") as Button).emit_signal("pressed") # 开手机
		30:
			var bag := {}
			for i in 20:
				bag["itm_%02d" % i] = (2 if i % 3 == 0 else 1)  # 每 3 件一个份数=2 看角标
			scene.set("bag", bag)
		36:
			scene.call("_open_app", "items") # 翻转+展开跨页 → 背包 4×4
		60:
			(scene.get("phone_ui") as PhoneUi).set("_items_page", 1) # 拨到第 2 页看 snap

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)
