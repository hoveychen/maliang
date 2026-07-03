extends Control
## 童话书 onboarding：翻页绘本讲故事 + 图标问题 + 自我介绍 + 形象生成。
## 面向 3 岁小朋友：不依赖文字——大图标演出 + 预制 TTS 旁白（assets/voice/onboarding/）。
## 页面由 PAGES 声明式驱动；answers 收集到 PlayerProfile。
## kind: story(讲故事,点击/旁白结束后翻页) | question(图标选项) | intro(ASR 自我介绍,P5)
##       | generate(形象生成确认,P6)

const VOICE_DIR := "res://assets/voice/onboarding"
const FLIP_TIME := 0.35

## 问题选项 value 直接入档案；icon 为超大演出图标（Android 需真机验 emoji 渲染，见 P8）。
const PAGES := [
	{ "id": "story_1", "kind": "story", "icons": "🌲🌷🌈", "voice": "ob_story_1" },
	{ "id": "story_2", "kind": "story", "icons": "🧚🖌️✨", "voice": "ob_story_2", "fairy": true },
	{ "id": "story_3", "kind": "story", "icons": "🚪🌟🎈", "voice": "ob_story_3" },
	{ "id": "q_gender", "kind": "question", "field": "gender", "voice": "ob_q_gender", "options": [
		{ "icon": "👦", "value": "boy", "voice": "ob_opt_boy" },
		{ "icon": "👧", "value": "girl", "voice": "ob_opt_girl" },
	] },
	{ "id": "q_color", "kind": "question", "field": "color", "voice": "ob_q_color", "options": [
		{ "icon": "", "value": "红色", "voice": "ob_opt_red", "color": Color(0.94, 0.35, 0.35) },
		{ "icon": "", "value": "蓝色", "voice": "ob_opt_blue", "color": Color(0.35, 0.55, 0.94) },
		{ "icon": "", "value": "黄色", "voice": "ob_opt_yellow", "color": Color(0.98, 0.83, 0.3) },
		{ "icon": "", "value": "绿色", "voice": "ob_opt_green", "color": Color(0.42, 0.82, 0.45) },
	] },
	{ "id": "q_likes", "kind": "question", "field": "likes", "voice": "ob_q_likes", "options": [
		{ "icon": "🐰", "value": "小兔子", "voice": "ob_opt_rabbit" },
		{ "icon": "🐱", "value": "小猫", "voice": "ob_opt_cat" },
		{ "icon": "🐶", "value": "小狗", "voice": "ob_opt_dog" },
		{ "icon": "🦖", "value": "小恐龙", "voice": "ob_opt_dino" },
	] },
	{ "id": "q_interest", "kind": "question", "field": "interest", "voice": "ob_q_interest", "options": [
		{ "icon": "🎨", "value": "画画", "voice": "ob_opt_draw" },
		{ "icon": "⚽", "value": "踢球", "voice": "ob_opt_ball" },
		{ "icon": "🎵", "value": "唱歌", "voice": "ob_opt_sing" },
		{ "icon": "📚", "value": "听故事", "voice": "ob_opt_story" },
	] },
	{ "id": "intro", "kind": "intro", "voice": "ob_intro_ask" },
	{ "id": "generate", "kind": "generate", "voice": "ob_generating" },
]

var answers: Dictionary = {}
var page_idx := -1
var _page: Control = null          ## 当前页容器（翻页时旧页被收走）
var _book: PanelContainer
var _voice: AudioStreamPlayer
var _flipping := false
var _story_auto_t := 0.0           ## story 页自动翻页倒计时（旁白结束后）

# 自我介绍（intro 页）：按住说话 → 转写 → 名字确认，多轮重问
const INTRO_MAX_TRIES := 3         ## 重问上限；仍没听到就先叫「小朋友」，进游戏后还能改
var api: Api
var mic: MicRecorder
var _intro_recording := false
var _intro_pcm := PackedByteArray()
var _intro_tries := 0
var _intro_status: Label = null    ## 🎤/🔴/⏳ 状态演出
var _intro_confirm: Control = null ## ✓/✗ 确认行
var _pending := {}                 ## 待确认 {name, nickname, transcript}
var _asr_local: Object = null      ## 端侧 ASR（Android MaliangAsr），null=服务端识别
var _local_session := false

