class_name ConfirmBar
extends VBoxContainer
## 语音确认条（VoiceCapture.confirm_mode 的那层 UI）：说完先把刚录的话放给孩子听，
## 他点「就是这样」才发出去，点「再说一次」就重录。world 与 onboarding 共用一份——
## 两个宿主各画一遍必然漂移（VoiceCapture 当初就是被两份手抄的编排逼出来的）。
##
## 三个键，全是图标，不识字也能用：
##   耳朵 = 再听一遍   对勾 = 就是这样   转圈 = 再说一次
## 识别到的文字也显示一行，但那是给家长看的——孩子认的是自己的声音。
##
## 用法：
##   var bar := ConfirmBar.new(); layer.add_child(bar)
##   bar.replay_pressed.connect(_vc.replay)
##   bar.accept_pressed.connect(_vc.accept)
##   bar.retry_pressed.connect(_vc.retry)
##   _vc.confirm_ready.connect(func(t): bar.show_for(t))   # 亮条
##   _vc.committed.connect(bar.hide_bar)                   # 采纳后收条

signal replay_pressed
signal accept_pressed
signal retry_pressed

const ICON_SIDE := 72.0      ## 主按钮（就是这样）的图标边长：幼儿手指够粗，键要大
const ICON_SIDE_SUB := 60.0  ## 次按钮（再听/再说）

var _text_label: Label

func _init() -> void:
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 10)
	visible = false

	_text_label = Label.new()
	_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UiAssets.style_card_label(_text_label, 26)
	add_child(_text_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)
	# 顺序按孩子的动作频次排：多数时候是「对，就是这样」，所以对勾摆中间、最大。
	var again := UiAssets.icon_button("ic_ear", ICON_SIDE_SUB)
	again.pressed.connect(func() -> void: replay_pressed.emit())
	row.add_child(again)
	var yes := UiAssets.icon_button("ic_yes", ICON_SIDE)
	yes.pressed.connect(func() -> void: accept_pressed.emit())
	row.add_child(yes)
	var retry := UiAssets.icon_button("ic_retry", ICON_SIDE_SUB)
	retry.pressed.connect(func() -> void: retry_pressed.emit())
	row.add_child(retry)
	add_child(row)

## 亮确认条（VoiceCapture 已经在回放那句话了）。text=识别到的文字，给家长看。
func show_for(text: String) -> void:
	_text_label.text = text
	visible = true

func hide_bar() -> void:
	visible = false
