extends SceneTree
## 贴纸贴自己（self-stickers P2/P3，docs/placement-interaction-design.md §3.3 方案 A）：
## 客户端维护「自己 attachments 权威副本」的增量合并逻辑 World._merge_attach（纯函数）。
## - 空列表挂上 → 出现该槽
## - 同槽再挂别的 → 换（不重复、仍一份）
## - 摘下（item_id 空）→ 移除该槽
## - 摘不存在的槽 → 无副作用
## - 多槽互不影响
## 运行: godot --headless --script res://test/test_self_stickers.gd

const World = preload("res://scripts/world.gd")

var fails := 0

func _init() -> void:
	# ── 空列表挂上 ──────────────────────────────────────────────────────────
	var l: Array = []
	l = World._merge_attach(l, "headTop", "sticker_crown")
	_check("空挂上→一份", l.size(), 1)
	_check("槽=headTop", _item_of(l, "headTop"), "sticker_crown")

	# ── 同槽换贴纸：仍一份、换成新 id ────────────────────────────────────────
	l = World._merge_attach(l, "headTop", "sticker_hat")
	_check("同槽换→仍一份", l.size(), 1)
	_check("同槽换→新 id", _item_of(l, "headTop"), "sticker_hat")

	# ── 另一槽挂上：两份、互不影响 ──────────────────────────────────────────
	l = World._merge_attach(l, "handL", "sticker_star")
	_check("另一槽→两份", l.size(), 2)
	_check("headTop 不受影响", _item_of(l, "headTop"), "sticker_hat")
	_check("handL 新增", _item_of(l, "handL"), "sticker_star")

	# ── 摘下 headTop（item_id 空）：只剩 handL ──────────────────────────────
	l = World._merge_attach(l, "headTop", "")
	_check("摘下 headTop→一份", l.size(), 1)
	_check("headTop 已清", _item_of(l, "headTop"), "")
	_check("handL 仍在", _item_of(l, "handL"), "sticker_star")

	# ── 摘不存在的槽：无副作用 ──────────────────────────────────────────────
	l = World._merge_attach(l, "handR", "")
	_check("摘空槽→仍一份", l.size(), 1)
	_check("handL 仍在", _item_of(l, "handL"), "sticker_star")

	# ── 摘光：空列表 ────────────────────────────────────────────────────────
	l = World._merge_attach(l, "handL", "")
	_check("摘光→空", l.size(), 0)

	print("test_self_stickers: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## 取某槽的 itemId（不存在返回空串）。
func _item_of(list: Array, slot: String) -> String:
	for a in list:
		if typeof(a) == TYPE_DICTIONARY and String((a as Dictionary).get("slot", "")) == slot:
			return String((a as Dictionary).get("itemId", ""))
	return ""

func _check(what: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	print("  FAIL %s: got %s want %s" % [what, str(got), str(want)])
	fails += 1
	return 1
