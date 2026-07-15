extends Control
## 童话书 onboarding：真 3D 卡纸故事书（PaperBook）翻页讲故事 + 自我介绍 + 点点引导式形象创作
## + 照镜子改一改（docs/onboarding-avatar-redesign-design.md）。
## 面向 3 岁小朋友：不依赖文字——大图标演出 + 预制 TTS 旁白（assets/voice/onboarding/）
## + 动态问题用 edge-tts 现念（点点音色）。
## 页面由 PAGES 声明式驱动；answers 收集到 PlayerProfile。
## kind: story(讲故事,点击/旁白结束后翻页) | intro(ASR 自我介绍,已前移——后面点点能喊名字)
##       | avatar_chat(点点引导多轮对话:图标卡+开放语音,服务端 /onboarding/avatar-chat)
##       | generate(形象生成+照镜子改一改:说想改哪→增量重生成,≤2 次必收尾)
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

## art/icon 为 assets/ui 的 AIGC 素材名（UiAssets，替代 emoji）。
## 名字页（intro）前移到形象对话前：后面点点才能喊着「朵朵」引导——个性化的地基。
const PAGES := [
	{ "id": "story_1", "kind": "story", "art": "story_forest", "voice": "ob_story_1" },
	{ "id": "story_2", "kind": "story", "art": "story_fairy_glade", "voice": "ob_story_2", "fairy": true },
	{ "id": "story_3", "kind": "story", "art": "story_door", "voice": "ob_story_3" },
	{ "id": "intro", "kind": "intro", "voice": "ob_intro_ask" },
	{ "id": "avatar_chat", "kind": "avatar_chat", "voice": "" },
	{ "id": "generate", "kind": "generate", "voice": "ob_generating" },
]

## 离线降级题序（docs/onboarding-avatar-redesign-design.md §3.3）：/onboarding/avatar-chat 不可达时
## 本地出静态三题（复用打包图标与预制旁白），答案进 avatar_attrs、本地拼简化描述——绝不卡小朋友。
## likes 一栏转译为衣服图案（motif）：治「抱着玩偶」病灶，离线路径同样双手空着。
const FB_QUESTIONS := [
	{ "attr": "gender", "voice": "ob_q_gender", "options": [
		{ "icon": "opt_boy", "value": "小男生", "legacy": "boy", "voice": "ob_opt_boy" },
		{ "icon": "opt_girl", "value": "小女生", "legacy": "girl", "voice": "ob_opt_girl" },
	] },
	{ "attr": "color", "voice": "ob_q_color", "options": [
		{ "icon": "", "value": "红色", "voice": "ob_opt_red", "color": Color(0.94, 0.35, 0.35) },
		{ "icon": "", "value": "蓝色", "voice": "ob_opt_blue", "color": Color(0.35, 0.55, 0.94) },
		{ "icon": "", "value": "黄色", "voice": "ob_opt_yellow", "color": Color(0.98, 0.83, 0.3) },
		{ "icon": "", "value": "绿色", "voice": "ob_opt_green", "color": Color(0.42, 0.82, 0.45) },
	] },
	{ "attr": "motif", "voice": "ob_q_likes", "options": [
		{ "icon": "opt_rabbit", "value": "小兔子", "voice": "ob_opt_rabbit" },
		{ "icon": "opt_cat", "value": "小猫", "voice": "ob_opt_cat" },
		{ "icon": "opt_dog", "value": "小狗", "voice": "ob_opt_dog" },
		{ "icon": "opt_dino", "value": "小恐龙", "voice": "ob_opt_dino" },
	] },
]

## 形象选项库 color 类的色块（服务端刻意不生成图标，客户端按 label 渲染纯色卡）。
const CHAT_COLOR_SWATCH := {
	"红色": Color(0.94, 0.35, 0.35), "橙色": Color(0.96, 0.6, 0.3), "黄色": Color(0.98, 0.83, 0.3),
	"绿色": Color(0.42, 0.82, 0.45), "蓝色": Color(0.35, 0.55, 0.94), "紫色": Color(0.65, 0.5, 0.9),
	"粉色": Color(0.96, 0.6, 0.75), "白色": Color(0.97, 0.96, 0.94),
}

