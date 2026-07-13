extends SceneTree
## 盖章/种花仪式的分镜推导（StampCeremony.plan）。
## 锁死三件事：
##   ① 演出末态永远收敛到服务端 wallet（离线挣的、admin 补的、溢出释放的都不能演跑偏）；
##   ② 花田满 9 时章卡攒满不长花（服务端 settleWallet 把 progress 停在 3），只提示 FIELD_FULL；
##   ③ 章的款式：在线有真 stampStyle 就用真的，没有就按累计序号确定性兜底（重启补演不漂移）。
## 运行: godot --headless --path . --script res://test/test_stamp_ceremony.gd

const B := StampCeremony.Beat

func _init() -> void:
	var fails := 0
	fails += _t_single_stamp()
	fails += _t_third_stamp_blooms()
	fails += _t_offline_replay()
	fails += _t_field_full()
	fails += _t_full_release_on_spend()
	fails += _t_pluck()
	fails += _t_styles()
	fails += _t_replay_cap()
	fails += _t_backwards_snap()
	print("== test_stamp_ceremony: %d 失败 ==" % fails)
	quit(fails)

## 一个章 → 一拍 STAMP，落在第 1 个槽
func _t_single_stamp() -> int:
	var beats := StampCeremony.plan(
		{ "flowers": 3, "stampProgress": 0, "stampsTotal": 0 },
		{ "flowers": 3, "stampProgress": 1, "stampsTotal": 1 })
	var f := 0
	f += _eq("单章：一拍", beats.size(), 1)
	f += _eq("单章：是 STAMP", beats[0]["beat"], B.STAMP)
	f += _eq("单章：落第 0 槽", beats[0]["slot"], 0)
	return f

## 第三个章 → STAMP 后紧跟 BLOOM，花长在下一个空格
func _t_third_stamp_blooms() -> int:
	var beats := StampCeremony.plan(
		{ "flowers": 4, "stampProgress": 2, "stampsTotal": 8 },
		{ "flowers": 5, "stampProgress": 0, "stampsTotal": 9 })
	var f := 0
	f += _eq("第三章：两拍", beats.size(), 2)
	f += _eq("第三章：先盖章", beats[0]["beat"], B.STAMP)
	f += _eq("第三章：盖在第 2 槽", beats[0]["slot"], 2)
	f += _eq("第三章：后开花", beats[1]["beat"], B.BLOOM)
	f += _eq("第三章：长在第 4 格（0-based）", beats[1]["cell"], 4)
	return f

## 离线挣的 3 个章：一次补演 3 拍章 + 1 拍花
func _t_offline_replay() -> int:
	var beats := StampCeremony.plan(
		{ "flowers": 0, "stampProgress": 0, "stampsTotal": 0 },
		{ "flowers": 1, "stampProgress": 0, "stampsTotal": 3 })
	var f := 0
	f += _eq("离线补演：4 拍", beats.size(), 4)
	f += _eq("离线补演：末拍开花", beats[3]["beat"], B.BLOOM)
	f += _eq("离线补演：花在第 0 格", beats[3]["cell"], 0)
	return f

## 花田满 9：章卡盖满也不长花，只提示 FIELD_FULL；再来的章无处可盖（不重复盖第 3 槽）
func _t_field_full() -> int:
	# 满 9 花、已攒 2 章 → 再挣 2 个章：第 1 个盖满第 3 槽 + FIELD_FULL；第 2 个只提示一次
	var beats := StampCeremony.plan(
		{ "flowers": 9, "stampProgress": 2, "stampsTotal": 30 },
		{ "flowers": 9, "stampProgress": 3, "stampsTotal": 32 })
	var f := 0
	f += _eq("满 9：拍数", beats.size(), 2)
	f += _eq("满 9：先盖满第 3 槽", beats[0]["beat"], B.STAMP)
	f += _eq("满 9：槽位 2", beats[0]["slot"], 2)
	f += _eq("满 9：提示花田满", beats[1]["beat"], B.FIELD_FULL)
	f += _eq("满 9：不重复提示", _count(beats, B.FIELD_FULL), 1)
	f += _eq("满 9：一朵花都不长", _count(beats, B.BLOOM), 0)
	return f

