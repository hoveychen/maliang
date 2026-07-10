class_name HudFactory
extends RefCounted
## 舞台 HUD 工厂：计分板 / 倒计时 / toast 三种覆盖层控件，挂在传入的 CanvasLayer 上。
## 由 world.gd 的舞台宿主驱动（stage_cmd 的 hud_* → 这里渲染）；step() 每帧推进倒计时与 toast 过期。
## 倒计时归零经 on_timer_done(id) 上报（world 转成 stage_event(timer, subId) 过网），双端读数用服务端时戳。
## 设计文档: docs/script-runtime-design.md
##
## 无状态跨场：clear() 收场时移除全部控件；一场演出内 id 唯一（脚本侧 hudN 递增）。

const TOAST_SEC := 2.2   ## toast 停留秒数（含淡出）
const COUNT_FONT := 64   ## 倒计时大字号（幼儿远看清）
const SCORE_FONT := 30
const TOAST_FONT := 28

var _parent: Node                 ## 承载控件的 CanvasLayer（world 的 _hud_layer）
var _on_timer_done: Callable      ## (id:String) -> void：某倒计时归零时回调
var _scores := {}                 ## id -> { row:HBoxContainer, val_label:Label, value:int }
var _timers := {}                 ## id -> { label:Label, deadline_ms:int, fired:bool }
var _toasts: Array = []           ## [{ label:Label, expire_ms:int }]
var _score_box: VBoxContainer     ## 计分板容器（右上角竖排）
var _count_label: Label           ## 倒计时大字（顶部居中，多个倒计时共用一处显示最紧迫的）

func setup(parent: Node, on_timer_done: Callable) -> void:
	_parent = parent
	_on_timer_done = on_timer_done

## 计分板：新建一行「标签 值」，初值 0。同 id 重复创建则复用。
func score(id: String, label: String) -> void:
	if _scores.has(id):
		return
	_ensure_score_box()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var name_label := Label.new()
	name_label.text = label + "："
	_style(name_label, SCORE_FONT)
	var val_label := Label.new()
	val_label.text = "0"
	_style(val_label, SCORE_FONT)
	row.add_child(name_label)
	row.add_child(val_label)
	_score_box.add_child(row)
	_scores[id] = { "row": row, "val_label": val_label, "value": 0 }

## 计分板加分（可负）。
func score_add(id: String, n: int) -> void:
	var s: Dictionary = _scores.get(id, {})
	if s.is_empty():
		return
	s["value"] = int(s["value"]) + n
	(s["val_label"] as Label).text = str(s["value"])

## 倒计时：deadline_ms 为本地 Time.get_ticks_msec() 口径的截止时刻（world 用服务端时戳换算）。
## 同 id 重复创建则重置截止时刻。
func countdown(id: String, deadline_ms: int) -> void:
	_ensure_count_label()
	_timers[id] = { "label": _count_label, "deadline_ms": deadline_ms, "fired": false }
	_refresh_count()

## 取消倒计时（脚本 cancel() 或收场）。
func cancel_timer(id: String) -> void:
	_timers.erase(id)
	_refresh_count()

## 顶部飘一条提示，TOAST_SEC 后自动消失。
func toast(text: String) -> void:
	if _parent == null:
		return
	var label := Label.new()
	label.text = text
	label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	label.offset_top = 200.0
	label.offset_bottom = 240.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style(label, TOAST_FONT)
	_parent.add_child(label)
	_toasts.append({ "label": label, "expire_ms": Time.get_ticks_msec() + int(TOAST_SEC * 1000.0) })

## 每帧推进：倒计时读数刷新 + 归零触发 on_timer_done；toast 过期移除。
func step(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not _timers.is_empty():
		var fired: Array = []
		for id in _timers:
			var t: Dictionary = _timers[id]
			if not bool(t["fired"]) and now >= int(t["deadline_ms"]):
				t["fired"] = true
				fired.append(id)
		_refresh_count()
		for id in fired:
			if _on_timer_done.is_valid():
				_on_timer_done.call(id) # 回调里可能 cancel/clear，末尾统一做
	if not _toasts.is_empty():
		var kept: Array = []
		for e in _toasts:
			if now >= int(e["expire_ms"]):
				(e["label"] as Label).queue_free()
			else:
				kept.append(e)
		_toasts = kept

## 收场清空：移除全部 HUD 控件（计分板/倒计时/toast），下一场重建。
func clear() -> void:
	for s in _scores.values():
		(s["row"] as Node).queue_free()
	_scores.clear()
	_timers.clear()
	for e in _toasts:
		(e["label"] as Label).queue_free()
	_toasts.clear()
	if _score_box != null:
		_score_box.queue_free()
		_score_box = null
	if _count_label != null:
		_count_label.queue_free()
		_count_label = null

## 倒计时显示：取所有未归零倒计时里最紧迫（deadline 最小）的秒数，向上取整。全归零则清空文字。
func _refresh_count() -> void:
	if _count_label == null:
		return
	var now := Time.get_ticks_msec()
	var soonest := -1
	for t in _timers.values():
		if bool(t["fired"]):
			continue
		var dl := int(t["deadline_ms"])
		if soonest < 0 or dl < soonest:
			soonest = dl
	if soonest < 0:
		_count_label.text = ""
		_count_label.visible = false
		return
	var remain_ms: int = maxi(0, soonest - now)
	_count_label.text = str(int(ceil(float(remain_ms) / 1000.0)))
	_count_label.visible = true

func _ensure_score_box() -> void:
	if _score_box != null or _parent == null:
		return
	_score_box = VBoxContainer.new()
	_score_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_score_box.offset_left = -260.0
	_score_box.offset_right = -20.0
	_score_box.offset_top = 220.0
	_score_box.alignment = BoxContainer.ALIGNMENT_END
	_parent.add_child(_score_box)

func _ensure_count_label() -> void:
	if _count_label != null or _parent == null:
		return
	_count_label = Label.new()
	_count_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_count_label.offset_top = 120.0
	_count_label.offset_bottom = 120.0 + float(COUNT_FONT) + 12.0
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style(_count_label, COUNT_FONT)
	_count_label.visible = false
	_parent.add_child(_count_label)

## 统一描边白字（与 world._style_label 同风格，但 HudFactory 自持不依赖 world 私有方法）。
func _style(l: Label, size: int) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 6)