const CHAT_TIMEOUT_SEC := 15.0     ## 对话一轮的超时（done 轮含两次 LLM，宽一点）；超时→离线降级
const REFINE_MAX := 2              ## 照镜子改一改上限：第 2 次改完必收尾（零挫败，A1 同款闸）

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

# 点点引导式形象对话（avatar_chat 页）：服务端无状态多轮，state 原样存原样带回
var _tts: EdgeTts                  ## 动态问题现念（点点音色 zh-CN-YunxiaNeural）；不可用静默跳过
var _chat_state := {}              ## /onboarding/avatar-chat 回带的 state（客户端只存不算）
var _chat_busy := false            ## 一轮在途（请求/念题中）：不开麦、不响应点卡
var _chat_fallback := false        ## 离线降级：本地静态题序（FB_QUESTIONS）
var _chat_fb_idx := 0              ## 降级题序进度
var _chat_fb_attrs := {}           ## 降级收集的属性（与服务端 AvatarAttrs 同键）
var _fb_picking := false           ## 降级选中反馈窗口（0.6s）内旧卡仍在：拦第二次点击防双答
var _chat_cards: HBoxContainer = null
var _chat_status: TextureRect = null
var _chat_wave: Control = null

# 形象生成（generate 页）：对话 done 起预取；照镜子改一改（说想改哪→增量重生成，≤2 次必收尾）
var _gen_status: TextureRect = null
var _gen_img: TextureRect = null
var _gen_confirm: Control = null
var _gen_wave: Control = null
var _refine_ready := false         ## 图已亮相，可以听「想改哪里」
var _refine_busy := false          ## refine 在途：不开麦
var _refine_count := 0
var _refine_notes: Array = []      ## 孩子提的修改原话（随档案上报，个性化金矿）
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
	_tts = EdgeTts.new()
	_tts.name = "EdgeTts"
	add_child(_tts)
	if OS.get_environment("MALIANG_EDGE_TTS") != "0": # 回测隔离开关（与 world 同款约定）
		_tts.probe() # 异步探活：对话页动态问题现念要用；不通则静默只出卡
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

# ── VoiceCapture 信号回调（onboarding 侧的业务：状态图标 + 按页路由提交）─────────────
# 三个开麦页共用一套编排：intro=名字、avatar_chat=开放语音答题、generate=照镜子说想改哪。

## 当前页的话筒状态图标（哪页开麦就亮哪页的）。
func _status_icon() -> TextureRect:
	match _page_kind():
		"intro": return _intro_status
		"avatar_chat": return _chat_status
		"generate": return _gen_status
	return null

func _page_kind() -> String:
	if page_idx >= 0 and page_idx < PAGES.size():
		return String(PAGES[page_idx]["kind"])
	return ""

## 端侧模型就绪：图标从「稍等」回到「在听」。
func _on_capture_ready() -> void:
	var ic := _status_icon()
	if ic != null and not _vc.is_recording():
		ic.texture = UiAssets.tex("ic_mic")

## 开口：亮录音图标。
func _on_capture_begin() -> void:
	var ic := _status_icon()
	if ic != null:
		ic.texture = UiAssets.tex("ic_mic_rec")

## 说完：一次性采集，关麦 + 图标转「处理中」，等端侧识别出文本（local_final）。
func _on_capture_committed() -> void:
	match _page_kind():
		"intro": _intro_submitting = true
		"avatar_chat": _chat_busy = true
		"generate": _refine_busy = true
	_vc.close()
	var ic := _status_icon()
	if ic != null:
		ic.texture = UiAssets.tex("ic_wait")

## 端侧识别出最终文本：按页路由（名字提交 / 对话一轮 / 照镜子修改）。
func _on_capture_local_final(text: String) -> void:
	match _page_kind():
		"intro": _submit_intro(text.strip_edges())
		"avatar_chat": _chat_submit(text.strip_edges())
		"generate": _refine_submit(text.strip_edges())

## 误触（说太短）：图标回「在听」，麦克风继续开着（VoiceCapture 内部保持聆听）。
func _on_capture_cancelled() -> void:
	var ic := _status_icon()
	if ic != null:
		ic.texture = UiAssets.tex("ic_mic")

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
		"avatar_chat": _build_avatar_chat(box, p)
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

