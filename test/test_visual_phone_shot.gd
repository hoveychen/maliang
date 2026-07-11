extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：3D 纸糊双折叠手机——
## 掏出弹入动画→正面态（白卡纸壳、铅笔数字时钟、灵动岛、贴纸图标网格）→
## 点开集邮 app（整机翻转 180°+铰链展开成双宽跨页）→ 跨页界面 → 返回正面。
## 编排（--fixed-fps 8）：f8 开手机 → f40 开 flowers（翻转动画 f40-44）→ f80 返回 → f100 收起。
## 运行: godot --write-movie <目录>/f.png --fixed-fps 8 --quit-after 110 \
##       --script res://test/test_visual_phone_shot.gd
## 注意：--write-movie 须带窗跑（headless 段错误），且不要改 root.size（会冻结截帧）。

var scene: Node
var frame := 0

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	match frame:
		8:
			(scene.get("album_button") as Button).emit_signal("pressed") # 开手机→近身相机+弹入
		40:
			scene.call("_open_app", "flowers") # 翻转+展开跨页
		80:
			(scene.get("phone_ui") as PhoneUi).close_app() # 返回正面
		100:
			scene.call("_close_phone") # 收起

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)
