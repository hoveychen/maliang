extends SceneTree
## 引路引导台词：小朋友不会自己想到「可以让小仙子带路」，她闲着时主动提一句
## （「想去哪儿玩呀？告诉我，我带你去！」）。
##
## 关键是【门控】：只在还没用过引路时提。用过之后再一遍遍问「想去哪儿玩呀」就成了唠叨——
## 这是这个测试真正要钉住的行为，台词本身反而是次要的。
## 运行：scripts/test-headless.sh

var scene: Node
var frame := 0
var fails := 0
var played_before := false  ## 没用过引路时，引导词播过
var played_after := false   ## 用过引路后，引导词又播了（不该）

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.ready.connect(_setup)
	process_frame.connect(_tick)

func _setup() -> void:
	scene.set("_fairy_greeted", true)  # 跳过问候，直奔闲聊
	scene.set("_poi_check_t", 9999.0)  # 别让 POI 提醒抢她
	scene.set("_fairy_chat_t", 0.2)    # 马上开口

func _fv() -> FairyVoice:
	return scene.get("fairy_voice") as FairyVoice

## 引导词是否真的播过。
## 不能用 can_play("guide_hint")==false 来判——她播【任何】台词都会占住 GLOBAL_GAP，
## 那时 can_play 一样是 false，会把「她刚说了句闲聊」误读成「她播了引导词」。
## 播过某条的确凿证据是它的 id 进了冷却表 _next_ok。
func _hint_played() -> bool:
	var next_ok: Dictionary = (_fv() as FairyVoice).get("_next_ok")
	for id in next_ok:
		if String(id).begins_with("fairy_guide_hint"):
			return true
	return false

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	var fv := _fv()
	if fv == null:
		return

	# 台词池存在性：没有 wav 的话下面的行为断言会假绿
	if frame == 2:
		_check("引导台词已入库（guide_hint 池非空）", (fv.call("_pool", "guide_hint") as Array).size() > 0, true)

	# ── 阶段一：还没用过引路 → 她该主动提示 ──
	if frame > 2 and frame < 40:
		if _hint_played():
			played_before = true

	if frame == 40:
		_check("没用过引路时，她会主动提示「我可以带你去」", played_before, true)
		# 小朋友用了一次引路（她带过一次路了）
		scene.call("start_guide", {
			"targetKind": "location", "targetName": "风车", "targetScene": "village",
			"targetTile": { "tileX": 30, "tileY": 40 }, "legs": [],
		})
		_check("用过引路后置位", scene.get("_guide_used"), true)
		scene.call("end_guide", "")
		# 冷却表清干净（抹掉阶段一的痕迹）+ 让她马上再开口，看她还提不提
		(_fv() as FairyVoice).set("_next_ok", {})
		(_fv() as FairyVoice).set("_global_next_ok", 0.0)
		scene.set("_fairy_chat_t", 0.2)

	# ── 阶段二：用过引路了 → 她不该再念叨 ──
	if frame > 42 and frame < 80:
		if _hint_played():
			played_after = true

	if frame == 80:
		_check("用过引路后不再唠叨引导词", played_after, false)
		if fails == 0:
			print("fairy_guide_hint PASS")
		else:
			printerr("fairy_guide_hint FAILED: %d" % fails)
		quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
