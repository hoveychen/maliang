extends SceneTree
## Item3DViewer(物品详情 live 3D 查看器)+ ItemThumbnailer.build_item_node(抽出的复用节点工厂)单测。
## headless 可跑：只验节点工厂分发与 setup 返回值(能否造出 3D 节点),不触发渲染/取景(假视口渲不了)。
## 运行: godot --headless --script res://test/test_item_3d_viewer.gd

var _fails := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		printerr("  ✗ ", msg)
		_fails += 1

func _sdf_def() -> Dictionary:
	return {
		"id": "it1", "worldId": "w", "name": "小球",
		"renderRef": "sdf_inline",
		"spec": {
			"name": "小球", "palette": ["#e8b04b"],
			"parts": [{ "shape": "sphere", "pos": [0, 0.5, 0], "r": 0.3, "color": 0 }],
			"locomotion": { "type": "none" }, "ropes": [],
		},
	}

func _sticker_def() -> Dictionary:
	return { "id": "st1", "worldId": "w", "name": "太阳贴纸", "renderRef": "sticker:@abc", "mount": "edge" }

func _initialize() -> void:
	# build_item_node：造物 sdf_inline → 出 Node3D；贴纸 → null（详情页据此回落平面图）。
	var n := ItemThumbnailer.build_item_node(_sdf_def())
	_check(n != null and n is Node3D, "build_item_node(sdf_inline) 出 3D 节点")
	if n != null:
		n.free()
	_check(ItemThumbnailer.build_item_node(_sticker_def()) == null, "build_item_node(贴纸) → null")
	_check(ItemThumbnailer.build_item_node({ "renderRef": "" }) == null, "build_item_node(无 renderRef) → null")

	# Item3DViewer.setup：造物 → true（造出模型）；贴纸 → false（调用方回落）。
	var host := Node.new()
	root.add_child(host)
	var v := Item3DViewer.new()
	host.add_child(v)
	_check(v.setup(_sdf_def()) == true, "Item3DViewer.setup(造物) → true")
	var v2 := Item3DViewer.new()
	host.add_child(v2)
	_check(v2.setup(_sticker_def()) == false, "Item3DViewer.setup(贴纸) → false")

	print("item_3d_viewer: fails=%d" % _fails)
	quit(_fails)
