extends Control
## 童话书 onboarding：真 3D 卡纸故事书（PaperBook）翻页讲故事 + 图标问题 + 自我介绍 + 形象生成。
## 面向 3 岁小朋友：不依赖文字——大图标演出 + 预制 TTS 旁白（assets/voice/onboarding/）。
## 页面由 PAGES 声明式驱动；answers 收集到 PlayerProfile。
## kind: story(讲故事,点击/旁白结束后翻页) | question(图标选项) | intro(ASR 自我介绍,P5)
##       | generate(形象生成确认,P6)
##
## 呈现层（2026-07 重做）：根仍是 Control（全屏输入捕获），3D 节点挂主视口 World3D——
## 合书开场 → 翻开封面（连同左半摞页）→ 每步真实翻页（PaperBook 弯曲页面/页堆/沟槽凹陷）。
## 页面 Control 树按原设计尺寸(1040×600)建，塞进跨页 SubViewport 后整体 ×1.5 填满
## （输入换算由 Control.scale 自动处理）；点击走射线拾取→UV→push_input（PaperPhone 同款）。
##
## intro 页是开放麦：旁白问完自动开麦，交给 VoiceCapture 模块（mic+VAD+端侧/服务端ASR+
## 自听防护+BGM门控，与 world.gd 共用同一编排），onboarding 只接信号做状态图标与名字提交。
## 话筒图标只做状态指示，不可点。端侧模型未就绪时不开麦（没有服务端识别可回落）。

const VOICE_DIR := "res://assets/voice/onboarding"
const WAVE_BARS := 5              ## 声波条数量
const WAVE_MIN_H := 12.0          ## 声波条静息高度
const WAVE_MAX_H := 76.0          ## 声波条满幅高度

# ── 3D 舞台参数 ──
const SPREAD_PX := Vector2i(1560, 900)   ## 跨页视口分辨率（=页面设计尺寸 1040×600 ×1.5）
const PAGE_DESIGN := Vector2(1040, 600)  ## 页面 Control 树设计尺寸（沿用旧版，零改版式）
const CAM_FOV := 40.0
const CAM_DIST := 1.6                    ## 书离相机距离
const BOOK_FILL := 0.80                  ## 跨页宽占屏比
const BOOK_NDC := Vector2(0.0, -0.03)    ## 书中心落点（NDC）
## 摊在桌上的阅读俯角:顶边绕横轴向里翻(远)、底边向外翻(近)——正常人看桌上
## 书本的透视,近大远小、底边宽顶边窄(老板两轮校准:先"要正对别侧摆"再
## "上侧往里翻";最初正角度=书顶朝相机像立在展架上,是反的)。
const BOOK_TILT := Vector3(-0.52, 0.0, 0.0)
const TURN_TIME := 0.55                  ## 翻一页时长
const OPEN_TIME := 1.1                   ## 翻开封面时长
const CLOSED_BEAT := 0.8                 ## 开场合书停顿

## 问题选项 value 直接入档案；art/icon 为 assets/ui 的 AIGC 素材名（UiAssets，替代 emoji）。
const PAGES := [
	{ "id": "story_1", "kind": "story", "art": "story_forest", "voice": "ob_story_1" },
	{ "id": "story_2", "kind": "story", "art": "story_fairy_glade", "voice": "ob_story_2", "fairy": true },
	{ "id": "story_3", "kind": "story", "art": "story_door", "voice": "ob_story_3" },
	{ "id": "q_gender", "kind": "question", "field": "gender", "voice": "ob_q_gender", "options": [
		{ "icon": "opt_boy", "value": "boy", "voice": "ob_opt_boy" },
		{ "icon": "opt_girl", "value": "girl", "voice": "ob_opt_girl" },
	] },
	{ "id": "q_color", "kind": "question", "field": "color", "voice": "ob_q_color", "options": [
		{ "icon": "", "value": "红色", "voice": "ob_opt_red", "color": Color(0.94, 0.35, 0.35) },
		{ "icon": "", "value": "蓝色", "voice": "ob_opt_blue", "color": Color(0.35, 0.55, 0.94) },
		{ "icon": "", "value": "黄色", "voice": "ob_opt_yellow", "color": Color(0.98, 0.83, 0.3) },
		{ "icon": "", "value": "绿色", "voice": "ob_opt_green", "color": Color(0.42, 0.82, 0.45) },
	] },
	{ "id": "q_likes", "kind": "question", "field": "likes", "voice": "ob_q_likes", "options": [
		{ "icon": "opt_rabbit", "value": "小兔子", "voice": "ob_opt_rabbit" },
		{ "icon": "opt_cat", "value": "小猫", "voice": "ob_opt_cat" },
		{ "icon": "opt_dog", "value": "小狗", "voice": "ob_opt_dog" },
		{ "icon": "opt_dino", "value": "小恐龙", "voice": "ob_opt_dino" },
	] },
	{ "id": "q_interest", "kind": "question", "field": "interest", "voice": "ob_q_interest", "options": [
		{ "icon": "opt_paint", "value": "画画", "voice": "ob_opt_draw" },
		{ "icon": "opt_ball", "value": "踢球", "voice": "ob_opt_ball" },
		{ "icon": "opt_music", "value": "唱歌", "voice": "ob_opt_sing" },
		{ "icon": "opt_book", "value": "听故事", "voice": "ob_opt_story" },
	] },
	{ "id": "intro", "kind": "intro", "voice": "ob_intro_ask" },
	{ "id": "generate", "kind": "generate", "voice": "ob_generating" },
]

