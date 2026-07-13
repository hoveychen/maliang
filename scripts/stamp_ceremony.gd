class_name StampCeremony
extends RefCounted
## 盖章/种花仪式的「见证游标」与分镜推导（纯数据，不碰渲染，headless 可测）。
##
## 为什么需要它：经济全在服务端算死——`addStamp` 一进来就 `stampProgress++`、满 3 立刻变花
## （server/src/persistence.ts settleWallet）。客户端 `_apply_wallet` 收到的永远是**结算后**的
## 结果。想让小朋友「亲手把章盖上去」，客户端必须记住自己**见证到哪儿了**，把服务端已经算完、
## 但小朋友还没看过的那几个章补演出来。
##
## seen = { flowers, stampProgress, stampsTotal }，存 user://profile.json（wallet 是 per-player，
## 不会串台）。`plan()` 拿 (seen, wallet) 差分出一串分镜，演完 `seen = wallet` 硬对齐——
## 离线挣的、admin 补的、满 9 溢出释放的，全部自动收敛，演出永远不会跟账目对不上。
##
## 见 docs/stamp-flower-ux-design.md §3。

const MAX_FLOWERS := 9          ## 与服务端 types.ts MAX_FLOWERS 一致
const STAMPS_PER_FLOWER := 3    ## 与服务端 types.ts STAMPS_PER_FLOWER 一致
## 与服务端 types.ts STAMP_STYLES 一致。收不到真 stampStyle 时按累计序号确定性兜底选一款。
const STYLES := ["star", "smile", "paw", "medal", "heart"]
## 回放上限：一次最多补演这么多个章，超出的静默入账（不让小朋友干等 30 秒）。
const MAX_REPLAY := 6

## 分镜类型
enum Beat {
	STAMP,       ## 盖一个章。slot=落在第几个槽(0..2)，style=章款式
	BLOOM,       ## 三章种出一朵花。cell=长在花田第几格(0..8)
	PLUCK,       ## 一朵花被花掉（造角色/造物扣费）。cell=被摘走的是第几格
	FIELD_FULL,  ## 花田满 9，章卡攒满却种不出花（服务端 stampProgress 停在 3）
}

const PROFILE_KEY := "stamp_seen"

## ── 见证游标持久化 ────────────────────────────────────────────────────────

static func load_seen() -> Dictionary:
	var raw: Variant = PlayerProfile.load_profile().get(PROFILE_KEY, {})
	if typeof(raw) != TYPE_DICTIONARY:
		return empty_seen()
	var d := raw as Dictionary
	return {
		"flowers": int(d.get("flowers", 0)),
		"stampProgress": int(d.get("stampProgress", 0)),
		"stampsTotal": int(d.get("stampsTotal", 0)),
	}

static func save_seen(seen: Dictionary) -> void:
	var p := PlayerProfile.load_profile()
	p[PROFILE_KEY] = {
		"flowers": int(seen.get("flowers", 0)),
		"stampProgress": int(seen.get("stampProgress", 0)),
		"stampsTotal": int(seen.get("stampsTotal", 0)),
	}
	PlayerProfile.save_profile(p)

static func empty_seen() -> Dictionary:
	return { "flowers": 0, "stampProgress": 0, "stampsTotal": 0 }

## 钱包字典 → 只留三个记账字段（hearts 不参与仪式）。
static func snapshot(wallet: Dictionary) -> Dictionary:
	return {
		"flowers": int(wallet.get("flowers", 0)),
		"stampProgress": int(wallet.get("stampProgress", 0)),
		"stampsTotal": int(wallet.get("stampsTotal", 0)),
	}

## 欠盖的章数（手机角标用；不需要整套分镜时的轻量查询）。
static func pending_count(seen: Dictionary, wallet: Dictionary) -> int:
	return maxi(0, int(wallet.get("stampsTotal", 0)) - int(seen.get("stampsTotal", 0)))

## ── 分镜推导 ──────────────────────────────────────────────────────────────

