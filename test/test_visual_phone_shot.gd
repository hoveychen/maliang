extends SceneTree
## 临时视觉验证（不进回测，服务人眼 QA）：3D 纸糊双折叠手机 + 集邮册的盖章/种花仪式——
## 掏出弹入动画 → 正面态（白卡纸壳、手写数字时钟、灵动岛、贴纸图标网格）→ 点开小红花 app
## （整机翻转 180°+铰链展开成双宽跨页）→ **橡皮章招手 → 砸下 → 三章化墨越过中缝 → 左页种出
## 一朵小红花** → 返回正面 → 收起。
##
## 编排（--fixed-fps 12）：f8 开手机 → f36 塞钱包（欠 1 章）→ f40 开 flowers（翻转 f40-46，
## 之后仪式自演：招手 1.2s → 自动砸下 → 开花 ~2.1s，约到 f100）→ f120 返回 → f140 收起。
## 仪式一共约 4 秒，返回帧必须留够——早于它就会把仪式中止掉（close_app = 中止不提交）。
##
## 运行: godot --write-movie <目录>/f.png --fixed-fps 12 --quit-after 150 \
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
		36:
			# 摆一个「花田长了 4 朵、章卡攒了 2 个章、还欠 1 个章没盖」的状态：离线世界钱包全 0，
			# 不塞只能看见一张空册子。**必须晚于离线兜底那次 _apply_wallet**，否则被冲掉。
			scene.set("stamp_seen", { "flowers": 4, "stampProgress": 2, "stampsTotal": 14 })
			scene.set("wallet", { "flowers": 5, "stampProgress": 0, "stampsTotal": 15, "hearts": 3 })
		40:
			scene.call("_open_app", "flowers") # 翻转+展开跨页 → 欠 1 章 → 仪式自动开演
		120:
			(scene.get("phone_ui") as PhoneUi).close_app() # 返回正面（此时仪式早已演完）
		140:
			scene.call("_close_phone") # 收起

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)