var answers: Dictionary = {}
var page_idx := -1
var _page: Control = null          ## 当前页容器（翻页时旧页被收走）
var _book: PaperBook               ## 3D 卡纸故事书载体
var _cam: Camera3D
var _page_root: Control            ## 跨页视口里的页面容器（1040×600 设计系，×1.5 填满视口）
var _voice: AudioStreamPlayer
var game_audio: GameAudio
var _flipping := false
var _story_auto_t := 0.0           ## story 页自动翻页倒计时（旁白结束后）

# 自我介绍（intro 页）：开放麦 + VAD 断句 → 转写 → 名字确认，多轮重问
const INTRO_MAX_TRIES := 3         ## 重问上限；仍没听到就先叫「小朋友」，进游戏后还能改
var api: Api
var _vc: VoiceCapture              ## 开放麦编排（mic+VAD+端侧/服务端ASR+自听防护+BGM门控），见 voice_capture.gd
var _intro_tries := 0
var _intro_status: TextureRect = null ## 录音状态演出（ic_mic/ic_mic_rec/ic_wait/em_happy）
var _intro_confirm: Control = null ## ✓/✗ 确认行（服务端念完「你叫X对不对呀」后出现）
var _pending := {}                 ## 待确认 {name, nickname, transcript}
var _intro_submitting := false     ## 已提交、等识别/确认：不再开麦
var _intro_wave: Control = null    ## 声波条（随 VAD 电平起伏）

# 形象生成（generate 页）：intro 页起预取，✓采用 / ↻重生成
var _gen_status: TextureRect = null
var _gen_img: TextureRect = null
var _gen_confirm: Control = null
var _prefetch_state := ""          ## "" | pending | done | failed
var _prefetch_hash := ""
var _prefetch_tex: Texture2D = null
var _prefetch_anchors: Dictionary = {}  ## /player-sprite 返回体带的贴纸锚点（headTop/handL/handR），随档案落盘

func _ready() -> void:
	_setup_stage3d()
	_voice = AudioStreamPlayer.new()
	add_child(_voice)
	game_audio = GameAudio.new()
	game_audio.name = "GameAudio"
	add_child(game_audio)
	game_audio.start_bgm([GameAudio.BGM_STEPS[0]]) # 旁白为主，音乐只垫底
	api = Api.new()
	api.name = "Api"
	add_child(api)
	_vc = VoiceCapture.new()
	_vc.name = "VoiceCapture"
	_vc.game_audio = game_audio
	# 名字页【不】进确认模式（即便手机设置里开了）：这里本来就有一层更直接的确认——
	# 服务端念出识别到的名字「你叫XX，对不对呀」，孩子点 ✓/✗。再叠一层回放录音只会更啰嗦。
	# 确认模式只服务 world 的开放式对话（那里没有任何复述，孩子无从判断自己说清没有）。
	# 开麦门禁：旁白播放期间不喂（半双工防自听），其余交给 VAD。BGM 让位判据=旁白在播。
	_vc.should_capture = func() -> bool: return not _voice.playing
	_vc.is_speaking = func() -> bool: return _voice.playing
	_vc.utterance_begin.connect(_on_capture_begin)
	_vc.committed.connect(_on_capture_committed)
	_vc.local_final.connect(_on_capture_local_final)
	_vc.cancelled.connect(_on_capture_cancelled)
	_vc.asr_ready.connect(_on_capture_ready)
	add_child(_vc)
	_next_page()