## 满 9 溢出释放：花掉一朵 → 服务端 spendFlower 里 settle 立刻把攒满的章兑现
## 客户端表现为：先摘走一朵，再种回来一朵（花数不变，但章卡清空了）
func _t_full_release_on_spend() -> int:
	var beats := StampCeremony.plan(
		{ "flowers": 9, "stampProgress": 3, "stampsTotal": 33 },
		{ "flowers": 9, "stampProgress": 0, "stampsTotal": 33 })
	var f := 0
	f += _eq("溢出释放：两拍", beats.size(), 2)
	f += _eq("溢出释放：先摘花", beats[0]["beat"], B.PLUCK)
	f += _eq("溢出释放：摘第 8 格", beats[0]["cell"], 8)
	f += _eq("溢出释放：再种回来", beats[1]["beat"], B.BLOOM)
	f += _eq("溢出释放：种回第 8 格", beats[1]["cell"], 8)
	return f

## 造角色扣 1 朵花 → 摘花演出
func _t_pluck() -> int:
	var beats := StampCeremony.plan(
		{ "flowers": 3, "stampProgress": 1, "stampsTotal": 4 },
		{ "flowers": 2, "stampProgress": 1, "stampsTotal": 4 })
	var f := 0
	f += _eq("摘花：一拍", beats.size(), 1)
	f += _eq("摘花：是 PLUCK", beats[0]["beat"], B.PLUCK)
	f += _eq("摘花：摘走第 2 格（最后一朵）", beats[0]["cell"], 2)
	return f

## 款式：在线的真 stampStyle 优先；超出部分按累计序号确定性兜底
func _t_styles() -> int:
	var seen := { "flowers": 0, "stampProgress": 0, "stampsTotal": 0 }
	var wallet := { "flowers": 0, "stampProgress": 2, "stampsTotal": 2 }
	var beats := StampCeremony.plan(seen, wallet, ["paw"])
	var f := 0
	f += _eq("款式：真 style 优先", beats[0]["style"], "paw")
	f += _eq("款式：兜底按序号（第 1 个章 → STYLES[1]）", beats[1]["style"], StampCeremony.STYLES[1])
	# 同一个章重算两次必须同款（重启补演不能漂移）
	var again := StampCeremony.plan(seen, wallet)
	f += _eq("款式：兜底确定性", again[0]["style"], StampCeremony.STYLES[0])
	# 非法 style 落回兜底
	var bad := StampCeremony.plan(seen, { "flowers": 0, "stampProgress": 1, "stampsTotal": 1 }, ["banana"])
	f += _eq("款式：非法 style 落兜底", bad[0]["style"], StampCeremony.STYLES[0])
	return f

## 回放上限：欠太多章时只演最后 MAX_REPLAY 个，但账目照样对齐
func _t_replay_cap() -> int:
	var n := StampCeremony.MAX_REPLAY + 5
	var beats := StampCeremony.plan(
		{ "flowers": 0, "stampProgress": 0, "stampsTotal": 0 },
		{ "flowers": n / 3, "stampProgress": n % 3, "stampsTotal": n })
	var f := 0
	f += _eq("回放上限：章拍数不超上限", _count(beats, B.STAMP), StampCeremony.MAX_REPLAY)
	# 静默入账的那几个章不产出 BLOOM，但末态由调用方 snap 到 wallet —— 这里只断言没超演
	f += _eq("回放上限：不多演", 1 if beats.size() <= StampCeremony.MAX_REPLAY * 2 else 0, 1)
	return f

## 账目倒退（admin 清账/迁移）：不编演出，交给调用方静默对齐
func _t_backwards_snap() -> int:
	var beats := StampCeremony.plan(
		{ "flowers": 5, "stampProgress": 2, "stampsTotal": 17 },
		{ "flowers": 3, "stampProgress": 0, "stampsTotal": 0 })
	var f := 0
	# stampsTotal 倒退 → pending=0，不盖章；花少了 2 朵 → 摘花两拍（合理演出，不算跑偏）
	f += _eq("倒退：不盖章", _count(beats, B.STAMP), 0)
	f += _eq("倒退：摘走 2 朵", _count(beats, B.PLUCK), 2)
	return f

## ── 断言工具 ──────────────────────────────────────────────────────────────

func _count(beats: Array, kind: int) -> int:
	var n := 0
	for b in beats:
		if int(b["beat"]) == kind:
			n += 1
	return n

func _eq(label: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  OK   %s" % label)
		return 0
	printerr("  FAIL %s: 得到 %s，期望 %s" % [label, str(got), str(want)])
	return 1