# 形象生成（generate 页）：intro 页起预取，✓采用 / ↻重生成
var _gen_status: Label = null
var _gen_img: TextureRect = null
var _gen_confirm: Control = null
var _prefetch_state := ""          ## "" | pending | done | failed
var _prefetch_hash := ""
var _prefetch_tex: Texture2D = null

func _ready() -> void:
	_setup_background()
	_setup_book()
	_voice = AudioStreamPlayer.new()
	add_child(_voice)
	api = Api.new()
	api.name = "Api"
	add_child(api)
	mic = MicRecorder.new()
	mic.name = "MicRecorder"
	add_child(mic)
	_setup_local_asr()
	_setup_skip()
	_next_page()

## 端侧 ASR（与 world.gd 同路由策略：插件就绪走本地，否则整段 PCM 上传）。
func _setup_local_asr() -> void:
	if not Engine.has_singleton("MaliangAsr"):
		return
	_asr_local = Engine.get_singleton("MaliangAsr")
	_asr_local.connect("final_result", _on_local_final)
	_asr_local.connect("asr_error", func(_msg: String) -> void:
		_asr_local = null
		_local_session = false)
	_asr_local.initialize()

func _exit_tree() -> void:
	# 场景切走时断开插件信号，防悬空回调
	if _asr_local != null:
		if _asr_local.is_connected("final_result", _on_local_final):
			_asr_local.disconnect("final_result", _on_local_final)

func _setup_background() -> void:
	var bg := TextureRect.new()
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0.55, 0.72, 0.92), Color(0.92, 0.88, 0.78)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	bg.texture = tex
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

func _setup_book() -> void:
	_book = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.98, 0.92) # 米色书页
	style.set_corner_radius_all(28)
	style.set_content_margin_all(28.0)
	style.shadow_color = Color(0.2, 0.25, 0.3, 0.35)
	style.shadow_size = 18
	_book.add_theme_stylebox_override("panel", style)
	_book.set_anchors_preset(Control.PRESET_CENTER)
	_book.offset_left = -520.0
	_book.offset_right = 520.0
	_book.offset_top = -300.0
	_book.offset_bottom = 300.0
	add_child(_book)

func _setup_skip() -> void:
	# 家长用的小跳过按钮（右上角，半透明不抢戏）
	var skip := Button.new()
	skip.text = "跳过 ▸"
	skip.add_theme_font_size_override("font_size", 22)
	skip.modulate = Color(1, 1, 1, 0.55)
	skip.flat = true
	skip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	skip.offset_left = -140.0
	skip.offset_top = 16.0
	skip.offset_bottom = 56.0
	skip.pressed.connect(_finish)
	add_child(skip)

# ── 翻页与页面渲染 ─────────────────────────────────────────────────────────

func _next_page() -> void:
	if _flipping:
		return
	if page_idx + 1 >= PAGES.size():
		_finish()
		return
	page_idx += 1
	_flip_to(_build_page(PAGES[page_idx]))

## 书页翻转：旧页横向压扁（绕左脊）→ 新页展开。
func _flip_to(next_page: Control) -> void:
	_flipping = true
	var old := _page
	_page = next_page
	if old != null:
		var tw := create_tween()
		tw.tween_property(old, "scale:x", 0.0, FLIP_TIME).set_ease(Tween.EASE_IN)
		tw.tween_callback(old.queue_free)
	next_page.scale.x = 0.0
	_book.add_child(next_page)
	var tw2 := create_tween()
	tw2.tween_interval(FLIP_TIME if old != null else 0.0)
	tw2.tween_property(next_page, "scale:x", 1.0, FLIP_TIME).set_ease(Tween.EASE_OUT)
	tw2.tween_callback(func() -> void:
		_flipping = false
		_on_page_shown(PAGES[page_idx]))

func _build_page(p: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 30)
	box.pivot_offset = Vector2(0.0, 300.0) # 绕左脊翻
	match String(p["kind"]):
		"story": _build_story(box, p)
		"question": _build_question(box, p)
		"intro": _build_intro(box, p)
		"generate": _build_generate(box, p)
	return box