func _exit_tree() -> void:
	# 场景切走：关麦。VoiceCapture 自身 _exit_tree 断开端侧插件信号。
	if _vc != null:
		_vc.close()

# ── VoiceCapture 信号回调（onboarding 侧的业务：状态图标 + 名字提交）─────────────

## 端侧模型就绪：图标从「稍等」回到「在听」。
func _on_capture_ready() -> void:
	if _intro_status != null and not _vc.is_recording():
		_intro_status.texture = UiAssets.tex("ic_mic")

## 开口：亮录音图标。
func _on_capture_begin() -> void:
	if _intro_status != null:
		_intro_status.texture = UiAssets.tex("ic_mic_rec")

## 说完：一次性采集，关麦 + 图标转「处理中」，等端侧识别出文本（local_final）。
func _on_capture_committed() -> void:
	_intro_submitting = true
	_vc.close()
	if _intro_status != null:
		_intro_status.texture = UiAssets.tex("ic_wait")

## 端侧识别出最终文本：提交为名字（空文本 → _submit_intro 内部重问）。
func _on_capture_local_final(text: String) -> void:
	_submit_intro(text.strip_edges())

## 误触（说太短）：图标回「在听」，麦克风继续开着（VoiceCapture 内部保持聆听）。
func _on_capture_cancelled() -> void:
	if _intro_status != null:
		_intro_status.texture = UiAssets.tex("ic_mic")

## 3D 舞台：相机 + 暖光 + 摊在木桌上的卡纸故事书（合书开场）。根是 Control，
## 3D 节点挂进主视口的 World3D（2D 画布叠在 3D 之上，本 Control 不画东西只收输入）。
func _setup_stage3d() -> void:
	_cam = Camera3D.new()
	_cam.name = "StageCam"
	_cam.fov = CAM_FOV
	add_child(_cam)
	_cam.make_current()
	# 暖平行光（左上前方）+ 环境光：纸艺观感的第一根支柱是真实光照下的素色材质。
	# 不开实时阴影（老平板 GPU 陷阱），接触阴影用假影贴图（PaperBook.create_desk）。
	var sun := DirectionalLight3D.new()
	sun.name = "WarmSun"
	sun.rotation = Vector3(-0.95, -0.35, 0.0)
	sun.light_color = Color(1.0, 0.965, 0.90)
	sun.light_energy = 1.05
	sun.shadow_enabled = false
	add_child(sun)
	var env := WorldEnvironment.new()
	env.name = "StageEnv"
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.93, 0.87, 0.78) # 桌面外兜底暖色（正常被木桌盖满）
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.86, 0.82, 0.78)
	e.ambient_light_energy = 0.75
	env.environment = e
	add_child(env)
	# 书：合书姿态趴在木桌上入场，翻开封面见 _next_page 首页特例
	_book = PaperBook.new()
	_book.name = "PaperBook"
	add_child(_book)
	_book.rotation = BOOK_TILT
	_book.set_open_frac(0.0)
	_book.set_cover_texture(UiAssets.tex("book_cover"))
	_book.create_desk(UiAssets.tex("desk_wood"))
	_book.create_spread(SPREAD_PX)
	# 跨页视口内容：纸面底色 + 页面容器（1040×600 设计系整体 ×1.5 = 1560×900 恰满幅）
	var paper := ColorRect.new()
	paper.color = Color(0.985, 0.972, 0.938) # 白卡纸
	paper.size = Vector2(SPREAD_PX)
	_book.spread_viewport().add_child(paper)
	_page_root = Control.new()
	_page_root.name = "PageRoot"
	_page_root.size = PAGE_DESIGN
	_page_root.scale = Vector2(SPREAD_PX) / PAGE_DESIGN
	_book.spread_viewport().add_child(_page_root)
	_fit_stage()
	get_viewport().size_changed.connect(_fit_stage)

