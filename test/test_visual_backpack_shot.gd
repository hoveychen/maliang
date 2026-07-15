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
			# 真实内置 item id：离线也能走客户端现场离屏渲染出真图（P3 缩略图混合来源的「没图现渲」半边）；
			# 给几个份数>1 看右上数量角标。塞 11 件（>8）→ 2 页，看纵向翻页圆点。
			scene.set("bag", {
				"tree_puff_a": 1, "rock_0": 3, "tuft_0": 1, "house_0": 1,
				"bush_puff": 2, "tree_puff_b": 1, "rock_1": 1, "house_1": 5,
				"rock_2": 1, "tree_puff_c": 1, "windmill": 2, "sticker_sun": 1,
			})
		36:
			scene.call("_open_app", "items") # 翻转+展开跨页 → 背包 2×4（方案二 2 列），逐件懒渲缩略图
		70:
			(scene.get("phone_ui") as PhoneUi)._select_item("sticker_sun") # 贴纸详情=4 按钮(摆到地块/装到身上/扔掉/再听一次)看溢不溢出

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)