func _build_story(box: VBoxContainer, p: Dictionary) -> void:
	if p.get("fairy", false):
		var img := TextureRect.new()
		img.texture = load("res://assets/fairy.png")
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.custom_minimum_size = Vector2(300.0, 205.0)
		img.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(img)
	var icons := Label.new()
	icons.text = String(p.get("icons", "✨"))
	icons.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icons.add_theme_font_size_override("font_size", 120 if not p.get("fairy", false) else 72)
	box.add_child(icons)
	var hint := Button.new()
	hint.text = "▶"
	hint.add_theme_font_size_override("font_size", 44)
	hint.flat = true
	hint.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	hint.pressed.connect(_next_page)
	box.add_child(hint)

func _build_question(box: VBoxContainer, p: Dictionary) -> void:
	var q := Label.new()
	q.text = "❓"
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	q.add_theme_font_size_override("font_size", 64)
	box.add_child(q)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 36)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	for opt in (p["options"] as Array):
		row.add_child(_option_button(p, opt as Dictionary))
	box.add_child(row)

## 图标大按钮：emoji 或纯色圆角块（颜色题用色块，不依赖 emoji 渲染）。
func _option_button(p: Dictionary, opt: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(170.0, 170.0)
	b.text = String(opt.get("icon", ""))
	b.add_theme_font_size_override("font_size", 96)
	var style := StyleBoxFlat.new()
	style.bg_color = opt.get("color", Color(0.96, 0.93, 0.85))
	style.set_corner_radius_all(32)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = (style.bg_color as Color).lightened(0.12)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.pressed.connect(func() -> void: _on_option(p, opt, b))
	return b

func _on_option(p: Dictionary, opt: Dictionary, btn: Button) -> void:
	if _flipping:
		return
	answers[String(p["field"])] = String(opt["value"])
	_play(String(opt.get("voice", "")))
	# 选中反馈：弹一下再翻页
	btn.pivot_offset = btn.size * 0.5
	var tw := create_tween()
	tw.tween_property(btn, "scale", Vector2(1.18, 1.18), 0.12)
	tw.tween_property(btn, "scale", Vector2.ONE, 0.12)
	tw.tween_interval(0.5)
	tw.tween_callback(_next_page)

## ASR 自我介绍：按住大话筒说话 → 转写 → 提取名字 → TTS 复述确认（✓/✗），多轮重问。
func _build_intro(box: VBoxContainer, _p: Dictionary) -> void:
	_intro_tries = 0
	_intro_status = Label.new()
	_intro_status.text = "🎤"
	_intro_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_intro_status.add_theme_font_size_override("font_size", 110)
	box.add_child(_intro_status)

	var hold := Button.new()
	hold.text = "按住说话"
	hold.add_theme_font_size_override("font_size", 40)
	hold.custom_minimum_size = Vector2(360.0, 110.0)
	hold.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.95, 0.55, 0.45)
	style.set_corner_radius_all(55)
	hold.add_theme_stylebox_override("normal", style)
	var down := style.duplicate() as StyleBoxFlat
	down.bg_color = Color(0.85, 0.35, 0.3)
	hold.add_theme_stylebox_override("pressed", down)
	hold.add_theme_stylebox_override("hover", style)
	hold.button_down.connect(_intro_start)
	hold.button_up.connect(_intro_stop)
	box.add_child(hold)

	# 名字确认行：听完「你叫X对不对呀」后点 ✓/✗（初始隐藏）
	_intro_confirm = HBoxContainer.new()
	(_intro_confirm as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	(_intro_confirm as HBoxContainer).add_theme_constant_override("separation", 40)
	_intro_confirm.visible = false
	for spec in [["✓", Color(0.45, 0.8, 0.45), true], ["✗", Color(0.9, 0.5, 0.45), false]]:
		var b := Button.new()
		b.text = String(spec[0])
		b.custom_minimum_size = Vector2(130.0, 110.0)
		b.add_theme_font_size_override("font_size", 64)
		var s := StyleBoxFlat.new()
		s.bg_color = spec[1]
		s.set_corner_radius_all(30)
		b.add_theme_stylebox_override("normal", s)
		b.add_theme_stylebox_override("hover", s)
		b.add_theme_stylebox_override("pressed", s)
		b.pressed.connect(_on_intro_confirm.bind(bool(spec[2])))
		(_intro_confirm as HBoxContainer).add_child(b)
	box.add_child(_intro_confirm)
	_intro_confirm.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

func _intro_start() -> void:
	if _intro_recording:
		return
	_voice.stop() # 别和旁白抢
	_intro_recording = true
	_intro_pcm = PackedByteArray()
	_intro_status.text = "🔴"
	mic.start()
	_local_session = _asr_local != null and _asr_local.isReady()
	if _local_session:
		_asr_local.startSession()

func _intro_stop() -> void:
	if not _intro_recording:
		return
	_intro_recording = false
	_drain_intro()
	mic.stop()
	_intro_status.text = "⏳"
	if _local_session:
		_asr_local.stopSession() # final_result 信号回来后 _on_local_final
	else:
		_submit_intro("", _intro_pcm)

func _drain_intro() -> void:
	var chunk := mic.drain_pcm16k()
	if chunk.is_empty():
		return
	if _local_session:
		_asr_local.feedPcm(chunk)
	else:
		_intro_pcm.append_array(chunk)

func _on_local_final(text: String) -> void:
	_local_session = false
	_submit_intro(text.strip_edges(), PackedByteArray())

## 提交自我介绍：转写（端侧）或 PCM（服务端识别）→ 名字 + 确认音频。
func _submit_intro(transcript: String, pcm: PackedByteArray) -> void:
	var body := {}
	if not transcript.is_empty():
		body["transcript"] = transcript
	elif not pcm.is_empty():
		body["pcmBase64"] = Marshalls.raw_to_base64(pcm)
		body["rate"] = 16000
	else:
		_intro_retry()
		return
	var res := await api.post_json("/onboarding/intro", body)
	var name := String(res.get("name", ""))
	if name.is_empty():
		_intro_retry()
		return
	_pending = {
		"name": name,
		"nickname": String(res.get("nickname", name)),
		"transcript": String(res.get("transcript", transcript)),
	}
	_intro_status.text = "😊"
	var audio := await api.fetch_audio(String(res.get("confirmTtsAsset", "")))
	_play_pcm(audio["bytes"] as PackedByteArray, int(audio["rate"]))
	_intro_confirm.visible = true

## 没听到名字：重问（预制 retry 音频），到达上限先叫「小朋友」继续，不卡住小朋友。
func _intro_retry() -> void:
	_intro_tries += 1
	if _intro_tries >= INTRO_MAX_TRIES:
		answers["name"] = ""
		answers["nickname"] = "小朋友"
		_next_page()
		return
	_intro_status.text = "🎤"
	_play("ob_intro_retry")

func _on_intro_confirm(yes: bool) -> void:
	_intro_confirm.visible = false
	if yes:
		answers["name"] = String(_pending.get("name", ""))
		answers["nickname"] = String(_pending.get("nickname", "小朋友"))
		answers["intro"] = String(_pending.get("transcript", ""))
		_next_page()
	else:
		_intro_retry()

## 播服务端返回的 PCM16 音频（确认语等运行期合成内容）。
func _play_pcm(bytes: PackedByteArray, rate: int) -> void:
	if bytes.is_empty():
		return
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	_voice.stop()
	_voice.stream = wav
	_voice.play()

## 形象生成确认：答案拼描述 → 生图（intro 页起就预取，生图 ~1min 与说话时间重叠）
## → 展示 → ✓采用 / ↻再变一次。离线/失败直接放行（占位形象进世界，不卡小朋友）。
func _build_generate(box: VBoxContainer, _p: Dictionary) -> void:
	_gen_status = Label.new()
	_gen_status.text = "🪄✨"
	_gen_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gen_status.add_theme_font_size_override("font_size", 110)
	box.add_child(_gen_status)

	_gen_img = TextureRect.new()
	_gen_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_gen_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_gen_img.custom_minimum_size = Vector2(300.0, 300.0)
	_gen_img.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_gen_img.visible = false
	box.add_child(_gen_img)

	_gen_confirm = HBoxContainer.new()
	(_gen_confirm as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	(_gen_confirm as HBoxContainer).add_theme_constant_override("separation", 40)
	_gen_confirm.visible = false
	for spec in [["✓", Color(0.45, 0.8, 0.45), true], ["↻", Color(0.95, 0.75, 0.4), false]]:
		var b := Button.new()
		b.text = String(spec[0])
		b.custom_minimum_size = Vector2(130.0, 110.0)
		b.add_theme_font_size_override("font_size", 64)
		var s := StyleBoxFlat.new()
		s.bg_color = spec[1]
		s.set_corner_radius_all(30)
		b.add_theme_stylebox_override("normal", s)
		b.add_theme_stylebox_override("hover", s)
		b.add_theme_stylebox_override("pressed", s)
		b.pressed.connect(_on_gen_confirm.bind(bool(spec[2])))
		(_gen_confirm as HBoxContainer).add_child(b)
	box.add_child(_gen_confirm)
	_gen_confirm.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_generate_avatar()

## 答案 → 形象描述（风格后缀由服务端生图管线统一拼接）。
func _avatar_description() -> String:
	var who := "小男孩" if String(answers.get("gender", "")) == "boy" else "小女孩"
	return "一个可爱的%s形象，穿着%s的衣服，抱着一只%s玩偶，一看就很喜欢%s" % [
		who, String(answers.get("color", "彩色")),
		String(answers.get("likes", "小兔子")), String(answers.get("interest", "玩耍"))]

## 预取：进 intro 页就开始生图（结果落 _prefetch_*，generate 页直接用）。
func _start_avatar_prefetch() -> void:
	if _prefetch_state != "":
		return
	_prefetch_state = "pending"
	var res := await api.post_json("/player-sprite", { "visualDescription": _avatar_description() })
	var hash := String(res.get("spriteAsset", ""))
	if hash.is_empty():
		_prefetch_state = "failed"
		return
	var tex := await api.fetch_texture(hash)
	if tex == null:
		_prefetch_state = "failed"
		return
	_prefetch_hash = hash
	_prefetch_tex = tex
	_prefetch_state = "done"

func _generate_avatar() -> void:
	_gen_confirm.visible = false
	_gen_img.visible = false
	_gen_status.text = "🪄✨"
	_start_avatar_prefetch()
	while _prefetch_state == "pending" or _flipping:
		await get_tree().process_frame
	if not is_inside_tree() or _page == null:
		return # 场景已切走（跳过）
	if _prefetch_state != "done":
		_next_page()
		return
	_gen_status.text = "✨"
	_gen_img.texture = _prefetch_tex
	_gen_img.visible = true
	_play("ob_confirm")
	_gen_confirm.visible = true

func _on_gen_confirm(yes: bool) -> void:
	if yes:
		answers["sprite_asset"] = _prefetch_hash
		_next_page()
		return
	_play("ob_regen")
	_prefetch_state = "" # 再变一次：重新生成
	_generate_avatar()

# ── 旁白与推进 ────────────────────────────────────────────────────────────

func _on_page_shown(p: Dictionary) -> void:
	var dur := _play(String(p.get("voice", "")))
	if String(p["kind"]) == "story":
		_story_auto_t = maxf(dur, 0.5) + 1.2 # 旁白讲完停 1.2s 自动翻页
	elif String(p["kind"]) == "intro":
		_start_avatar_prefetch() # 答案已齐：说话确认的同时后台生形象（生图 ~1min 重叠掉）

func _process(delta: float) -> void:
	if _intro_recording:
		_drain_intro() # 录音时持续排空采集缓冲（端侧喂插件/服务端攒整段）
	if _story_auto_t > 0.0 and not _flipping:
		_story_auto_t -= delta
		if _story_auto_t <= 0.0 and page_idx >= 0 and String(PAGES[page_idx]["kind"]) == "story":
			_next_page()

## 播预制旁白，返回音频时长（缺文件返回 0，静默继续——音频由 P4 批量生成）。
func _play(id: String) -> float:
	if id.is_empty():
		return 0.0
	if not ResourceLoader.exists("%s/%s.wav" % [VOICE_DIR, id]):
		return 0.0
	var stream: AudioStream = load("%s/%s.wav" % [VOICE_DIR, id])
	if stream == null:
		return 0.0
	_voice.stop()
	_voice.stream = stream
	_voice.play()
	return stream.get_length()

var _finishing := false

func _finish() -> void:
	if _finishing:
		return
	_finishing = true
	var profile := PlayerProfile.load_profile()
	for k in answers:
		profile[k] = answers[k]
	profile["created_at"] = Time.get_datetime_string_from_system()
	PlayerProfile.save_profile(profile)
	# 收尾欢呼后翻进世界
	var dur := _play("ob_done")
	if dur > 0.0:
		await get_tree().create_timer(dur + 0.3).timeout
	get_tree().change_scene_to_file("res://main.tscn")