## 书（连同木桌）贴合相机视野（进场与窗口变化时）。
func _fit_stage() -> void:
	_book.fit_to_camera(_cam, BOOK_FILL, BOOK_NDC, CAM_DIST)

## 全屏输入：射线拾取 → 转发进跨页视口（命中书页时吞掉事件）。
func _gui_input(ev: InputEvent) -> void:
	if _book != null and _book.route_gui_event(_cam, ev):
		accept_event()

# ── 翻页与页面渲染 ─────────────────────────────────────────────────────────

func _next_page() -> void:
	if _flipping:
		return
	if page_idx + 1 >= PAGES.size():
		_finish()
		return
	page_idx += 1
	_show_page(_build_page(PAGES[page_idx]))

## 展示新页：首页=合书停一拍→翻开封面；其后=真实翻页（旧页快照卷过书脊）。
func _show_page(next_page: Control) -> void:
	_flipping = true
	var old := _page
	_page = next_page
	var swap := func() -> void:
		if old != null:
			old.queue_free()
		_page_root.add_child(next_page)
	if page_idx == 0:
		swap.call()
		await get_tree().create_timer(CLOSED_BEAT).timeout
		game_audio.play_sfx("page")
		await _book.play_open(OPEN_TIME)
	else:
		game_audio.play_sfx("page")
		var prog := float(page_idx) / float(maxi(PAGES.size() - 1, 1))
		await _book.turn_page(swap, prog, TURN_TIME)
	_flipping = false
	_on_page_shown(PAGES[page_idx])

## 页面根是 plain Control（不接管子节点定位）：story 的全出血插画直接铺满页根，
## 交互内容走居中 VBox 叠层——两者互不打架。
func _build_page(p: Dictionary) -> Control:
	var page := Control.new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	if String(p["kind"]) == "story":
		_build_story(page, p)
		return page
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 30)
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.add_child(box)
	match String(p["kind"]):
		"question": _build_question(box, p)
		"intro": _build_intro(box, p)
		"generate": _build_generate(box, p)
	return page

func _build_story(page: Control, p: Dictionary) -> void:
	# 绘本插画全出血铺满跨页（书脊沟槽的凹陷变形直接压过画面）；
	# fairy 页在插画光斑中央叠小仙子立绘；▶ 悬浮在页脚。
	var art := TextureRect.new()
	art.texture = UiAssets.tex(String(p.get("art", "story_forest")))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.clip_contents = true
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.add_child(art)
	if p.get("fairy", false):
		var img := TextureRect.new()
		img.texture = load("res://assets/fairy.png")
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.set_anchors_preset(Control.PRESET_CENTER)
		img.offset_left = -140.0
		img.offset_right = 140.0
		img.offset_top = -96.0
		img.offset_bottom = 96.0
		art.add_child(img)
	var hint := UiAssets.icon_button("ic_next", 72.0)
	hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint.offset_left = -36.0
	hint.offset_right = 36.0
	hint.offset_top = -88.0
	hint.offset_bottom = -16.0
	hint.pressed.connect(_next_page)
	page.add_child(hint)

func _build_question(box: VBoxContainer, p: Dictionary) -> void:
	var q := UiAssets.icon_rect("ic_question", 88.0)
	box.add_child(q)
	# 选项拆成左右页两组、中间空出书脊沟槽——真书不会把内容印进装订沟
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 36)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var opts := p["options"] as Array
	var half := ceili(opts.size() / 2.0)
	for i in opts.size():
		if i == half:
			var gutter := Control.new()
			gutter.custom_minimum_size = Vector2(110.0, 0.0) # 与 separation×2 合计≈180px 避开沟槽
			row.add_child(gutter)
		row.add_child(_option_button(p, opts[i] as Dictionary))
	box.add_child(row)