## 从 seen 走到 wallet，产出该演的分镜序列。
##   styles: 在线期间 task_complete 带来的真 stampStyle 队列（先进先出）；取不到就确定性兜底。
## 返回的每个分镜是 { "beat": Beat, ... }，见 Beat 注释。
## 保证：把分镜按顺序应用一遍，末态一定等于 wallet（末尾无条件对齐；见 §3「永远收敛」）。
static func plan(seen: Dictionary, wallet: Dictionary, styles: Array = []) -> Array:
	var beats: Array = []
	var sim := snapshot(seen)
	var target := snapshot(wallet)

	var pending := maxi(0, target["stampsTotal"] - sim["stampsTotal"])
	# 超过回放上限的部分静默入账：先把它们「盖」进 sim，但不产出分镜。
	var silent := maxi(0, pending - MAX_REPLAY)
	if silent > 0:
		print("[stamp] 欠盖 %d 个章，超出回放上限 %d，静默入账 %d 个" % [pending, MAX_REPLAY, silent])
	for i in pending:
		var idx: int = sim["stampsTotal"]  # 这是第几个章（0-based），兜底选款用
		var loud := i >= silent
		sim["stampsTotal"] += 1
		if sim["stampProgress"] >= STAMPS_PER_FLOWER and sim["flowers"] >= MAX_FLOWERS:
			# 花田满 9 + 章卡也满：这个章无处可盖（服务端 settleWallet 把 progress 停在 3，
			# 只有 stampsTotal 在涨）。别硬往满槽上再盖一遍，只提示「花田满了，先用掉一朵」。
			if loud and (beats.is_empty() or beats.back()["beat"] != Beat.FIELD_FULL):
				beats.append({ "beat": Beat.FIELD_FULL })
			continue
		sim["stampProgress"] += 1
		var slot: int = sim["stampProgress"] - 1
		if loud:
			beats.append({ "beat": Beat.STAMP, "slot": slot, "style": _style_for(styles, i, idx) })
		var grew := _settle(sim, beats if loud else [])
		if loud and not grew and sim["stampProgress"] >= STAMPS_PER_FLOWER:
			# 刚把章卡盖满、却没长出花 = 花田正好满 9
			beats.append({ "beat": Beat.FIELD_FULL })

	# 花被花掉（造角色/造物扣费）。注意不能只看 flowers 差分：满 9 时花掉一朵，服务端
	# spendFlower 里的 settleWallet 会立刻把攒满的章兑现补回一朵——花数前后都是 9，差分为 0，
	# 但章卡清空了。所以这里按「还没对上账就再摘一朵」收敛，摘不动了就停。
	for _i in MAX_FLOWERS:
		if sim == target:
			break
		var overflow_released: bool = sim["stampProgress"] > target["stampProgress"] and sim["flowers"] >= MAX_FLOWERS
		if not (sim["flowers"] > target["flowers"] or overflow_released):
			break
		sim["flowers"] -= 1
		beats.append({ "beat": Beat.PLUCK, "cell": sim["flowers"] })
		_settle(sim, beats)  # 腾出格子 → 攒满的章立刻兑现（溢出释放）

	if sim != target:
		# admin 补花 / 后台清账 / 版本迁移之类：不编演出，直接以服务端为准。
		print("[stamp] 演出末态 %s 与服务端 %s 不一致，静默对齐服务端" % [sim, target])
	return beats

## 服务端 settleWallet 的客户端镜像（persistence.ts:41）。长出花就追加 BLOOM 分镜。
static func _settle(sim: Dictionary, beats: Array) -> bool:
	var grew := false
	while sim["stampProgress"] >= STAMPS_PER_FLOWER and sim["flowers"] < MAX_FLOWERS:
		sim["flowers"] += 1
		sim["stampProgress"] -= STAMPS_PER_FLOWER
		beats.append({ "beat": Beat.BLOOM, "cell": sim["flowers"] - 1 })
		grew = true
	if sim["stampProgress"] > STAMPS_PER_FLOWER:
		sim["stampProgress"] = STAMPS_PER_FLOWER
	return grew

## 第 i 个补演的章用哪款：优先吃在线收到的真 stampStyle，取不到就按累计序号确定性兜底
## （离线挣的、重启后补演的都走这条，同一个章每次算出来都一样）。
static func _style_for(styles: Array, i: int, stamp_index: int) -> String:
	if i < styles.size():
		var s := String(styles[i])
		if s in STYLES:
			return s
	return STYLES[stamp_index % STYLES.size()]