# ── 点点引导式形象对话（avatar_chat 页）────────────────────────────────────────
# 服务端无状态多轮（/onboarding/avatar-chat）：每轮把 state 原样带回，点点动态提问（图标卡 2-4 张）
# + 开放语音（说「我要会发光的头发」不必落在卡上）。服务端不可达 → FB_QUESTIONS 本地静态题序。

func _build_avatar_chat(box: VBoxContainer, _p: Dictionary) -> void:
	_chat_status = UiAssets.icon_rect("ic_question", 110.0)
	box.add_child(_chat_status)
	_chat_cards = HBoxContainer.new()
	_chat_cards.alignment = BoxContainer.ALIGNMENT_CENTER
	_chat_cards.add_theme_constant_override("separation", 36)
	_chat_cards.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(_chat_cards)
	_chat_wave = _make_wave()
	box.add_child(_chat_wave)
	_chat_start()

## 共用声波控件（intro/avatar_chat 同款视觉：随 VAD 电平起伏，让 3 岁小朋友看出「我在听」）。
func _make_wave() -> Control:
	var vw := VoiceWave.new()
	vw.bar_count = WAVE_BARS
	vw.bar_width = 16.0
	vw.bar_gap = 10.0
	vw.bar_min_h = WAVE_MIN_H
	vw.bar_max_h = WAVE_MAX_H
	vw.bar_color = Color(0.95, 0.55, 0.45)
	vw.gain = 6.0  # 小龄近场电平偏小，放大才够跳
	vw.level_source = func() -> float: return _vc.level() if _vc != null else 0.0
	vw.custom_minimum_size = Vector2(0.0, WAVE_MAX_H)
	vw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return vw