## 图标大按钮：AIGC 贴纸图标 或 纯色圆角块（颜色题用色块，天然不依赖图片）。
func _option_button(p: Dictionary, opt: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(170.0, 170.0)
	var icon_name := String(opt.get("icon", ""))
	if not icon_name.is_empty():
		b.icon = UiAssets.tex(icon_name)
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = opt.get("color", Color(0.96, 0.93, 0.85))
	style.set_corner_radius_all(32)
	style.set_content_margin_all(14.0)
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
	game_audio.play_sfx("select")
	_play(String(opt.get("voice", "")))
	# 选中反馈：弹一下再翻页
	btn.pivot_offset = btn.size * 0.5
	var tw := create_tween()
	tw.tween_property(btn, "scale", Vector2(1.18, 1.18), 0.12)
	tw.tween_property(btn, "scale", Vector2.ONE, 0.12)
	tw.tween_interval(0.5)
	tw.tween_callback(_next_page)

## ASR 自我介绍：旁白问完自动开麦 → VAD 断句 → 转写 → 提取名字 → TTS 复述确认（✓/✗），多轮重问。
## 话筒是纯状态指示器（不可点）：ic_mic=在听 / ic_mic_rec=听到你说话 / ic_wait=处理中。
func _build_intro(box: VBoxContainer, _p: Dictionary) -> void:
	_intro_tries = 0
	_intro_status = UiAssets.icon_rect("ic_mic", 150.0)
	box.add_child(_intro_status)

	# 声波：共用 VoiceWave 控件（流动波，与 world 收听 HUD 同款），随 VAD 电平起伏，让 3 岁
	# 小朋友看出「我在听」。开麦时才流动（旁白时落回静息，见 _process 里 active 门控）。
	var vw := VoiceWave.new()
	vw.bar_count = WAVE_BARS
	vw.bar_width = 16.0
	vw.bar_gap = 10.0
	vw.bar_min_h = WAVE_MIN_H
	vw.bar_max_h = WAVE_MAX_H
	vw.bar_color = Color(0.95, 0.55, 0.45)
	vw.gain = 6.0  # 沿用旧灵敏度（lvl*6）：小龄近场电平偏小，放大才够跳
	vw.level_source = func() -> float: return _vc.level() if _vc != null else 0.0
	vw.custom_minimum_size = Vector2(0.0, WAVE_MAX_H)  # VBox 给足高度，柱底对齐控件底
	vw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_intro_wave = vw
	box.add_child(_intro_wave)

	# 名字确认行：听完「你叫X对不对呀」后点 ✓/✗（初始隐藏）
	_intro_confirm = HBoxContainer.new()
	(_intro_confirm as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	(_intro_confirm as HBoxContainer).add_theme_constant_override("separation", 40)
	_intro_confirm.visible = false
	for spec in [["ic_yes", true], ["ic_no", false]]:
		var b := UiAssets.icon_button(String(spec[0]), 116.0)
		b.pressed.connect(_on_intro_confirm.bind(bool(spec[1])))
		(_intro_confirm as HBoxContainer).add_child(b)
	box.add_child(_intro_confirm)
	_intro_confirm.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

func _is_intro_page() -> bool:
	return page_idx >= 0 and page_idx < PAGES.size() and String(PAGES[page_idx]["kind"]) == "intro"

## 提交自我介绍：端侧转写 → 名字 + 确认音频。
## 端侧识别好的转写 → 服务端提名字/称呼（音频永不上传：服务端已无 ASR）。空转写就地重问。
func _submit_intro(transcript: String) -> void:
	if transcript.is_empty():
		_intro_retry()
		return
	var res := await api.post_json("/onboarding/intro", { "transcript": transcript })
	var name := String(res.get("name", ""))
	if name.is_empty():
		_intro_retry()
		return
	_pending = {
		"name": name,
		"nickname": String(res.get("nickname", name)),
		"transcript": String(res.get("transcript", transcript)),
	}
	_intro_status.texture = UiAssets.tex("em_happy")
	var audio := await api.fetch_audio(String(res.get("confirmTtsAsset", "")))
	_play_pcm(audio["bytes"] as PackedByteArray, int(audio["rate"]))
	_intro_confirm.visible = true

## 没听到名字：重问（预制 retry 音频），到达上限先叫「小朋友」继续，不卡住小朋友。
## 放开 _intro_submitting：retry 旁白播完后 _process 会自动重新 _vc.open()。
func _intro_retry() -> void:
	_intro_tries += 1
	if _intro_tries >= INTRO_MAX_TRIES:
		answers["name"] = ""
		answers["nickname"] = "小朋友"
		_vc.close()
		_next_page()
		return
	_intro_status.texture = UiAssets.tex("ic_mic")
	game_audio.play_sfx("oops")
	_play("ob_intro_retry")
	_intro_submitting = false

func _on_intro_confirm(yes: bool) -> void:
	_intro_confirm.visible = false
	if yes:
		game_audio.play_sfx("confirm")
		answers["name"] = String(_pending.get("name", ""))
		answers["nickname"] = String(_pending.get("nickname", "小朋友"))
		answers["intro"] = String(_pending.get("transcript", ""))
		_vc.close()
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
	_gen_status = UiAssets.icon_rect("ic_wand", 150.0)
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
	for spec in [["ic_yes", true], ["ic_retry", false]]:
		var b := UiAssets.icon_button(String(spec[0]), 116.0)
		b.pressed.connect(_on_gen_confirm.bind(bool(spec[1])))
		(_gen_confirm as HBoxContainer).add_child(b)
	box.add_child(_gen_confirm)
	_gen_confirm.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_generate_avatar()

## 答案 → 形象描述（公用逻辑在 PlayerProfile.avatar_description，设置页「换形象」同款）。
func _avatar_description() -> String:
	return PlayerProfile.avatar_description(answers)

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
	var anch: Variant = res.get("anchors")
	_prefetch_anchors = anch if typeof(anch) == TYPE_DICTIONARY else {}
	_prefetch_hash = hash
	_prefetch_tex = tex
	_prefetch_state = "done"

func _generate_avatar() -> void:
	_gen_confirm.visible = false
	_gen_img.visible = false
	_gen_status.texture = UiAssets.tex("ic_wand")
	_start_avatar_prefetch()
	while _prefetch_state == "pending" or _flipping:
		await get_tree().process_frame
	if not is_inside_tree() or _page == null:
		return # 场景已切走（跳过）
	if _prefetch_state != "done":
		_next_page()
		return
	_gen_status.texture = UiAssets.tex("ic_sparkle")
	_gen_img.texture = _prefetch_tex
	_gen_img.visible = true
	game_audio.play_sfx("reveal")
	_play("ob_confirm")
	_gen_confirm.visible = true

func _on_gen_confirm(yes: bool) -> void:
	if yes:
		game_audio.play_sfx("confirm")
		answers["sprite_asset"] = _prefetch_hash
		answers["anchors"] = _prefetch_anchors # 与 sprite_asset 成对落档，_apply_player_sprite 灌进玩家节点
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
	# （无悬浮微摆：书是摊在桌上的实体,晃动反而破坏"躺在桌面"的落地感）
	# duck（音量微降）留宿主：旁白在播 或 正在录音时压低，给人声让路。
	# BGM 静音（比 duck 更狠，断外放回灌）由 VoiceCapture 内部门控——聆听窗一开即静音，
	# 只在旁白/人声出声时放行（修正旧口径只在 recording 才静音、漏掉开麦等待窗的问题）。
	game_audio.set_ducked(_voice.playing or _vc.is_recording())
	# intro 页旁白说完 → 自动开麦（Android 端侧未就绪则不开、绝不上传）；VoiceCapture 内部
	# VAD 判开口/说完、自听防护、分片、端侧/服务端路由。step 每帧驱动（含 BGM 静音门控）。
	if _is_intro_page() and not _intro_submitting and not _voice.playing and not _vc.must_wait_for_ready():
		_vc.open()
	_vc.step(delta)
	# 声波只在聆听窗（麦开着）流动；旁白/等待时落回静息，别假装在听。
	if _intro_wave is VoiceWave:
		(_intro_wave as VoiceWave).active = _vc.is_open()
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
	_vc.close() # 收尾时可能正开着麦（名字页）：关掉,别留悬空会话
	var profile := PlayerProfile.load_profile()
	for k in answers:
		profile[k] = answers[k]
	profile["created_at"] = Time.get_datetime_string_from_system()
	PlayerProfile.save_profile(profile)
	# 收尾欢呼后翻进世界。首次进世界必走「建造小世界」intro（教学+建造+可能的定档段）——
	# 刚写完档案但 intro_seen 仍 false，should_run 必真。
	IntroDirector.pending = IntroDirector.should_run()
	var dur := _play("ob_done")
	if dur > 0.0:
		await get_tree().create_timer(dur + 0.3).timeout
	Loading.next_scene = "res://main.tscn"
	get_tree().change_scene_to_file("res://loading.tscn")
