extends SceneTree
## 临时视觉验证(不进回测):真实游戏世界里,玩家被真实的树挡住时穿透剪影的观感。
## 带窗跑:
##   MALIANG_API_BASE=http://127.0.0.1:1 godot --path . --quit-after 90 \
##     --script res://test/test_visual_xray_ingame_shot.gd
## 输出 /tmp/xray_ingame.png。用游戏自带的 baked 树 mesh + SdfStaticBaker 材质,
## 放在玩家与相机之间(相机方位固定 +Z),让树挡住玩家。

const TREE := preload("res://assets/sdf_props/baked/tree_puff_b.res")

var scene: Node
var frame := 0
var tree: MeshInstance3D

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	# 拉近相机、压低俯角,让树与玩家的前后遮挡更明显
	scene.set("_target_dist", 11.0)
	scene.set("_target_pitch", 22.0)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	frame += 1
	if frame == 1:
		player["logical"] = TerrainMap.tile_center(Vector2i(37, 37)) # 广场空地取景
		return
	if frame == 6 and tree == null:
		var node := player["node"] as PaperCharacter
		var wp := node.global_position
		var cam := scene.get("camera") as Camera3D
		# 朝相机的水平方向(不管方位角),把树放在相机↔玩家连线上、朝相机 2.2m 处
		var to_cam := cam.global_position - wp
		to_cam.y = 0.0
		var dir_h := to_cam.normalized()
		tree = MeshInstance3D.new()
		tree.mesh = TREE
		tree.material_override = SdfStaticBaker.material()
		tree.scale = Vector3.ONE * 1.35
		# 朝相机 1.9m,并下沉 1.6m 让茂密树冠盖住玩家上半身(截图演示,非真实摆放)
		tree.position = wp + dir_h * 1.9 + Vector3(0.0, -1.6, 0.0)
		scene.add_child(tree)
		return
	if frame == 12:
		var vp := root.get_viewport()
		var img := vp.get_texture().get_image()
		img.save_png("/tmp/xray_ingame.png")
		print("[xray-ingame] saved /tmp/xray_ingame.png size=%dx%d" % [img.get_width(), img.get_height()])
		quit(0)