## 图标大卡：贴纸图标 / 服务端图标资产 / 纯色块 / 文字兜底（iconAsset 未生成时）。
func _card_button(icon_tex: Texture2D, bg: Color, label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(170.0, 170.0)
	if icon_tex != null:
		b.icon = icon_tex
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	elif not label.is_empty():
		b.text = label
		b.add_theme_font_size_override("font_size", 40)
		b.add_theme_color_override("font_color", Color(0.32, 0.26, 0.2))
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(32)
	style.set_content_margin_all(14.0)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = (style.bg_color as Color).lightened(0.12)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.pressed.connect(func() -> void:
		if _flipping:
			return
		b.pivot_offset = b.size * 0.5
		var tw := create_tween()
		tw.tween_property(b, "scale", Vector2(1.18, 1.18), 0.12)
		tw.tween_property(b, "scale", Vector2.ONE, 0.12)
		cb.call())
	return b

## 卡片行重建：左右页两组、中间空出书脊沟槽（真书不会把内容印进装订沟）。
func _chat_show_cards(cards: Array) -> void:
	for c in _chat_cards.get_children():
		c.queue_free()
	var half := ceili(cards.size() / 2.0)
	for i in cards.size():
		if i == half:
			var gutter := Control.new()
			gutter.custom_minimum_size = Vector2(110.0, 0.0) # 与 separation×2 合计≈180px 避开沟槽
			_chat_cards.add_child(gutter)
		_chat_cards.add_child(cards[i] as Button)

## 开场轮：空输入起对话。服务端不可达 → 本地静态题序（绝不卡小朋友）。
func _chat_start() -> void:
	_chat_busy = true
	var res := await api.post_json("/onboarding/avatar-chat",
		{ "childInput": "", "childName": String(answers.get("nickname", "")) }, CHAT_TIMEOUT_SEC)
	if not is_inside_tree() or _chat_cards == null:
		return
	if res.is_empty():
		_chat_enter_fallback()
		return
	await _chat_apply(res)

## 小朋友一轮输入（点卡的 label 或开放语音的原话）→ 服务端推进一轮。
func _chat_submit(input: String) -> void:
	if input.is_empty():
		_chat_busy = false # 空识别：重新开麦接着听
		return
	_chat_busy = true
	game_audio.play_sfx("select")
	var body: Dictionary = _chat_state.duplicate(true)
	body["childInput"] = input
	var res := await api.post_json("/onboarding/avatar-chat", body, CHAT_TIMEOUT_SEC)
	if not is_inside_tree() or _chat_cards == null:
		return
	if res.is_empty():
		_chat_enter_fallback() # 中途断网：切本地题序接着问（已收集的属性在服务端 state 里，丢弃换本地）
		return
	await _chat_apply(res)

## 应用一轮结果：done → 存描述/属性、起预取、翻页；否则渲染卡片 + 点点念题 → 开麦。
func _chat_apply(res: Dictionary) -> void:
	_chat_state = res.get("state", {}) if typeof(res.get("state")) == TYPE_DICTIONARY else {}
	var reply := String(res.get("replyText", ""))
	if bool(res.get("done", false)):
		answers["visual_description"] = String(res.get("description", ""))
		var attrs: Variant = (_chat_state as Dictionary).get("attrs", {})
		if typeof(attrs) == TYPE_DICTIONARY:
			answers["avatar_attrs"] = attrs
			_apply_legacy_fields(attrs as Dictionary)
		_chat_show_cards([])
		if _chat_status != null:
			_chat_status.texture = UiAssets.tex("ic_sparkle")
		_start_avatar_prefetch() # 描述已定：翻页/旁白期间就开始生图
		await _say(reply)
		_next_page()
		return
	var options: Array = res.get("options", []) if typeof(res.get("options")) == TYPE_ARRAY else []
	var category := String(res.get("category", ""))
	var cards: Array = []
	for o in options:
		var od := o as Dictionary
		var label := String(od.get("label", ""))
		cards.append(await _chat_option_card(label, String(od.get("iconAsset", "")), category))
	_chat_show_cards(cards)
	if _chat_status != null:
		_chat_status.texture = UiAssets.tex("ic_question")
	await _say(String(res.get("question", reply)))
	_chat_busy = false # 念完题开麦（_process 驱动）；点卡与说话都收

## 一张对话选项卡：服务端图标资产 > 色块（color 类）> 文字兜底。点卡 = 用 label 当这轮输入。
func _chat_option_card(label: String, icon_asset: String, category: String) -> Button:
	var tex: Texture2D = null
	if not icon_asset.is_empty():
		tex = await api.fetch_texture(icon_asset)
	var bg: Color = Color(0.96, 0.93, 0.85)
	if category == "color" and CHAT_COLOR_SWATCH.has(label):
		bg = CHAT_COLOR_SWATCH[label]
		return _card_button(null, bg, "", func() -> void: _chat_submit(label))
	if tex == null:
		return _card_button(null, bg, label, func() -> void: _chat_submit(label))
	return _card_button(tex, bg, label, func() -> void: _chat_submit(label))

## 点点音色现念动态文本（edge-tts；不可用/失败静默跳过——卡片仍在，交互不断）。
## 返回后音频在播（_voice.playing 门控闭麦），播完 _process 自然开麦。
func _say(text: String) -> void:
	if text.strip_edges().is_empty() or _tts == null or not _tts.available:
		return
	var mp3: PackedByteArray = await _tts.synthesize(text, "zh-CN-YunxiaNeural")
	if mp3.is_empty() or not is_inside_tree():
		return
	var stream := AudioStreamMP3.new()
	stream.data = mp3
	_voice.stop()
	_voice.stream = stream
	_voice.play()

# ── 离线降级题序（本地三题，复用打包图标与预制旁白）──────────────────────────

func _chat_enter_fallback() -> void:
	_chat_fallback = true
	_chat_fb_idx = 0
	_chat_fb_attrs = { "motifs": [], "extras": [] }
	_chat_fb_show()

func _chat_fb_show() -> void:
	if _chat_fb_idx >= FB_QUESTIONS.size():
		_chat_fb_done()
		return
	var q := FB_QUESTIONS[_chat_fb_idx] as Dictionary
	var cards: Array = []
	for o in (q["options"] as Array):
		var od := o as Dictionary
		var icon_name := String(od.get("icon", ""))
		var tex: Texture2D = UiAssets.tex(icon_name) if not icon_name.is_empty() else null
		var bg: Color = od.get("color", Color(0.96, 0.93, 0.85))
		cards.append(_card_button(tex, bg, "", func() -> void: _chat_fb_pick(q, od)))
	_chat_show_cards(cards)
	if _chat_status != null:
		_chat_status.texture = UiAssets.tex("ic_question")
	_play(String(q.get("voice", "")))
	_chat_busy = true # 降级路径纯点选：不开麦（离线无从識别归一，语音留给在线路径）

func _chat_fb_pick(q: Dictionary, opt: Dictionary) -> void:
	if _fb_picking:
		return # 反馈窗口内旧卡仍可见可点：拦第二次点击，防一题双答/双推进
	_fb_picking = true
	game_audio.play_sfx("select")
	_play(String(opt.get("voice", "")))
	var attr := String(q["attr"])
	if attr == "motif":
		(_chat_fb_attrs["motifs"] as Array).append(String(opt["value"]))
	else:
		_chat_fb_attrs[attr] = String(opt["value"])
	if opt.has("legacy"):
		answers["gender"] = String(opt["legacy"]) # 音色映射等旧口径仍用 boy/girl
	_chat_fb_idx += 1
	await get_tree().create_timer(0.6).timeout # 让选中音效/反馈过一拍
	_fb_picking = false
	if is_inside_tree() and _chat_cards != null:
		_chat_fb_show()

## 降级收尾：本地拼简化描述（镜像服务端 composeAvatarDesc 的硬规则——双手空着、图案上衣）。
func _chat_fb_done() -> void:
	answers["avatar_attrs"] = _chat_fb_attrs
	_apply_legacy_fields(_chat_fb_attrs)
	var who := "小朋友"
	match String(_chat_fb_attrs.get("gender", "")):
		"小男生": who = "小男孩"
		"小女生": who = "小女孩"
	var color := String(_chat_fb_attrs.get("color", ""))
	var motifs := _chat_fb_attrs.get("motifs", []) as Array
	var desc := "一个可爱的%s，穿着%s舒服的衣服" % [who, (color + "的") if not color.is_empty() else ""]
	if motifs.size() > 0:
		desc += "，衣服上印着%s图案" % "和".join(PackedStringArray(motifs))
	desc += "，双手空空的自然垂在身边，没有拿任何东西"
	answers["visual_description"] = desc
	_chat_show_cards([])
	_start_avatar_prefetch()
	_next_page()

## 从形象属性回填旧档案口径字段（gender=boy/girl 供音色映射/presence；color 供旧模板兜底）。
func _apply_legacy_fields(attrs: Dictionary) -> void:
	match String(attrs.get("gender", "")):
		"小男生": answers["gender"] = "boy"
		"小女生": answers["gender"] = "girl"
	var color := String(attrs.get("color", ""))
	if not color.is_empty():
		answers["color"] = color

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

## 形象生成 + 照镜子·改一改：对话 done 起预取（生图与翻页/念题时间重叠）→ 亮相 →
## 「有没有哪里想变一变？」孩子说想改哪（开放麦）→ /player-sprite refine 增量重生成，
## ≤REFINE_MAX 次必收尾（第 2 次改完直接欢呼采纳）；点 ✓ 随时「就是我！」直接出发。
## 替代旧 ↻ 盲重掷——「我说得越清楚，改出来越像我想的」正是要教的那一拍（A1 试→改）。
## 离线/失败直接放行（占位形象进世界，不卡小朋友）。
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

	_gen_wave = _make_wave()
	box.add_child(_gen_wave)

	_gen_confirm = HBoxContainer.new()
	(_gen_confirm as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	(_gen_confirm as HBoxContainer).add_theme_constant_override("separation", 40)
	_gen_confirm.visible = false
	var yes := UiAssets.icon_button("ic_yes", 116.0)
	yes.pressed.connect(_on_gen_accept)
	(_gen_confirm as HBoxContainer).add_child(yes)
	box.add_child(_gen_confirm)
	_gen_confirm.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_generate_avatar()

## 预取：形象对话 done（描述已定）就开始生图（结果落 _prefetch_*，generate 页直接用）。
func _start_avatar_prefetch() -> void:
	if _prefetch_state != "":
		return
	_prefetch_state = "pending"
	var desc := String(answers.get("visual_description", ""))
	if desc.is_empty():
		desc = PlayerProfile.avatar_description(answers) # 兜底：极端路径（描述丢失）退旧模板
	var res := await api.post_json("/player-sprite", { "visualDescription": desc })
	if not await _apply_sprite_result(res):
		_prefetch_state = "failed"
		return
	_prefetch_state = "done"

## /player-sprite 返回体 → 预取槽（hash/贴图/锚点/最终描述）。false=失败。
func _apply_sprite_result(res: Dictionary) -> bool:
	var hash := String(res.get("spriteAsset", ""))
	if hash.is_empty():
		return false
	var tex := await api.fetch_texture(hash)
	if tex == null:
		return false
	var anch: Variant = res.get("anchors")
	_prefetch_anchors = anch if typeof(anch) == TYPE_DICTIONARY else {}
	_prefetch_hash = hash
	_prefetch_tex = tex
	var final_desc := String(res.get("visualDescription", ""))
	if not final_desc.is_empty():
		answers["visual_description"] = final_desc # refine 链的最新描述（下一次 refine 在它之上改）
	return true

func _generate_avatar() -> void:
	_gen_confirm.visible = false
	_gen_img.visible = false
	_refine_ready = false
	_gen_status.texture = UiAssets.tex("ic_wand")
	_start_avatar_prefetch()
	while _prefetch_state == "pending" or _flipping:
		await get_tree().process_frame
	if not is_inside_tree() or _page == null:
		return # 场景已切走（跳过）
	if _prefetch_state != "done":
		_next_page()
		return
	_reveal_avatar(true)

## 亮相（首次与每轮 refine 后共用）：出图 + 问「有没有哪里想变一变」+ 开麦听修改。
func _reveal_avatar(first: bool) -> void:
	_gen_status.texture = UiAssets.tex("ic_sparkle")
	_gen_img.texture = _prefetch_tex
	_gen_img.visible = true
	game_audio.play_sfx("reveal")
	_gen_confirm.visible = true
	if _refine_count >= REFINE_MAX:
		_on_gen_accept() # 改满上限：无论如何欢呼采纳（零挫败收尾，不再第三次挑刺）
		return
	if first:
		var dur := _play("ob_confirm") # 「你看，这就是你呀！喜欢吗？」
		if dur > 0.0:
			await get_tree().create_timer(dur + 0.1).timeout
		if not is_inside_tree():
			return
	await _say("有没有哪里想变一变呀？告诉点点，或者点勾勾我们就出发咯！")
	_refine_busy = false
	_refine_ready = true # 开麦听「头发要长一点」（_process 驱动）

## 照镜子一改：孩子点名的修改 → /player-sprite refine（LLM 并进描述再生图）。
func _refine_submit(text: String) -> void:
	if text.is_empty():
		_refine_busy = false
		return
	if _refine_count >= REFINE_MAX or String(answers.get("visual_description", "")).is_empty():
		_refine_busy = false
		return # 上限已到（理论上麦已关）或无描述可改（降级路径失联）：忽略，等 ✓
	_refine_busy = true
	_refine_ready = false
	_gen_confirm.visible = false
	_gen_img.visible = false
	_gen_status.texture = UiAssets.tex("ic_wand")
	_say("好嘞，点点改改看！")
	var res := await api.post_json("/player-sprite", {
		"refineFrom": String(answers.get("visual_description", "")),
		"refineRequest": text,
	})
	if not is_inside_tree() or _page == null:
		return
	if not await _apply_sprite_result(res):
		# 改失败：原图放回，别丢小朋友已有的形象
		_gen_img.visible = true
		_gen_confirm.visible = true
		_gen_status.texture = UiAssets.tex("ic_sparkle")
		_refine_busy = false
		_refine_ready = true
		return
	_refine_notes.append(text) # 修改原话随档案上报（个性化金矿）
	_refine_count += 1
	_reveal_avatar(false)

## 「就是我！」：采纳当前形象，进世界。
func _on_gen_accept() -> void:
	if _prefetch_hash.is_empty():
		return
	_refine_ready = false
	_vc.close()
	game_audio.play_sfx("confirm")
	answers["sprite_asset"] = _prefetch_hash
	answers["anchors"] = _prefetch_anchors # 与 sprite_asset 成对落档，_apply_player_sprite 灌进玩家节点
	_next_page()

# ── 旁白与推进 ────────────────────────────────────────────────────────────

func _on_page_shown(p: Dictionary) -> void:
	var dur := _play(String(p.get("voice", "")))
	if String(p["kind"]) == "story":
		_story_auto_t = maxf(dur, 0.5) + 1.2 # 旁白讲完停 1.2s 自动翻页
	# 预取不再挂 intro 页：描述由形象对话 done 时才定，预取在 _chat_apply/_chat_fb_done 触发

## 当前页此刻允许开麦吗（旁白/TTS 在播、请求在途时都不开）。
func _mic_allowed() -> bool:
	match _page_kind():
		"intro": return not _intro_submitting
		"avatar_chat": return not _chat_busy and not _chat_fallback # 降级题序纯点选
		"generate": return _refine_ready and not _refine_busy
	return false

func _process(delta: float) -> void:
	# （无悬浮微摆：书是摊在桌上的实体,晃动反而破坏"躺在桌面"的落地感）
	# duck（音量微降）留宿主：旁白在播 或 正在录音时压低，给人声让路。
	# BGM 静音（比 duck 更狠，断外放回灌）由 VoiceCapture 内部门控——聆听窗一开即静音，
	# 只在旁白/人声出声时放行（修正旧口径只在 recording 才静音、漏掉开麦等待窗的问题）。
	game_audio.set_ducked(_voice.playing or _vc.is_recording())
	# 开麦页（intro 名字 / avatar_chat 答题 / generate 说想改哪）旁白说完 → 自动开麦
	#（Android 端侧未就绪则不开、绝不上传）；VoiceCapture 内部 VAD 判开口/说完、自听防护、
	# 分片、端侧路由。step 每帧驱动（含 BGM 静音门控）。
	if _mic_allowed() and not _voice.playing and not _vc.must_wait_for_ready():
		_vc.open()
	_vc.step(delta)
	# 声波只在聆听窗（麦开着）流动；旁白/等待时落回静息，别假装在听。
	for w in [_intro_wave, _chat_wave, _gen_wave]:
		if w is VoiceWave:
			(w as VoiceWave).active = _vc.is_open()
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
	_vc.close() # 收尾时可能正开着麦：关掉,别留悬空会话
	var profile := PlayerProfile.load_profile()
	for k in answers:
		profile[k] = answers[k]
	profile["created_at"] = Time.get_datetime_string_from_system()
	PlayerProfile.save_profile(profile)
	# 档案落库（服务端副本，docs/onboarding-avatar-redesign-design.md §2.5）：fire-and-forget，
	# 欢呼旁白 ~3s 是它的完成窗口；失败静默——本地 profile.json 才是主档，离线可玩不受影响。
	_upload_onboarding_profile(profile)
	# 收尾欢呼后翻进世界。首次进世界必走「建造小世界」intro（教学+建造+可能的定档段）——
	# 刚写完档案但 intro_seen 仍 false，should_run 必真。
	IntroDirector.pending = IntroDirector.should_run()
	var dur := _play("ob_done")
	await get_tree().create_timer(maxf(dur + 0.3, 2.0)).timeout
	Loading.next_scene = "res://main.tscn"
	get_tree().change_scene_to_file("res://loading.tscn")

## onboarding 档案全量上报（名字/结构化属性/最终描述/refine 原话/形象 hash）。
## 键=player_id（设备端稳定 UUID）；服务端幂等覆盖，重跑 onboarding 重报即可。
func _upload_onboarding_profile(profile: Dictionary) -> void:
	var attrs: Variant = profile.get("avatar_attrs", {})
	api.post_json("/onboarding/profile", {
		"playerId": PlayerProfile.ensure_player_id(),
		"name": String(profile.get("name", "")),
		"nickname": String(profile.get("nickname", "")),
		"attrs": attrs if typeof(attrs) == TYPE_DICTIONARY else {},
		"visualDescription": String(profile.get("visual_description", "")),
		"refineNotes": _refine_notes,
		"spriteAsset": String(profile.get("sprite_asset", "")),
		"createdAt": String(profile.get("created_at", "")),
	})
