extends SceneTree
## NpcGreeter 主动社交调度契约（见 docs/villager-social-design.md）。
## 纯调度器：资格判定(性格×熟识度)、全局单槽错峰、接近→到达→收尾状态机。不碰节点/走位。
## 运行: godot --headless --path . --script res://test/test_npc_greeter.gd

var g: NpcGreeter
var _ran := false

func _initialize() -> void:
	g = NpcGreeter.new()
	root.add_child(g)
	process_frame.connect(_run_once)

## 造一个假村民 dict（调度器只读字段，不需要真节点）。
func _npc(id: String, logical: Vector2, social: String, fam: String) -> Dictionary:
	return {
		"id": id, "logical": logical, "is_fairy": false,
		"social_type": social, "familiarity": fam,
		"in_chat": false, "paper_action": "", "greet_free": true, "greet_hijack": false,
	}

func _run_once() -> void:
	if _ran:
		return
	_ran = true
	var fails := 0

	# ── 资格：外向迎陌生人，内向迎熟人 ──
	fails += _check("外向迎陌生人", NpcGreeter.greet_eligible("extrovert", "stranger"), true)
	fails += _check("外向不迎熟人", NpcGreeter.greet_eligible("extrovert", "friend"), false)
	fails += _check("内向迎点头之交", NpcGreeter.greet_eligible("introvert", "acquaintance"), true)
	fails += _check("内向迎朋友", NpcGreeter.greet_eligible("introvert", "friend"), true)
	fails += _check("内向不迎陌生人", NpcGreeter.greet_eligible("introvert", "stranger"), false)
	fails += _check("空类型不迎", NpcGreeter.greet_eligible("", "stranger"), false)

	# ── 命中：近旁的合格外向村民会被挑去主动接近 ──
	var pl := Vector2(0, 0)
	var ext := _npc("ext1", Vector2(5, 0), "extrovert", "stranger") # 半径内(9)、合格
	var act := g.update(0.1, [ext], pl, false)
	fails += _check("合格村民被挑中接近", act.get("type", ""), "approach")
	fails += _check("接近的是它", act.get("cid", ""), "ext1")

	# ── 单槽错峰：已有活跃迎接者时，第二个合格村民不会同时被挑 ──
	var ext2 := _npc("ext2", Vector2(4, 0), "extrovert", "stranger")
	var act2 := g.update(0.1, [ext, ext2], pl, false)
	fails += _check("同一时刻至多一个迎接者（第二个不启动）", act2.get("type", ""), "")

	# ── 接近 → 到达：玩家没动，村民（模拟走近）进入 ARRIVE_DIST 触发 arrived ──
	ext["logical"] = Vector2(NpcGreeter.ARRIVE_DIST - 0.5, 0) # 模拟 follow 把它带到玩家旁
	var act3 := g.update(0.1, [ext, ext2], pl, false)
	fails += _check("到达玩家旁触发 arrived", act3.get("type", ""), "arrived")
	fails += _check("arrived 的是同一个村民", act3.get("cid", ""), "ext1")

	# ── 到达后停留 DWELL：不足则静默，超过则 release 收尾 ──
	var act4 := g.update(0.1, [ext, ext2], pl, false)
	fails += _check("停留期内静默保持（follow 钉住）", act4.get("type", ""), "")
	var act5 := g.update(NpcGreeter.DWELL + 0.1, [ext, ext2], pl, false)
	fails += _check("停留结束 release 收尾", act5.get("type", ""), "release")

	# ── release 后进入全局冷却：紧接着不会立刻再挑下一个 ──
	var act6 := g.update(0.1, [ext2], pl, false)
	fails += _check("收尾后全局冷却内不再启动", act6.get("type", ""), "")

	# ── engaged（玩家在对话/录音）→ 不主动迎接 ──
	var g2 := NpcGreeter.new()
	root.add_child(g2)
	var e := _npc("e", Vector2(3, 0), "extrovert", "stranger")
	fails += _check("engaged 时不迎接", g2.update(0.1, [e], pl, true).get("type", ""), "")

	# ── 超出接近半径 → 不迎接 ──
	var far := _npc("far", Vector2(NpcGreeter.APPROACH_RADIUS + 2.0, 0), "extrovert", "stranger")
	fails += _check("太远不迎接", g2.update(0.1, [far], pl, false).get("type", ""), "")

	# ── 忙碌村民不被挑：in_chat / paper_action / 不空闲 ──
	var g3 := NpcGreeter.new()
	root.add_child(g3)
	var busy := _npc("busy", Vector2(3, 0), "extrovert", "stranger")
	busy["in_chat"] = true
	fails += _check("对话中的村民不迎接", g3.update(0.1, [busy], pl, false).get("type", ""), "")
	var g4 := NpcGreeter.new()
	root.add_child(g4)
	var notfree := _npc("nf", Vector2(3, 0), "extrovert", "stranger")
	notfree["greet_free"] = false
	fails += _check("不空闲（有执行器/被选中）的村民不迎接", g4.update(0.1, [notfree], pl, false).get("type", ""), "")

	# ── 活跃迎接者被抢走（greet_hijack）→ giveup 收尾 ──
	var g5 := NpcGreeter.new()
	root.add_child(g5)
	var v := _npc("v", Vector2(5, 0), "extrovert", "stranger")
	fails += _check("先启动接近", g5.update(0.1, [v], pl, false).get("type", ""), "approach")
	v["greet_hijack"] = true # 玩家点它对话了
	fails += _check("被抢走 → giveup", g5.update(0.1, [v], pl, false).get("type", ""), "giveup")

	# ── 接近超时（玩家一直跑够不着）→ giveup ──
	var g6 := NpcGreeter.new()
	root.add_child(g6)
	var run := _npc("run", Vector2(6, 0), "extrovert", "stranger")
	fails += _check("启动接近", g6.update(0.1, [run], pl, false).get("type", ""), "approach")
	run["logical"] = Vector2(6, 0) # 始终够不着（>ARRIVE_DIST）
	var timeout_act := g6.update(NpcGreeter.TIMEOUT + 0.1, [run], pl, false)
	fails += _check("超时够不着 → giveup", timeout_act.get("type", ""), "giveup")

	if fails == 0:
		print("npc_greeter tests PASS")
	else:
		printerr("npc_greeter tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
