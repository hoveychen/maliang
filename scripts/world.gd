extends Node3D
## Demo 世界控制器（P5）。
## 浮动原点 + chunk streaming + world-bending + HD-2D 纸片角色 + 点击进交互模式。
## 逻辑/数据是纯平铺环面；弯曲只在渲染。角色精灵不走 shader，改用 CPU 复算
## 弯曲量、沿相机上方向落到弯曲地表（曲面世界放置物体的通用解法）。

## 世界首屏就绪：首屏 chunk 全部 skin 完毕 + 在线引导结束（或超时兜底）后发出，
## loading.gd 收到即淡出过场交还世界。断网时 _bootstrap 提前返回，超时也会兜底放行。
signal world_ready

const READY_TIMEOUT_SEC := 25.0   ## 就绪硬超时：仅防卡死兜底。必须 > api.get_world 的网络超时（GET_WORLD_TIMEOUT_SEC=18），
                                  ## 保证「慢但成功」的 get_world 在揭幕前返回（走正常路径、玩家已就位），
                                  ## 而不是揭幕后才返回把玩家硬拽到仙子旁——那正是启动瞬移的成因。
const READY_MIN_SEC := 0.4        ## 最短等待：首屏 chunk 至少铺一轮，避免 world_ready 抢在铺设前发出
const PLAYER_SPEED := 8.0         ## 方向键直接驱动玩家的速度（与 BehaviorExecutor.SPEED 一致）
const CHARACTER_SHADOWS := true   ## 实验：只给会动的角色投实时定向阴影（地面/建筑/散布/水全不投）；关则全场景平光靠脚下暗斑。真机 Mali-G76 上看是否划算
const GOD_PITCH_DEG := 47.0       ## 默认跟随视角：地平线落屏幕 ~4/5 高度（约 20% 天空）
const LOCK_PITCH_DEG := 30.0      ## lock 跟随：明显放平（3/4 平视，地平线 ~3/4、约 25% 天空）
const SPRITE_LEAN_FACTOR := 0.55  ## 角色固定倾角 = (90-相机角)*该系数（站立感+面向相机折中）
const GOD_DIST := 23.0            ## 玩家占屏高 ~1/7（占位形象 3.2 单位实测 1/6.9；36 时仅 1/11 太远）
const LOCK_DIST := 20.0
const ZOOM_MIN := 16.0
const ZOOM_MAX := 64.0
const CAM_EASE := 6.0             ## 视角过渡速度（pitch/dist/focus 一起缓动）
# 对话站桩 + 双方构图 + 说话人跟随（近身对话专用，见 _enter_interaction / compute_dialog_cam）
const STAGE_GAP := 5.0            ## 站位间距（米）：玩家跳到 NPC 对应侧、离 NPC 此距离处站定
const STAGE_HOP_DUR := 0.32       ## 玩家跳到站位的小跳时长（秒）
const STAGE_HOP_HEIGHT := 1.1     ## 小跳竖直弧线峰高（米）
const DIALOG_FILL := 0.5          ## 基础构图：最高者高度占屏中间 50%（1/4 → 3/4）
const DIALOG_ZOOM_MIN := 6.0      ## 对话态轨道距离下限（远小于 god 态 ZOOM_MIN，允许贴近构图小体型角色）
const CREATION_CAM_DIST := 11.0   ## 创造视图特写：框住仙子 + 她身旁的降生蛋/魔法熔炉（答案要「看得见飞进去」）
const CREATION_CAM_SHIFT := 3.0   ## 焦点右移量：让仙子渲染到屏幕偏左，右侧留给 2×2 大卡
## 引导期占位符相对仙子的落位：落到屏幕左下的空地——右边是 2×2 大卡、底部中央是麦克风条，
## 都不能压着（人眼 QA screenshots/creation_view.png 逐版校过）。
const CREATION_PLACEHOLDER_OFFSET := Vector2(-1.0, 2.5)
const CREATION_PLACEHOLDER_SCALE := 1.35 ## 引导期占位符放大些：远景里的蛋/炉太小，孩子看不清答案飞进了哪儿
const THROW_TIME := 0.55          ## 答案卡飞进蛋/炉的时长（够看清，又不拖慢一轮追问）
const THROW_END_SCALE := 0.18     ## 飞到终点时缩到多小（被「吸」进去的感觉）
const SPEAK_SHIFT := 0.35         ## 说话人跟随：焦点朝说话方偏移的比例（0=两人中点，1=完全对准说话方）
const SPEAK_ZOOM_BLEND := 0.45    ## 说话人跟随：轨道距离朝「说话方单独占 50%」混合的比例（小体型→距离更近→zoom 更多）
const PICK_RADIUS_PX := 80.0
const THINK_TIMEOUT := 40.0       ## 「思考中」最长等待秒数；超时(响应丢失/网络/TLS)自动清除，杜绝永久卡死
const PLAYER_ID := "player"
const PLAYER_SPAN := 2            ## 玩家占地（半格数），与 NPC 一致
const APPROACH_ARRIVE := 2.6      ## 跑向 NPC 的到达半径：对象自身占格，走到旁边即算到（同送信）
# 收听 HUD：底部 AIGC 生成的奶油圆角边框贴图（hud_listen，麦克风+音波+星饰）+ 声波柱嵌入内板。
const WAVE_HUD_W := 340.0         ## HUD 边框屏上宽度（像素）；高度按贴图 640×315 比例推算
const WAVE_HUD_ASPECT := 315.0 / 640.0
const WAVE_BARS := 9              ## 声波柱数（居中排在边框空心内板）
const WAVE_MIN_H := 8.0           ## 声波柱静息高度（像素）
const WAVE_MAX_H := 40.0          ## 声波柱满音量高度（像素）
const WAVE_BASE_Y := 18.0         ## 柱底相对 HUD 竖直中心的下移量（像素）：波条落在内板中下部
## 创造视图里收听 HUD 的落位：右半屏被 2×2 大卡占掉（左缘约 x=652）、左下角是降生蛋/熔炉（右缘约 x=355），
## 中间只剩约 297px 的缝，塞不下 340px 的原尺寸——整体缩小并左移落进缝里，两侧各留约 16px。
## 用 scale 而非改 offsets：边框贴图与声波柱同比缩，不会各缩各的（见 _layout_voice_wave）。
const CREATION_WAVE_SCALE := 0.78
const CREATION_WAVE_DX := -136.0  ## 创造视图里 HUD 的水平位移（像素，负=左移）
## 引导精灵的名字（神笔的笔灵，见 docs/fairy-persona-design.md）。与服务端 types.ts 的
## FAIRY_NAME 保持一致——只在离线占位随从上用（在线时名字随服务端角色下发）。
const FAIRY_NAME := "点点"
const FAIRY_HEIGHT := 1.5         ## 点点立绘世界高度（头部大小的随从，时之笛式）
const VILLAGER_BASE_HEIGHT := 6.0 ## 村民/角色世界高度基准（中号体型）；×appearance.scale 得实际高度
const BODY_SCALE_MIN := 0.4       ## 体型倍率防御 clamp 下限（挡服务端坏数据）
const BODY_SCALE_MAX := 2.0       ## 体型倍率防御 clamp 上限
const FAIRY_HOVER := 2.4          ## 小仙子悬浮基准高度（米，脚底离地）
const FOG_DEPTH_BEGIN := 52.0     ## 深度雾起点（焦点在平地时；随 _cur_focus_y 整体补偿）；后移让中景摆脱奶白罩
const FOG_DEPTH_END := 95.0       ## 小世界(span 150)：~95 外渐隐进天空，藏住远端循环，保留无限地平线感（不可后移，环面循环会穿帮）
const SKY_HORIZON_COLOR := Color(0.80, 0.86, 1.0) ## 天空地平线色 = 雾色（远地渐隐进天空的无缝衔接）；偏粉蓝而非奶白（Pokopia 式远景往蓝去）
const SKY_ZENITH_COLOR := Color(0.46, 0.69, 0.95)  ## 天顶色（可见天空带上缘的深一档蓝）；粉彩淡蓝
const SKY_WIND := Vector2(0.006, 0.0015)           ## 云漂移速度（uv/秒），非零 = 天空是动的
# 纸片动作演出（_update_paper_motion）
const WALK_SWAY_DEG := 6.0   ## 走路左右摇摆角（度，绕脚底 roll）
const WALK_SWAY_HZ := 2.6    ## 摇摆频率（步频感）
const WALK_FLUTTER := 0.10   ## 走路下摆飘动幅度（米，paper shader 行波）
const IDLE_CURL := 0.045     ## 待机呼吸微卷幅度（米，左右边缘向 Z）
const FLIP_SPEED := 10.0     ## 翻面角速度（rad/s，~0.3s 完成一次转身翻面）
const FACE_MOVE_EPS := 0.5   ## 认定横向移动的最小速度（米/秒），防原地抖动换面
# 动画段切换阈值（_update_anim_clip）：走路强度 paper_walk 是 0..1 的缓动量，单阈值会让
# 角色在起步/刹车经过阈值时来回抖段，所以进/出用两个值（滞回）。
const CLIP_MOVE_ON := 0.30   ## 走路强度升过它 → 请求 moving 段
const CLIP_MOVE_OFF := 0.12  ## 走路强度落回它以下 → 回 idle 段
## 走路踏步弹跳幅度（米）。走路观感是**程序化**的，不是生成的图集段——实测 Seedance 做不出
## 这些角色的行走循环：腿常被裙子/身体挡住，模型做不出迈步就自己改成原地转身摇摆，还把
## 道具换到另一只手（角色外观都变了），横向漂 0.87m。所以 moving 段服务端不生成，走路靠
## 这里的踏步弹跳 + 已有的左右摇摆(WALK_SWAY_DEG)/下摆飘动(WALK_FLUTTER) 三件叠出来。
const WALK_BOB := 0.14
# 「主动看你」环境演出（借鉴 Pokopia「生物即角色」）：近身空闲村民偶尔转头看玩家并挥手/点头。
const NOTICE_RADIUS := 6.5   ## 触发半径（米）：玩家进这个范围内的空闲村民才会注意到
const NOTICE_CD_MIN := 8.0   ## 单个村民两次打招呼的最短间隔（秒）
const NOTICE_CD_MAX := 20.0  ## 最长间隔（秒）；每次随机取，天然错峰不齐步
const NOTICE_WALK_EPS := 0.06 ## paper_walk 低于此视作站定（走动中不打断脚步去打招呼）
const NOTICE_BUBBLE_LIFE := 2.2  ## 打招呼小表情气泡展示秒数（含尾段淡出）
const NOTICE_BUBBLE_H := 1.5     ## 气泡世界高度（米）
const NOTICE_EMOTES := ["happy", "wave"] ## 打招呼随机小表情（正向友好）
# 平板双指手势临时视角（捏合缩放 / 双指位移环绕+俯仰；松手 5s 无操作自动复原）
const GESTURE_RESET_DELAY := 5.0   ## 全部手指抬起后无进一步手势的复原倒计时（秒）
const GESTURE_YAW_SENS := 0.005    ## 双指横移 → 水平环绕角（rad/px，~200px 转 57°）
const GESTURE_PITCH_SENS := 0.15   ## 双指纵移 → 俯仰（度/px；上滑放平、下滑俯视）
const GESTURE_PITCH_MIN := 12.0    ## 手势后的最终俯仰下限（太平会穿地平线/穿雾）
const GESTURE_PITCH_MAX := 85.0    ## 上限（近垂直俯视）
const GESTURE_ZOOM_MUL_MIN := 0.35 ## 距离倍率范围（最终距离另有 ZOOM_MIN/MAX 硬夹）
const GESTURE_ZOOM_MUL_MAX := 2.5

var focus_logical := Vector2.ZERO   ## 相机在环面上聚焦的逻辑坐标（跟随玩家/交互对象）
var focus_override := Vector2.INF   ## 测试脚本抢镜头用：非 INF 时聚焦固定到这里
var _cur_pitch := GOD_PITCH_DEG
var _cur_dist := GOD_DIST
var _target_pitch := GOD_PITCH_DEG
var _target_dist := GOD_DIST
var _cur_focus_y := 0.0             ## 相机焦点高度 = focus 所在 tile 的台阶高度（缓动，防上台阶时画面跳变）
var _env: Environment               ## 世界环境（深度雾起止随 _cur_focus_y 补偿，山顶视角不整体变浓雾）
var _sun: DirectionalLight3D        ## 太阳灯（画质「角色实时阴影」开关切 shadow_enabled；_setup_environment 存下）
var _gfx_levels := {}               ## 画质旋钮当前档 {key: int level}（存档用的权威副本；设置页控件在 PhoneUi）
var _locked: PaperCharacter = null ## lock 跟随的角色（null=god 自由模式）
var _stage_player_logical := Vector2.ZERO ## 对话玩家站位（小跳落点）
var _hop_from := Vector2.ZERO      ## 小跳起点 logical
var _hop_t := -1.0                 ## 玩家小跳已播秒数（<0=不在跳，见 _step_hop）
var camera: Camera3D
var photo_cam := {}   ## 摄影机位覆盖（debug photo 命令，menu 相册拍摄）：非空时 _update_camera 改用 {pitch,yaw,dist,lift}
var chunk_manager: ChunkManager
var coord_label: Label
var perf_label: Label    ## 调试性能浮层（仅 debug 构建）：CPU 逻辑/渲染提交/GPU 实测三组耗时对比判瓶颈
var _perf_accum := 0.0   ## 浮层刷新节流（0.25s 一次，避免数字抖到读不了）
var _hud_tile := Vector2i(-9999, -9999)  ## 上次显示的 tile（没跨格不重排 HUD 字符串）
# 调试语音耗时浮层（仅 debug）：一轮对话四段 ms —— VAD（开口→断句）/ASR（端侧识别）/
# LLM（发转写→回应）/TTS（回应→首音出声）。ASR 与 VAD 已拆开；服务端 ASR 路径拆不开时并入 LLM。
var voice_prof_label: Label
var _vt_speak_start := 0  ## 开口 _utterance_begin
var _vt_speak_end := 0    ## 断句 _utterance_commit
var _vt_asr_done := 0     ## 端侧识别出文本 _on_local_asr_final
var _vt_send := 0         ## 发 voice_transcript 的时刻
var _vt_response := 0     ## character_response 到达
var _vt_tts_out := 0      ## 本轮首个 TTS 音频起播
var banner: Label
var heard_label: Label   ## 顶部显示 ASR 识别到的文字（"听到：…"，给家长确认）
var confirm_bar: ConfirmBar ## 说完先听一遍的确认条（仅 confirm_mode 开时出现）

var critter_tex: Texture2D
var npcs: Array = []              ## [{ node:PaperCharacter, logical:Vector2 }]
var player: Dictionary = {}       ## 玩家角色 { node, logical, id, span }；不进 npcs（拾取/对话只对 NPC）
var selected: PaperCharacter = null
var voice_wave: Control            ## 底部收听 HUD（AIGC 边框贴图 + 声波柱，近身对话期间显示，见 _update_voice_wave）
var voice_wave_widget: VoiceWave   ## voice_wave 内嵌的共用声波控件（流动波，自跑动画）
var _dragging := false
var _press_pos := Vector2.ZERO
# 暗黑式按住跟随：指针按在空地上即走，按住期间节流重下发指针下地面为移动目标
const HOLD_FOLLOW_INTERVAL := 0.12
var _hold_follow := false
var _hold_pos := Vector2.ZERO
var _hold_timer := 0.0
# 双指手势状态：临时偏移叠加在 god/lock 基准视角之上，复原后完全回到基准
var _touches := {}          ## 按下的手指 index → 屏幕坐标（含单指，供第二指落下时取双指位置）
var _gesturing := false     ## ≥2 指落下后置位，全部抬起才清（期间吞掉单指拾取/跟随）
var _gest_yaw := 0.0        ## 当前水平环绕角（rad，绕焦点；0=默认正北视角）
var _gest_yaw_t := 0.0
var _gest_pitch := 0.0      ## 俯仰临时偏移（度，叠加在 _cur_pitch 上）
var _gest_pitch_t := 0.0
var _gest_zoom := 1.0       ## 距离倍率（叠加在 _cur_dist 上）
var _gest_zoom_t := 1.0
var _gest_reset_t := 0.0    ## 复原倒计时（>0 时递减，归零瞬间目标回基准）
# 点击落点标记（黄色圆片，淡出）
const TAP_MARKER_LIFE := 0.8
var _tap_marker: MeshInstance3D = null
var _tap_marker_logical := Vector2.ZERO
var _tap_marker_t := 0.0

# intro 教学视觉指引（Bug②）：地面脉动光环 + 话筒 HUD 提示，由 IntroDirector 各教学步开关。
var _intro_hint: MeshInstance3D = null   ## 目标地面/村民脚下的脉动光环
var _intro_hint_logical := Vector2.ZERO
var _intro_hint_active := false
var _intro_hint_t := 0.0                 ## 呼吸相位
var _intro_mic_hint := false             ## 说话步：亮底部话筒+声波 HUD（放行 _update_voice_wave）

# M2 语音交互（近身开放麦：无按钮，VAD 自动断句）——编排收敛到 VoiceCapture 模块（见 _vc）
var backend: Backend
var _vc: VoiceCapture               ## 开放麦编排（mic+VAD+端侧/服务端ASR+自听防护+BGM门控），与 onboarding 共用
var thinking_label: Label          ## 思考状态源+家长可读小字（幼儿看角色头顶的 _think_bubble 动画）
var _think_timer: Timer            ## 「思考中」兜底超时（响应没回来时自动解卡）
# ── B3 语音起名（reuse-name §2.2/§3.2）：造物成功后点点问「叫它什么呀？」，复用 VoiceCapture 确认模式 ──
var _naming_item := ""             ## 非空 = 起名子模式：麦与 capture 回调都归起名，不走对话
var _naming_prev_confirm := false  ## 起名强制 confirm_mode，结束后恢复玩家原「说完先听一遍」设置
var _naming_timer: Timer           ## 起名静默超时：点点问完孩子没吭声/害羞 → 静默放弃（起名可选，§3.3）
const NAMING_TIMEOUT := 12.0       ## 起名等待上限（秒）：正在说/确认则续一轮，否则放弃
var _pending_reuse := {}           ## 待点的复用提示 {itemId,itemName}（服务端 npc_wishes 下发）；播一次即清
## A4 心愿清单（M1，docs/kids-thinking-little-boss.md）：npc_wishes 推导的只读视图，
## 每项 {characterId, ability, source}。硬上限 3 张卡——多了幼儿被信息淹没（§3.2）。
const WISH_BOARD_MAX := 3
var wish_board: Array = []
var _think_bubble: Label3D         ## 思考动画气泡：选中角色头顶 ·/··/··· 循环冒泡（不识字友好）
var _think_anim_t := 0.0           ## 思考气泡动画相位
var emotion_bubble: Sprite3D       ## 角色头顶情绪贴纸气泡（AIGC em_*，见 _show_emotion）
var _npc_chat_bubble: Sprite3D     ## NPC 间聊天轮流气泡（同一时刻只演一场，见 _update_npc_chats）
var _emotion_pop_t := -1.0         ## 情绪弹出动画已播秒数（<0 = 不在弹出中）
var _emotion_life := 0.0           ## 情绪气泡剩余展示秒数（尾段淡出后隐藏）
var _speak_anim_t := 0.0           ## 说话呼吸弹跳相位
var _speak_scales_settled := true  ## 所有角色缩放已回正（_update_speak_anim 空转早退用）
var _os_name := OS.get_name()       ## 平台名（headless 测试可覆盖成 "Android" 验端侧门禁）
# 空识别退避（缺陷 ①）：误触发录到近静音 → ASR 返回空 → 若立刻重开麦就会被噪声再触发，
# 形成连环录。空结果不再当一轮正常结束，而是闭麦退避一段（连续空则指数退避，见 InteractionFsm）。
var _empty_streak := 0              ## 连续空识别次数（拿到有效转写即清零）
var _cooldown_t := 0.0              ## 退避剩余秒数（>0 即闭麦，派生为 COOLDOWN 态）
# 「说完再走」（缺陷 ④）：leave 指令先挂起，等回应说完再动身 + 关对话。
# { npc, script, seen, arm, deadline }；空 = 没有挂起的离开。
var _pending_leave: Dictionary = {}
# 奖赏系统：进行中委托 + 小红花钱包（服务端权威，world_state/task_complete 同步；见 docs/reward-flower-design.md）
var active_task: Dictionary = {}   ## 进行中委托（空=无），见 _set_active_task
## 点了委托 chip 想问点点该怎么做：置真后走 approach，到位进 _enter_interaction 时发合成问句（见 _ask_fairy_about_task）。
var _pending_task_hint := false
## 点 chip 时替小朋友对点点说的那句：她带 activeTask 上下文回（跑腿提带路/心愿提一起造）。
const TASK_HINT_QUESTION := "这个任务怎么做呀？"
var wallet: Dictionary = { "flowers": 0, "stampProgress": 0, "stampsTotal": 0 } ## 小红花钱包
## 见证游标：小朋友**亲眼见过**的钱包状态（存 profile.json）。服务端算完的账要等他打开手机
## 亲手把章盖上才认——差额就是欠盖的章。见 StampCeremony / docs/stamp-flower-ux-design.md §3。
var stamp_seen: Dictionary = StampCeremony.empty_seen()
var _stamp_styles: Array = []      ## 在线期间 task_complete 带来的真章款式（先进先出，补演用）
var task_chip: HBoxContainer       ## 右上角委托提示（目标图标+短名 ⇒ 盖章奖励图标）
# 专门的「创造视图」（造角色/造物共用）：一进创造就退出普通对话构图，相机推近仙子特写、
# 背景压暗，屏幕中央弹 2×2 大图标卡（方案 A）。平时隐藏。
var _creation_view: Control        ## 创造视图根（全屏暗底 + 居中大卡；吃掉卡外点击）
var _creation_cards: GridContainer ## 居中 2×2 大图标卡网格
var _creation_q: Label             ## 顶部问题字幕（语音为主，字给家长）
var _creation_dots: HBoxContainer  ## 顶部进度圆点（每答一轮点亮一个）
var _creation_cancel_btn: Button   ## 右上角圆叉：随时退出创造（蛋/炉一起收）
var _creation_step := 0            ## 已走过的轮数（点亮的圆点数）
var _creation_cam := false         ## 创造视图相机特写态（推近仙子；退出创造复位）
var _in_creation := false          ## 正在引导式创造（造角色或造物；期间语音/点选都是这次会话的答复）
var _creation_goal := "character"  ## 这次引导在造什么（服务端 creation_prompt.goal）：character→降生蛋，prop→魔法熔炉，build→拼装台
var _creation_category := ""       ## 本轮追问的类别（creation_prompt.category）；'recipient'（A2 给谁做的）时多加一张「随便啦」软退出卡
var _creation_options: Array = []  ## 本轮追问的原始选项（[{id,label,iconAsset}]）——e2e harness 据此点卡应答（debug_cmd_server 快照读）
# ── 积木式造物（build，docs/kids-thinking-build-from-parts.md）拼装台状态 ──
var _build_blueprint_id := ""      ## 正在拼哪副蓝图（build_prompt.blueprintId）
var _build_slot := ""              ## 当前要填的槽（build_prompt.slotId）——拼装台点亮它发光；与服务端 askedSlots.at(-1) 一致
var _build_filled := {}            ## 已填槽 slotId → {partId, partRenderRef}（客户端累积，喂拼装台预览）
var _build_option_refs := {}       ## 本轮零件盘 partId → renderRef（点选后更新预览取用）
var _build_preview: ComposedProp = null  ## 浮在仙子身旁的拼装台预览（骨架 + 已填零件 + 当前槽发光）
const BUILD_PREVIEW_OFFSET := Vector3(2.2, 1.6, 0.0)  ## 拼装台相对仙子的偏移：侧旁 + 略上（与仙子同框）
# 复用改装（B1，§3.1「拆开重组」）：物品页点组合物→「拆开改改」→拼装台预填它的零件→点槽换掉→做好了
# 落成一行**新** ItemDef（旧的保留在背包，通往 B3）。复用 build 拼装台预览（_build_preview/_build_filled/
# _update_build_preview），但**无 LLM 会话**——客户端本地权威编辑零件树，做好了直接 send_create_build。
var _remixing := false             ## 正在改装（区别于 build 引导会话的 _in_creation）
var _remix_item_id := ""           ## 正在改装的原组合物 id（旧的不动，新造一行）
var _remix_options := {}           ## slotId → [{id,label,renderRef}] 每槽兼容零件（服务端 build_options 取回）
var _remix_stage := "slots"        ## "slots"=选要改的槽 / "parts"=为某槽挑零件
var _remix_slot := ""              ## parts 阶段正在为哪个槽挑零件
var _remix_confirm_btn: Button = null  ## 「做好了」落成按钮
var _remix_choice: Control = null  ## 物品页点组合物弹的「摆到世界 / 拆开改改」二选一小卡
var _task_check_t := 0.0           ## bring/visit 完成判定的节流计时
var _hud_layer: CanvasLayer        ## HUD 层（奖励飞入动画等临时控件挂这里）
var album_button: Button           ## 左下角手机启动器按钮（AIGC 手机图标）
var paper_phone: PaperPhone        ## 3D 纸糊双折叠手机（挂相机子节点，持机位见 PHONE_NDC）
var phone_ui: PhoneUi              ## 手机屏幕内容（两块 SubViewport 里的 Control 树 + 三 app）
# 物品系统：语音造物的物件可摆可收，收集册物品页列出收进背包的（服务端权威，state 同步）
var bag: Dictionary = {}           ## 背包（服务端权威）：物品实体 id → 份数（world_state/bag_update 同步）
# —— 手机：左下角启动器按钮 → 相机前弹出 3D 纸糊双折叠手机（PaperPhone 载体 + PhoneUi 内容）——
const PHONE_LAUNCHER_ICON := "ic_phone_fairy" ## 启动器图标资产（AIGC，缺失回退程序化占位）
## 盖章款式 id（与 server STAMP_STYLES 对齐）→ 图标 stamp_<style>（AIGC 集邮章）。
const STAMP_STYLES := ["star", "smile", "paw", "medal", "heart"]
## 3D 手机持机位（fit_to_camera 参数）：正面态贴屏右侧（玩家在屏左）；跨页态双倍宽，往中间收。
const PHONE_FILL := 0.85            ## 正面态机身高占屏比
const PHONE_NDC := Vector2(0.52, 0.0)        ## 正面态中心 NDC
const PHONE_SPREAD_FILL := 0.80     ## 跨页态机身高占屏比
const PHONE_SPREAD_NDC := Vector2(0.28, 0.0) ## 跨页态中心 NDC
var _phone_fit_vp := Vector2.ZERO   ## 上次贴合时的视口尺寸（窗口 resize 触发重贴合）
var _phone_dock_t := 0.0            ## 停靠态低频渲帧计时（60s 一帧，熄屏画面时钟走字）
## 手机近身相机：开手机时按玩家立绘高度反算距离，让玩家（自适应身高）占屏高约 70%，
## 并把焦点右移，使玩家落在屏幕偏左、右侧留给手机（PHONE_PLAYER_NDC_X 方向若反了取负）。
const PHONE_CAM_FILL := 0.70        ## 玩家立绘占屏高约 70%（按 _char_top 反算距离，自适应身高）
const PHONE_CAM_DIST_MIN := 3.5     ## 近身距离下限（比对话态更近，撑到 70%）
const PHONE_PLAYER_NDC_X := 0.30    ## 玩家横向落点（0=正中，0.30=中心偏左 30%），右侧留给手机
## 可玩时间预算（桌面 widget 用饼图展示剩余；超时冷却）：默认每轮 45 分钟、冷却 10 分钟，循环。
const PLAY_BUDGET_SEC := 2700       ## 每轮可玩时长（45 分钟）
const PLAY_COOLDOWN_SEC := 600      ## 超时冷却时长（10 分钟）
# —— 可玩时间预算（真强制冷却，跨会话持久化，见 tick/reconcile_play_budget + PlayerProfile.*_play_budget）——
var _play_used_sec := 0.0           ## 本轮已累计活跃游玩秒数
var _play_cooldown_until := 0.0     ## 冷却结束 unix 时间戳（0=不在冷却）
var _play_blocked := false          ## 当前是否被冷却拦截（拦世界交互 + 弹冷却遮罩）
var _play_remaining_frac := 1.0     ## 可玩剩余比例（喂桌面 widget 饼图）
var _play_cooldown_frac := 0.0      ## 冷却进度比例（喂冷却遮罩饼图）
var _play_save_t := 0.0             ## 预算落盘节流计时
var _cooldown_overlay: Control      ## 冷却期全屏拦截遮罩（挡世界交互 + 闹钟饼图倒计时 + 文案）
var _cooldown_pie: PlayTimePie      ## 遮罩上的大闹钟饼图（冷却进度）
# —— 手机开合的遮罩/相机态/图标分页 ——
var _phone_scrim: Control           ## 手机开着时的全屏透明遮罩：吞掉手机外的点击→收起手机（不当移动指令）
var _phone_cam := false             ## 手机近身相机态（开手机 true，收手机 false）
var _phone_cam_saved_dist := 0.0    ## 进近身前的 _target_dist（收手机还原）
var _phone_cam_shift := 0.0         ## 近身焦点右移量（按距离/宽高比动态算，见 _recompute_phone_cam）
var _phone_cam_lift := 0.0          ## 近身焦点竖直抬升（把玩家框在屏幕竖直中段）
const PROP_LONG_PRESS := 0.6       ## 长按拾起阈值（秒），期间手指基本不动
const NO_PRESS_TILE := Vector2i(-1, -1)
var _prop_press_tile := NO_PRESS_TILE ## 按下时指下的可拾物品 tile（长按候选，滑动/抬指取消）
var _prop_press_edge := -1         ## 长按候选是边缘贴纸时的 side（0..3），-1=不是贴纸
var _prop_press_t := 0.0           ## 长按累计秒
var _bag_action := ""              ## 最近一次拾/摆动作（"pickup"/"place"/""），bag_update 回包据此出横幅
const BRING_DONE_DIST := 4.5       ## 带人：目标与委托人相邻半径
const VISIT_DONE_DIST := 14.0      ## 探访：玩家到地点中心半径（POI 中心可能不可达，如池塘水面）
var _executors: Array = []        ## 活跃的 BehaviorExecutor
var _stage: StageAgent            ## 舞台协议大脑（剧本系统，见 stage_agent.gd）；_setup_backend 接线
var _hud: HudFactory              ## 舞台 HUD 工厂（计分/倒计时/toast，见 hud_factory.gd）；_setup_hud 建
var _stage_active := false        ## 观演/游戏态：期间吞玩家输入，StageAgent 全权调度演出
var _bench_freeze := false         ## benchmark 全程：锁玩家输入 + 仙子注魔定格（相机/主角不动；仙子是 billboard，定格不改帧成本，纯为旁白干净）
var _stage_drives: Array = []     ## 进行中的完成型舞台命令 { ex:BehaviorExecutor, done:Callable }
var _stage_holds: Array = []      ## 设置型持续驱动的执行器（follow/flee）：收场统一 cancel（永不自完成）
var _stage_speaks: Array = []     ## 进行中的舞台念白 { done:Callable, deadline:float, started:bool }
var _stage_balls := {}            ## C 档球实体 id → StageBall 节点（spawn_ball 建、收场统一 free）
var _fairy_drift_t := 0.0         ## 小仙子漂移/浮动相位
var fairy_voice: FairyVoice       ## 预制台词播放器（构建期 TTS，运行期零调用）
var story_voice: StoryVoice       ## 故事音包（M2）：章回剧本台词预烧 WAV，miss 回落 clientTts
var npc_wish_voice: NpcWishVoice  ## 村民心愿漏话（3D 定位音，按距离衰减；见 npc_wish_voice.gd）
var npc_greeter: NpcGreeter       ## 村民主动社交调度（走过来打招呼；见 npc_greeter.gd）
var game_audio: GameAudio         ## BGM + 音效（语音/思考时自动 duck）
var _fairy_bubble: Sprite3D       ## 小仙子说话时的音符气泡（AIGC ic_note）
var _fairy_greeted := false       ## 每次启动只问候一次
var _fairy_chat_t := 3.0          ## 下一次闲聊倒计时（首次 ~3s 内问候）
## 退避式沉默（fairy-persona P5）：孩子在沙盒里发呆/自言自语是最有价值的游戏时刻，点点不该
## 定时轰炸。每说一句无人回应的 idle 闲话就把下次等待拉长（+30s 每次，封顶 +150s），
## 孩子一互动就归零——从「每 15-25s 唠叨」变成「说一句，然后越等越久」。
var _fairy_idle_backoff := 0.0
const FAIRY_IDLE_BACKOFF_STEP := 30.0
const FAIRY_IDLE_BACKOFF_MAX := 150.0
## 安静一会儿（fairy-persona P5）：手机「点点睡觉」app 把点点哄睡——她说句困话后完全闭嘴
## （ambient + POI 都静音），孩子一互动就自然醒。能被叫停的陪伴才不叫骚扰。
var _fairy_napping := false
var _fairy_poi: Dictionary = {}   ## 进行中的 POI 提醒 { point, trigger, spoke, hold }
var _poi_check_t := 6.0           ## POI 扫描倒计时（每 2s 一次，开局先安静一会）

## 进行中的引路（服务端 guide_to 下发，见 docs/fairy-guide-design.md）：
## { plan: Dictionary, leg: int, nudge_t: float, elapsed: float, last_gap: float }
## 她不会走路（_run_behavior 对 is_fairy 早返回），引路故意不走行为脚本：走路的是小朋友，
## 她只飞在前面领路、回头等。玩家的操控权全程不被剥夺——这是与 stage（吞输入）的根本区别。
var _fairy_guide: Dictionary = {}
var guide_stop_button: Button     ## 引路中的「不去了」按钮（取消入口之一，另一路是语音 guide_stop）
var _guide_used := false          ## 本次进世界用过引路没有——用过就不再播「想去哪儿玩呀」的引导提示
var _last_greeting := ""          ## 最近一次收到的「对方先开口」招呼词（harness 观测招呼链用，仅 debug 快照读）

## 默认地形的兴趣点：池塘 / 北部主峰 / 东南瞭望丘风车 / 西南沼泽小潭。
## 发现半径内且台词未冷却时，小仙子飞过去提醒（台词冷却 180s 天然防重复唠叨）。
## name/aliases：语音指令「去某地」的地点名解析（名字与小仙子台词一致，见 _resolve_location）。
const POIS := [
	{ "tile": Vector2i(24, 24), "radius": 20.0, "trigger": "poi_pond", "name": "池塘", "aliases": ["湖", "水边", "河边"] },
	{ "tile": Vector2i(31, 7), "radius": 22.0, "trigger": "poi_mountain", "name": "大山", "aliases": ["山", "高山", "山顶"] },
	{ "tile": Vector2i(59, 54), "radius": 20.0, "trigger": "poi_windmill", "name": "风车", "aliases": ["大风车", "风车山"] },
	{ "tile": Vector2i(13, 50), "radius": 18.0, "trigger": "poi_marsh", "name": "小水潭", "aliases": ["水潭", "树林", "小树林"] },
	# M2 章回剧情：三只小猪的家（seed 站位旁）。仙子只提示有故事听，不催促（cooldown 长）。
	{ "tile": Vector2i(30, 46), "radius": 16.0, "trigger": "poi_story_pigs", "name": "小猪家", "aliases": ["三只小猪", "猪大哥家", "砖房"] },
]
## 运行期 POI：服务端 scenes.pois 下发则替换，否则沿用上面的内置常量（离线/老服务端）。
## POIS 仍是类常量，test_fairy_voice 据它校验「每个内置触发器都有台词」。
var pois: Array = POIS

## 把服务端下发的 POI 转成运行期结构（tile 由 [x,y] 变 Vector2i）。非法条目跳过。
## 全部非法/空 → 保留内置常量，绝不让世界变成没有地点的空壳。
static func parse_server_pois(list: Variant) -> Array:
	if typeof(list) != TYPE_ARRAY:
		return []
	var out: Array = []
	for e in (list as Array):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		var t: Variant = d.get("tile", null)
		if typeof(t) != TYPE_ARRAY or (t as Array).size() != 2:
			continue
		var name := String(d.get("name", ""))
		var trigger := String(d.get("trigger", ""))
		if name.is_empty() or trigger.is_empty():
			continue
		out.append({
			"tile": Vector2i(int((t as Array)[0]), int((t as Array)[1])),
			"radius": float(d.get("radius", 20.0)),
			"trigger": trigger,
			"name": name,
			"aliases": d.get("aliases", []),
		})
	return out

const POI_FLY_CAP := 9.0          ## 提醒飞行离玩家的最远距离（保持在视野内）
## 引路参数（fairy-guide）。领飞距离比 POI 提醒远一些——要有「在前面带路」的感觉，但仍封顶在视野内：
## 她飞没影了，小朋友就不知道该往哪走，引路也就白引了。
const GUIDE_FLY_CAP := 12.0       ## 领飞离玩家的最远距离（超过就停下等）
const GUIDE_ARRIVE_DIST := 3.0    ## 玩家离路点多近算「到了」
const GUIDE_NUDGE_INTERVAL := 8.0 ## 催促间隔（秒）：小朋友半天没靠近就回头喊一声
const GUIDE_TIMEOUT := 180.0      ## 引路总时限（秒）：超了温柔放弃，别让它永远挂着
## 目标角色找不到的宽限（秒）：换完场景那一瞬 _spawn_server_character 还在异步降生，
## 此刻找不到人是正常的——没有宽限就会当场误判「他不在了」把引路作废。
const GUIDE_LOST_GRACE := 5.0
var _player_executor: BehaviorExecutor = null ## 玩家当前移动指令（新点击即替换）
var _approach: Dictionary = {}    ## 正在跑向的目标 NPC 字典（到旁边后进近身视图）
var _stopped: Dictionary = {}     ## 被叫停等玩家的 NPC 字典（退出交互恢复闲逛）
var world_id := ""

# M2-real 在线
var api: Api
var online := false
var _villager_count := 0          ## 村民散开序号（避免堆叠在中心）

# 音频 I/O（真机：麦克风采集 + TTS 播放）
var _tts_player: AudioStreamPlayer
# 流式 TTS：tts_chunk 分片先积压再按 generator 空位排空（_drain_tts_stream）
var _tts_stream_pcm := PackedByteArray()
var _tts_gen_playback: AudioStreamGeneratorPlayback = null
var _tts_ending := false  ## 已收到 tts_end：积压排空+缓冲播完后主动 stop（generator 不会自己停）
var _tts_gen_capacity := 0 ## generator 空缓冲容量（开播时实测，播完判定的基准）
## 流式 TTS 预缓冲：tts_start 后先攒够 TTS_PREBUFFER_SEC 秒 PCM 再 play()，避免服务端分片节奏
## 慢于播放导致 generator 缓冲欠载（声音出一点就卡再续，实测尤其见于 iOS 走服务端降级流时）。
const TTS_PREBUFFER_SEC := 0.4
var _tts_prebuffering := false ## true=已建 generator 但攒预缓冲中，尚未 play()
var _tts_prebuffer_bytes := 0  ## 起播阈值（按采样率算的 PCM16 单声道字节数）
# clientTts：edge-tts 本地合成（设计见 docs/edge-tts-client-design.md）
var edge_tts: EdgeTts
var _tts_pending := false ## 本地合成/降级请求进行中：视同「角色在说话」（闭麦/压 BGM/相机），防 300ms 空窗漏麦
var _tts_pending_deadline := 0.0 ## pending 兜底超时（降级也石沉大海时放开麦）
var _edge_reprobe_t := 0.0 ## edge 失败后的重探倒计时
@onready var _edge_env_off := OS.get_environment("MALIANG_EDGE_TTS") == "0" ## 回测隔离开关（进程级不变，缓存免每帧 getenv 系统调用）
const EDGE_REPROBE_SEC := 60.0

func _ready() -> void:
	critter_tex = load("res://assets/critter.png")
	stamp_seen = StampCeremony.load_seen()  # 上次见证到哪儿（欠盖的章等他开手机补演）
	_setup_environment()
	chunk_manager = ChunkManager.new()
	chunk_manager.name = "ChunkManager"
	add_child(chunk_manager)
	# 物品实体目录 + 打包默认矩阵：区块首铺/NPC 落位之前就位——离线也有完整世界
	# （树/建筑/占用全来自矩阵；在线时服务端矩阵与打包一致则 changed=false 零重铺）。
	ItemCatalog.ensure_builtin()
	_load_packaged_terrain()
	ItemCatalog.apply_static_occupancy()
	_setup_camera()
	_setup_npcs()
	_setup_player()
	_setup_fairy_offline()
	_setup_hud()
	# 哨兵对：括住整棵树的 _process 跨度（见 ProcProf 注释）
	add_child(ProcProf.Sentinel.make(true))
	add_child(ProcProf.Sentinel.make(false))
	# 画质档启动应用（节点已就绪：_sun / chunk_manager / _env）。档位从哪来见
	# GraphicsSettings：用户设置页 / 本机 benchmark / 后端按 GPU 下发；没定过档的新机器
	# 在移动端落保守起步档。这里不再做任何自适应定档——benchmark 只嵌在 intro 注魔幕里跑。
	_apply_saved_graphics()
	# 真机性能分解扫频（见 PerfSweep 注释；标记文件触发，跑完自动摘除）
	if OS.is_debug_build() and FileAccess.file_exists("user://perf_sweep"):
		Engine.max_fps = 0  # 扫频要真实帧时，解除 menu 设的移动端限帧
		add_child(PerfSweep.make(self, _env))
	_setup_backend()
	api = Api.new()
	api.name = "Api"
	add_child(api)
	_setup_audio()
	# 分流：intro 由上游（menu/onboarding）按 IntroDirector.should_run（无画质档 / 未看过建造演出）
	# 置 pending——显式开关，避免每个 headless 测试都误入 intro。画质定档也在这条路里（注魔幕）。见分流矩阵。
	if IntroDirector.pending:
		IntroDirector.pending = false # 消费掉：一次就够
		_intro_active = true
		_intro = IntroDirector.make(self)
		add_child(_intro) # 编排器 _ready 里早揭幕 + 后台 fetch + 建造演出 + 转正 apply + 标记 intro 已看过
	else:
		_bootstrap() # 在线引导（best-effort，离线则保留占位 NPC）
		_watch_world_ready() # 首屏铺完+引导结束→发 world_ready（loading.gd 据此淡出）

func _setup_audio() -> void:
	_tts_player = AudioStreamPlayer.new()
	add_child(_tts_player)
	edge_tts = EdgeTts.new()
	edge_tts.name = "EdgeTts"
	add_child(edge_tts) # 探活由 _step_edge_tts 首帧触发（available 初始 false）
	# 村民心愿漏话：必须建在 edge_tts 之后——它持有 edge_tts 引用，早建会拿到 null 且【静默不出声】。
	npc_wish_voice = NpcWishVoice.new()
	npc_wish_voice.name = "NpcWishVoice"
	npc_wish_voice.edge_tts = edge_tts # 复用同一个 edge-tts（共享探活与时钟纠偏）
	add_child(npc_wish_voice)
	# 村民主动社交调度：纯调度器，走位/出声由本场景按它返回的 action 执行（见 _update_npc_greetings）。
	npc_greeter = NpcGreeter.new()
	npc_greeter.name = "NpcGreeter"
	add_child(npc_greeter)
	game_audio = GameAudio.new()
	game_audio.name = "GameAudio"
	add_child(game_audio)
	game_audio.start_bgm() # 三段渐进 loop 轮换，随机起播（每次进世界大概率不同首）
	# 开放麦编排（内部持 MicRecorder+VoiceVad+端侧ASR；与 onboarding 共用同一模块）。
	# 门禁 should_capture、人声让位 is_speaking、识别 sink（信号）由本场景注入为宿主策略。
	_vc = VoiceCapture.new()
	_vc.name = "VoiceCapture"
	_vc.game_audio = game_audio
	_vc.os_name = _os_name
	_vc.debug_log = OS.is_debug_build() # 录音诊断 [vad] logcat：仅 debug 构建
	_vc.confirm_mode = PlayerProfile.confirm_voice() # 小龄玩家：说完先听一遍自己的话（手机设置里开）
	_vc.should_capture = _voice_should_capture
	_vc.is_speaking = func() -> bool: return _fsm_inputs().speaking()
	_vc.utterance_begin.connect(_on_capture_begin)
	_vc.committed.connect(_on_capture_committed)
	_vc.local_final.connect(_on_capture_local_final)
	_vc.cancelled.connect(_on_capture_cancelled)
	_vc.asr_ready.connect(_on_capture_ready)
	_vc.confirm_ready.connect(_on_capture_confirm_ready)
	add_child(_vc)
	if confirm_bar != null:
		confirm_bar.replay_pressed.connect(_vc.replay)
		confirm_bar.accept_pressed.connect(_vc.accept)
		confirm_bar.retry_pressed.connect(_vc.retry)
	# 端侧语音 e2e 注入 harness 的控制通道（docs/voice-e2e-harness-design.md §4.3）现改为 app 级 autoload
	# （[autoload] HarnessCmd = debug_cmd_server.gd），从 App 启动就常驻、跨 menu/onboarding/world——好让
	# onboarding 的语音流程也能 e2e。故这里不再 add_child（否则与 autoload 抢 8577）；debug 门禁搬进了它 _ready。

## 开放麦门禁（每帧）：端侧未就绪不喂（绝不上传）；喊话只走端侧；否则按 FSM mic_open。
## cooldown 已折进 FSM（COOLDOWN 态非 mic_open），退避倒计时在 _process 里推进。
func _voice_should_capture() -> bool:
	if _vc.must_wait_for_ready():
		return false
	# B3 起名子模式：端侧就绪即开麦，但点点问句（name_ask）播放期间先静音——
	# 无 AEC 的麦会把她的问句录回去被听成开口。她说完才放行（同 greeting 静音口径）。
	if not _naming_item.is_empty():
		return _vc.is_ready() and not (fairy_voice != null and fairy_voice.is_playing())
	var x := _fsm_inputs()
	if not _talk_pid.is_empty() and not _vc.is_ready():
		return false # 喊话靠端侧转写做文本中继：没有可用识别就别开麦
	return InteractionFsm.mic_open(InteractionFsm.derive(x))

func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	_sun = light
	light.rotation_degrees = Vector3(-55.0, -40.0, 0.0)
	light.light_color = Color(1.0, 0.94, 0.80) # 暖阳（比旧值更暖：与冷环境光拉开色相分离）
	light.light_energy = 1.45
	# 贴片影方向唯一从这盏光推导：照射方向(-Z 轴)的水平投影 = 影子拖向的背光侧方向，
	# 写进 BlobShadow 供散布/建筑影用，保证影方向与场景明暗同一个太阳（不会两套方向打架）。
	var sun_fwd := -light.basis.z
	BlobShadow.sun_ground_dir = Vector3(sun_fwd.x, 0.0, sun_fwd.z).normalized()
	# 实时定向阴影：老移动 GPU（Mali-G76 实测）一开整帧 ~2.5 倍开销（7↔18fps），且与
	# 投影几何量/软硬过滤/阴影图尺寸都无关——是阴影管线本身的代价，故全场景默认平光、
	# 靠 BlobShadow 脚下暗斑承担锚定感。CHARACTER_SHADOWS 实验：只给会动的角色投实时
	# 阴影（地面/建筑/散布/水全设不投，shadow pass 只重画几张角色 billboard），把开销
	# 压到最小、看真机是否划算；开则角色脚下暗斑让位真实投影。
	light.shadow_enabled = CHARACTER_SHADOWS       # 默认档；画质设置启动恢复会 override（见 _apply_graphics_key）
	light.directional_shadow_max_distance = 45.0   # 总设：运行时开阴影即生效（只近处进 shadow pass）
	BlobShadow.suppress_actor_blob = CHARACTER_SHADOWS
	# 手机层不吃太阳：手机 shaded 纸面由自带灯照（挂相机随视角走，方向恒定），
	# 太阳方向随相机环绕相对变化，照上去会忽明忽暗（PaperPhone.attach_light_rig）。
	light.light_cull_mask &= ~PaperPhone.RENDER_LAYER
	add_child(light)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = _make_day_sky()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# 冷调环境光（Pokopia 式色相分离）：背光面/暗部只吃环境光，偏蓝紫的冷调让
	# 暗部与暖阳亮部拉开色相而非单纯压暗——老 Mali 不开 shadow pass 也能有「影子感」。
	env.ambient_light_color = Color(0.62, 0.70, 0.92)
	env.ambient_light_energy = 0.64
	# 深度雾：远处地面渐隐到天空地平线色 → chunk 边界雾化进天空、自然无限地平线
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = SKY_HORIZON_COLOR
	env.fog_light_energy = 1.0
	env.fog_depth_begin = FOG_DEPTH_BEGIN
	env.fog_depth_end = FOG_DEPTH_END
	env.fog_depth_curve = 1.0
	# 深度雾默认对天空满强度（sky 在无穷远 = 雾最浓），会把整个渐变/云抹平回雾色；
	# 关掉它，天空自己在 shader 里用 horizon_color 与雾带衔接。
	env.fog_sky_affect = 0.0
	we.environment = env
	add_child(we)
	_env = env

## hi_res 各级对应的 3D 渲染缩放（下标 = level）：0 省电 / 1 标准 / 2 高清（原生）。
const HI_RES_SCALES := [0.6, 0.7, 1.0]

## 幂等应用单个画质旋钮到某一级（设置页、启动恢复、benchmark 试档三处共用）。self 就是
## world，直接够到太阳灯 / chunk_manager / 环境。键定义与级数见 GraphicsSettings。
func _apply_graphics_key(key: String, lv: int) -> void:
	var on := lv > 0  # 2 级旋钮：0 关 1 开
	match key:
		"actor_shadows":  # 角色实时定向阴影 ↔ 脚下暗斑
			if _sun != null:
				_sun.shadow_enabled = on
			BlobShadow.suppress_actor_blob = on
			for c in get_tree().get_nodes_in_group("paper_chars"):
				if c.has_method("refresh_ground_shadow"):
					c.refresh_ground_shadow()  # 已在场角色立即挂/摘 blob
		"ground_shadows":  # 地面斜阳椭圆贴片影（树/灌木/建筑）
			chunk_manager.set_ground_shadows(on)
		"hi_res":  # 3D 渲染分辨率（HUD/UI 走 canvas，恒原生）
			get_viewport().scaling_3d_scale = HI_RES_SCALES[GraphicsSettings.clamp_level(key, lv)]
		"fog":  # 深度雾
			if _env != null:
				_env.fog_enabled = on
		"outline":  # SDF 物件描边 pass（inverted-hull，每物件画两遍）
			SdfProp.set_outline_enabled(on, get_tree())
		"prop_anim":  # 会动的 SDF 物件显/隐
			chunk_manager.set_props_shown(on)
		"prop_detail":  # SDF 顶点吸附迭代：精细 4/4，粗略 2/1（物件边缘锐利度）
			SdfProp.set_snap_iters(4 if on else 2, 4 if on else 1, get_tree())
		"terrain_detail":  # 地形/水面第二层错速贴图采样
			chunk_manager.set_terrain_low_detail(not on)
		"xray":  # 角色被遮挡时的 X 光穿透剪影（每角色每帧一个全 quad 深度采样）
			PaperCharacter.set_xray_enabled(on, get_tree())
		"papercraft":  # 纸艺风（样式键）：物品全量活材质 + 地形/水面记忆态 + SDF 造物
			BendMat.set_papercraft(on)  # 先切物品并解析调试强制位
			chunk_manager.set_papercraft(BendMat.papercraft_on())
			SdfProp.set_papercraft(BendMat.papercraft_on(), get_tree())

## 应用当前画质档到场景 + 同步设置页控件（启动、恢复自动、backend 下发三处共用）。
## 定过档（用户/benchmark/backend）就按档应用；没定过档 = 新机器，benchmark 还没跑，
## 移动端先落保守起步档（清晰度取标准 0.7，别让首帧就卡），桌面全最高。
func _apply_saved_graphics() -> void:
	var g := GraphicsSettings.load_all()
	if not GraphicsSettings.has_saved() and OS.has_feature("mobile"):
		g["hi_res"] = 1
	_gfx_levels = g
	for key: String in GraphicsSettings.all_keys():
		_apply_graphics_key(key, int(g[key]))
		if phone_ui != null:
			phone_ui.refresh_gfx_button(key)  # 设置页可能还没建 → null 兜底

## 设置页画质旋钮改档：即时应用到场景 + 把当前全部旋钮档存进 profile（source=user，
## 从此不再被 backend 下发覆盖，除非用户点「恢复自动」）。
func _on_graphics_level_changed(key: String, lv: int) -> void:
	_apply_graphics_key(key, lv)
	_gfx_levels[key] = GraphicsSettings.clamp_level(key, lv)
	GraphicsSettings.save_all(_gfx_levels, "user")

## 设置页点一下画质旋钮：升到下一档，到顶回最省（2 级旋钮就是开 ↔ 关）。
## toggled 传来的 on 无意义（按钮的按下态由当前档反推，见 _refresh_gfx_button）。
func _on_graphics_cycle(_on: bool, key: String) -> void:
	var next := (int(_gfx_levels.get(key, 0)) + 1) % int(GraphicsSettings.LEVELS[key])
	_on_graphics_level_changed(key, next)
	if phone_ui != null:
		phone_ui.refresh_gfx_button(key)

## 设置页「恢复自动画质」：清掉用户 override，本次会话立刻回到未定档的默认，
## 下次启动会重新查 backend（命中同 GPU 的众包档）或跑 benchmark。
func _on_gfx_restore_auto() -> void:
	GraphicsSettings.clear()
	_apply_saved_graphics()

## 设置页「重新检测画质」：丢掉现有档（含用户 override），重进世界走首启故事路跑一次 benchmark 定档。
## 换了系统版本、机器发烫、或孩子觉得卡了都可以重来一次。清了画质档后 should_run 自然为真——benchmark
## 已经只嵌在 intro 注魔幕里，所以这里置 IntroDirector.pending（返回用户 intro_seen=true → 跳教学、只演建造+定档）。
func _on_gfx_rebench() -> void:
	GraphicsSettings.clear()
	IntroDirector.pending = true
	Loading.next_scene = "res://main.tscn"
	get_tree().change_scene_to_file("res://loading.tscn")

## 白天动态天空：渐变 + 卡通云漂移 + 太阳光晕（shaders/sky_day.gdshader）。
## ambient 走纯色源不依赖天空 radiance，radiance 取最小档 + 仅材质变更时重烘
## （REALTIME 档强制 256 且逐帧重烘，安卓平板不划算；本世界高粗糙度+关高光，反射用不上）。
## 云漂移相位步进（0.25s 一步，视觉无感）：sky shader 不用 TIME（会触发 radiance
## 逐帧重烘，见 sky_day.gdshader 头注释），由这里按材质 wind 参数积分 cloud_offset
## ——wind 从材质读而非常量，QA 用 WIND_X 放大风速的截帧脚本仍然生效。
const SKY_STEP := 0.25
var _sky_step_t := 0.0
var _sky_offset := Vector2.ZERO

func _step_sky(delta: float) -> void:
	_sky_step_t += delta
	if _sky_step_t < SKY_STEP:
		return
	var m := _env.sky.sky_material as ShaderMaterial
	_sky_offset += (m.get_shader_parameter("wind") as Vector2) * _sky_step_t
	m.set_shader_parameter("cloud_offset", _sky_offset)
	_sky_step_t = 0.0

func _make_day_sky() -> Sky:
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = 0.008
	var cloud_tex := NoiseTexture2D.new()
	cloud_tex.seamless = true
	cloud_tex.width = 256
	cloud_tex.height = 256
	cloud_tex.noise = noise
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/sky_day.gdshader")
	mat.set_shader_parameter("cloud_tex", cloud_tex)
	mat.set_shader_parameter("horizon_color", SKY_HORIZON_COLOR)
	mat.set_shader_parameter("zenith_color", SKY_ZENITH_COLOR)
	mat.set_shader_parameter("wind", SKY_WIND)
	var sky := Sky.new()
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	return sky

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 50.0
	camera.keep_aspect = Camera3D.KEEP_HEIGHT # fov 恒为竖直视角：对话构图按竖直 FOV 反算距离，横屏/竖屏一致
	camera.far = 900.0
	add_child(camera)
	_update_camera()

## 相机固定在渲染原点上方、看向原点；平移靠改 focus_logical（世界相对滚动），
## 角度(pitch)/距离(dist) 由 god/lock 目标缓动得到。
## 焦点随 focus 所在 tile 的台阶高度整体抬升（_cur_focus_y），否则上高阶地形后角色出画。
## 双指手势的临时偏移（_gest_*）叠加在基准之上：俯仰加偏移、距离乘倍率、绕焦点环绕 yaw。
func _update_camera() -> void:
	# 摄影机位覆盖（debug photo 命令）：拍 menu 相册时脚本直给 pitch/yaw/dist，绕过跟随/手势缓动。
	if not photo_cam.is_empty():
		var ppitch := deg_to_rad(float(photo_cam.get("pitch", 35.0)))
		var pdist := clampf(float(photo_cam.get("dist", 18.0)), DIALOG_ZOOM_MIN, ZOOM_MAX)
		var pfocus := Vector3(0.0, _cur_focus_y + float(photo_cam.get("lift", 0.0)), 0.0)
		var poffset := Vector3(0.0, sin(ppitch) * pdist, cos(ppitch) * pdist) \
			.rotated(Vector3.UP, float(photo_cam.get("yaw", 0.0)))
		camera.global_position = pfocus + poffset
		camera.look_at(pfocus, Vector3.UP)
		return
	var pitch := deg_to_rad(_cam_pitch_deg())
	# 对话态/手机近身态放开近距下限（贴近构图）；god 态仍守 ZOOM_MIN
	var zmin := DIALOG_ZOOM_MIN if (_locked != null or _phone_cam) else ZOOM_MIN
	var dist := clampf(_cur_dist * _gest_zoom, zmin, ZOOM_MAX)
	var focus := Vector3(0.0, _cur_focus_y, 0.0)
	var offset := Vector3(0.0, sin(pitch) * dist, cos(pitch) * dist).rotated(Vector3.UP, _gest_yaw)
	camera.global_position = focus + offset
	camera.look_at(focus, Vector3.UP)

## 相机当前实际俯仰角（度）：基准缓动值 + 手势偏移，与 _update_camera 用的是同一个数——
## 取景反算（compute_overview_cam）必须拿这个，不能拿 GOD_PITCH_DEG，否则手势抬头后取景就错了。
func _cam_pitch_deg() -> float:
	return clampf(_cur_pitch + _gest_pitch, GESTURE_PITCH_MIN, GESTURE_PITCH_MAX)

## 站桩侧（纯函数）：dx = shortest_delta(NPC→玩家).x，>0 玩家在 NPC 右侧、否则左侧（含 dx≈0 默认左）。
static func stage_side(dx: float) -> float:
	return 1.0 if dx > 0.0 else -1.0

## 玩家对话站位（纯函数）：站到 NPC 的进入侧、离 NPC STAGE_GAP 处（保持玩家从哪边来就站哪边）。
static func staged_logical(npc_l: Vector2, player_l: Vector2, gap: float) -> Vector2:
	var dx := WorldGrid.shortest_delta(npc_l, player_l).x
	return WorldGrid.wrap_pos(npc_l + Vector2(stage_side(dx) * gap, 0.0))

## 对话相机构图（纯函数，便于单测）：给定两人中点、当前说话方位置与双方立绘世界高度，
## 反算轨道距离与焦点。基础态（is_idle=思考/无人说话）取两人 max 高度占屏中间 50%、焦点居中；
## 说话态则朝说话方偏移焦点、并向「说话方单独占 50%」混一点距离——小体型（如仙子）单独构图
## 距离更近，天然 zoom 更多。dist 未夹 min，由 _update_camera 按对话态 DIALOG_ZOOM_MIN 收口。
static func compute_dialog_cam(center: Vector2, speaker_logical: Vector2, base_h: float,
		speaker_h: float, fov_deg: float, is_idle: bool) -> Dictionary:
	var tanhalf := tan(deg_to_rad(fov_deg * 0.5))
	# 高度 H 占屏比 FILL 时的轨道距离：可见世界高 = 2*d*tan(fov/2)，令 H/可见高 = FILL
	var base_dist := base_h / (2.0 * DIALOG_FILL * tanhalf)
	if is_idle:
		return { "want": center, "dist": base_dist, "lift": base_h * 0.5 }
	var seg := WorldGrid.shortest_delta(center, speaker_logical)
	var want := WorldGrid.wrap_pos(center + seg * SPEAK_SHIFT)
	var indiv := speaker_h / (2.0 * DIALOG_FILL * tanhalf) # 说话方单独占 50% 的距离
	var dist := lerpf(base_dist, indiv, SPEAK_ZOOM_BLEND)
	var lift := lerpf(base_h, speaker_h, SPEAK_SHIFT) * 0.5 # 焦点竖直居中随偏移比例过渡
	return { "want": want, "dist": dist, "lift": lift }

## 对话中判定「谁在说话」：NPC 的 TTS 或（对仙子时）仙子语音在播 = npc；思考中 = idle（构图归中）；
## 其余（录音中 / 静待玩家开口）= player。焦点/距离据此朝对应角色偏移（见 _process 焦点块）。
func _dialog_speaker() -> String:
	if InteractionFsm.tts_speaking(_fsm_inputs()):
		return "npc"
	var fairy := _find_fairy()
	if not fairy.is_empty() and selected == fairy.get("node") \
			and fairy_voice != null and fairy_voice.is_playing():
		return "npc"
	if thinking_label.visible:
		return "idle"
	return "player"

## 用当前场景状态喂 compute_dialog_cam：两人中点、双方立绘高度、当前说话方。
func _dialog_camera() -> Dictionary:
	var np := _find_npc_dict(_locked)
	if np.is_empty():
		return { "want": player["logical"], "dist": _target_dist, "lift": 0.0 }
	var npc_l: Vector2 = np["logical"]
	var player_l: Vector2 = player["logical"]
	var npc_h := _char_top(_locked)
	var player_h := _char_top(player["node"] as PaperCharacter)
	var base_h := maxf(npc_h, player_h)
	var center := torus_midpoint(npc_l, player_l)
	var who := _dialog_speaker()
	var spk_l := npc_l if who == "npc" else player_l
	var spk_h := npc_h if who == "npc" else player_h
	return compute_dialog_cam(center, spk_l, base_h, spk_h, camera.fov, who == "idle")

## 站位落点可通行判定：该 logical 处玩家 footprint（PLAYER_SPAN）是否空闲（物件/建筑+角色层，
## 排除玩家自己）。与寻路 Pathfinder.cell_free 同源，建筑经 OccupancyMap 登记故能挡住。
func _stage_cell_free(pos: Vector2) -> bool:
	return Pathfinder.cell_free(OccupancyMap.to_cell(pos), PLAYER_SPAN, PLAYER_ID)

## 选站位：首选进入侧（NPC±STAGE_GAP）；被占则改站对侧；两侧都站不下返回玩家当前到位点（不跳）。
func _pick_stage_target(npc_l: Vector2, player_l: Vector2) -> Vector2:
	var pref := staged_logical(npc_l, player_l, STAGE_GAP)
	if _stage_cell_free(pref):
		return pref
	var dx := WorldGrid.shortest_delta(npc_l, player_l).x
	var other := WorldGrid.wrap_pos(npc_l + Vector2(-stage_side(dx) * STAGE_GAP, 0.0))
	if _stage_cell_free(other):
		return other
	return player_l # 两侧都被挡：留在已可达的到位点，绝不跳进不可通行处

## 玩家跳向对话站位：横向按最短环面向量缓入插值、竖直叠加 sin 弧线小跳；落地登记占用。
## 小跳期间 _update_paper_motion 走 _hop 分支（不按位移换面/摇摆，保持进对话设定的相对朝向）。
func _step_hop(delta: float) -> void:
	if _hop_t < 0.0 or player.is_empty():
		return
	_hop_t += delta
	var k := clampf(_hop_t / STAGE_HOP_DUR, 0.0, 1.0)
	var seg := WorldGrid.shortest_delta(_hop_from, _stage_player_logical)
	player["logical"] = WorldGrid.wrap_pos(_hop_from + seg * smoothstep(0.0, 1.0, k))
	player["hover"] = STAGE_HOP_HEIGHT * sin(k * PI)
	if k >= 1.0:
		player["logical"] = _stage_player_logical
		# 落定当帧把 paper_prev 对齐到落点：清零残余位移速度，避免 _update_paper_motion
		# 用小跳末速度把玩家翻成"朝行进方向"（长跳跨到对侧时会背对 NPC，即"方向反了"）
		player["paper_prev"] = _stage_player_logical
		player.erase("hover")
		player.erase("_hop")
		_hop_t = -1.0
		OccupancyMap.char_register(PLAYER_ID, _stage_player_logical, PLAYER_SPAN)

## 离线/intro 的 demo 村民：用打包的 seed 村民图集（VillagerAssets）以 idle 动画降生，
## 不再是染色 critter 静态占位。id 用 demo_<slug>（demo_ 前缀 → _LOCAL_ONLY_IDS 本地专属、
## 绝不上报）；转正（在线 bootstrap）时清掉、换成服务端村民（同款 seed 则视觉无缝，见设计 D2）。
func _setup_npcs() -> void:
	var positions := [Vector2(10.0, -10.0), Vector2(-11.0, -9.0), Vector2(1.0, -18.0)]
	var seed: Array = VillagerAssets.SEED
	for i in range(positions.size()):
		var v: Dictionary = seed[i % seed.size()]
		var npc := PaperCharacter.new()
		add_child(npc)
		# 先用 critter 占位跑通 setup（内部归一尺寸 + 挂脚下暗斑），再切村民图集动画。
		# 图集加载失败（理论上不会）则保留占位，不崩。
		npc.setup(critter_tex, Color.WHITE, String(v["name"]))
		var atlas := load(String(v["atlas"])) as Texture2D
		if atlas != null:
			# 相位按序错开，避免三只同帧起跳的机械感（31帧/8fps ≈ 3.9s 循环），与 _spawn_server_character 一致
			var phase := float(i) / float(positions.size()) * 3.9
			npc.play_anim(atlas, v["meta"], VillagerAssets.WORLD_HEIGHT, phase)
		var lg := WorldGrid.wrap_pos(positions[i])
		var did := "demo_%s" % String(v["slug"])
		npcs.append({ "node": npc, "logical": lg, "id": did })
		OccupancyMap.char_register(did, lg, 2)
		_start_ambient_wander(npcs[npcs.size() - 1])

## 让角色自主活动：循环「等一会 → 就近 wander」。
func _start_ambient_wander(npc_dict: Dictionary) -> void:
	if npc_dict.get("replicated", false):
		return # 被 host 复制驱动的 NPC：本端不自主闲逛（位置来自复制流）
	var ex := BehaviorExecutor.new()
	ex.setup(npc_dict, {
		"commands": [
			{ "type": "wait", "params": { "duration": randf_range(1.0, 3.5) } },
			{ "type": "wander", "params": { "radius": 7.0 } },
		],
		"loop": true,
	})
	ex.ambient = true  # 自主闲逛：不算脚本任务，「主动看你」可在其上叠加打招呼
	_executors.append(ex)

## 玩家角色：称呼来自 onboarding 档案；先占位形象（粉色 critter），
## 在线后由 _apply_player_sprite 换成档案里生成的形象。
func _setup_player() -> void:
	var node := PaperCharacter.new()
	add_child(node)
	var prof := PlayerProfile.load_profile()
	var pname := String(prof.get("nickname", ""))
	if pname.is_empty():
		pname = String(prof.get("name", ""))
	if pname.is_empty():
		pname = "我"
	node.setup(critter_tex, Color(1.0, 0.74, 0.80), pname)
	var spawn := _find_free_spot(focus_logical, PLAYER_SPAN)
	player = { "node": node, "logical": spawn, "id": PLAYER_ID, "span": PLAYER_SPAN }
	OccupancyMap.char_register(PLAYER_ID, spawn, PLAYER_SPAN)

## 档案里有生成形象时，从服务端拉取替换占位（离线/失败静默保留占位）。
## 锚点(贴纸附着位)随档案一起下发：造角色时服务端 /player-sprite 返回体带 anchors、客户端存档
## （见 onboarding/phone_ui），这里读出灌进玩家节点。老档案缺 anchors 时按 hash 现算一次补回。
func _apply_player_sprite() -> void:
	if player.is_empty():
		return
	var prof := PlayerProfile.load_profile()
	var asset := String(prof.get("sprite_asset", ""))
	var a: Variant = prof.get("anchors")
	var anchors: Dictionary = a if typeof(a) == TYPE_DICTIONARY else {}
	# 传入 _my_attachments：真立绘就位后按正确尺寸重挂贴纸（换形象/首次上线都走这条）。
	_apply_player_sprite_to(player["node"] as PaperCharacter, asset, anchors, _my_attachments)
	# 老档案（本次修复前造的角色）只有 sprite_asset 没有 anchors：按 hash 现算一次并落档（设计 §2.3）。
	if not asset.is_empty() and anchors.is_empty():
		_backfill_player_anchors(asset)

## 老档案锚点补算（设计 §2.3）：服务端按 spriteAsset 现算 anchors → 存回设备档案 + 灌进玩家节点。
## fire-and-forget、失败静默（离线/404 就继续走客户端 alpha 兜底）。
func _backfill_player_anchors(asset: String) -> void:
	var res: Dictionary = await api.post_json("/player-sprite/anchors", { "spriteAsset": asset })
	var got: Variant = res.get("anchors")
	if typeof(got) != TYPE_DICTIONARY or (got as Dictionary).is_empty():
		return
	var prof := PlayerProfile.load_profile()
	if String(prof.get("sprite_asset", "")) != asset:
		return # 期间玩家换了形象，别用旧 hash 的锚点覆盖新形象
	prof["anchors"] = got
	PlayerProfile.save_profile(prof)
	if not player.is_empty() and is_instance_valid(player["node"]):
		(player["node"] as PaperCharacter).set_anchors(got)

## 把某张玩家立绘应用到一个 PaperCharacter：本地玩家与远端玩家共用同一套归一化与 idle 轮询，
## 别人看到的我 = 我看到的我。node 可能中途被销毁（换场景/离场），每步 is_instance_valid 守卫。
## fire-and-forget 调用（不 await）：跑到首个 await 就返回，图到了再替换占位。
## anchors 可选：本地玩家从设备档案传入（真·vision 锚点）；远端玩家副本无档案、留空走 alpha 兜底。
func _apply_player_sprite_to(node: PaperCharacter, asset: String, anchors := {}, attachments := []) -> void:
	if is_instance_valid(node) and not anchors.is_empty():
		node.set_anchors(anchors) # 锚点与贴图解耦：先灌（离线/图未到也生效），贴纸后到自动重摆
	if asset.is_empty() or not is_instance_valid(node):
		return
	var tex := await api.fetch_texture(asset)
	if tex == null or not is_instance_valid(node):
		return
	node.texture = tex
	# 生成图按高度归一化到 5 单位（小朋友比 6 单位的村民略矮），脚底对齐
	node.pixel_size = 5.0 / float(tex.get_height())
	node.offset = Vector2(0.0, float(tex.get_height()) / 2.0)
	node.modulate = Color.WHITE
	BlobShadow.attach(node, clampf(float(tex.get_width()) * node.pixel_size * 0.38, 0.4, 1.4))
	# 立绘尺寸已定：按正确尺寸挂上身上的贴纸（自己=_my_attachments，远端=presence.attachments）。
	if not attachments.is_empty():
		_apply_attachments_list(node, attachments)
	# 试点：玩家形象静态就位后，后台轮询 idle 动画，就绪则静态切动画（世界高度保持 5 单位）
	_poll_idle_anim(node, asset, 5.0, 0.0)

## 试点：拿到静态立绘后后台轮询 idle 动画，就绪则把该 PaperCharacter 从静态切成动画播放。
## world_height 与静态一致（观感不跳）。node 可能中途被销毁，每步 is_instance_valid 守卫。
## fire-and-forget 调用（不 await）：跑到首个 await 就返回，后续在信号上续跑。
func _poll_idle_anim(node: PaperCharacter, sprite_hash: String, world_height: float, phase: float) -> void:
	if sprite_hash.is_empty():
		return
	# 退避轮询：3→6→12s 封顶，总窗 ~2 分钟（覆盖视频生成 60~90s + 排队）。
	# 旧版固定 3s×40：N 个角色 = N 条并发轮询，进世界头 2 分钟射频持续唤醒（平板发热）。
	var wait := 3.0
	var budget := 120.0
	while true:
		if not is_instance_valid(node):
			return
		var rec := await api.fetch_sprite_anim(sprite_hash)
		var status := String(rec.get("status", "none"))
		if status == "ready":
			var meta: Dictionary = rec.get("meta", {})
			var atlas := await api.fetch_texture(String(rec.get("animAsset", "")), true) # 图集走显存块压缩
			if atlas != null and is_instance_valid(node):
				node.play_anim(atlas, meta, world_height, phase)
			return
		if status == "failed":
			return
		if budget <= 0.0:
			return
		await get_tree().create_timer(wait).timeout
		budget -= wait
		wait = minf(wait * 2.0, 12.0)

## 离线模式的点点随从（在线时 _bootstrap 会清掉、换成服务端下发的点点）。
## 悬浮飞行：不登记占用图、不走寻路，由 _update_fairy 驱动跟随玩家。
func _setup_fairy_offline() -> void:
	var tex: Texture2D = load("res://assets/fairy.png")
	var node := PaperCharacter.new()
	add_child(node)
	node.setup(tex, Color.WHITE, FAIRY_NAME)
	node.pixel_size = FAIRY_HEIGHT / float(tex.get_height())
	BlobShadow.detach(node) # 悬浮飞行不落地，脚下暗斑穿帮
	node.wants_ground_shadow = false  # 切「角色实时阴影」刷新时别给悬浮角色挂脚下 blob
	var spawn := WorldGrid.wrap_pos(player["logical"] + Vector2(3.0, 2.0))
	npcs.append({ "node": node, "logical": spawn, "id": "fairy_local", "is_fairy": true, "hover": FAIRY_HOVER })
	fairy_voice = FairyVoice.new()
	fairy_voice.name = "FairyVoice"
	add_child(fairy_voice)
	story_voice = StoryVoice.new()
	story_voice.name = "StoryVoice"
	add_child(story_voice)
	_fairy_bubble = UiAssets.bubble_sprite("ic_note", 1.4)
	add_child(_fairy_bubble)

## 小仙子随从每帧驱动：悬浮漂移跟在玩家旁（玩家跑动时拖尾追赶，静止时缓慢环绕），
## 轻微上下浮动。永远由这里驱动，不吃行为脚本（见 _run_behavior）。
func _update_fairy(delta: float) -> void:
	if _bench_freeze:
		return # benchmark 采样期：仙子凝神注魔定格（不飘、不聊、不追随），保持负载恒定
	var fairy := _find_fairy()
	if fairy.is_empty() or player.is_empty():
		return
	_fairy_drift_t += delta
	var target: Vector2
	var speed_min := 1.2
	# 对话优先于 POI 提醒：小朋友正在跟她说话时，她必须停在原地听（缺陷 ③）。
	# 仙子的位移直接改 fairy["logical"]、不走行为脚本，_halt_npc 取消执行器拦不住她，
	# 所以只能在这里把「对话中」这一支提到 POI 之前。
	# 顺手丢弃进行中的 POI：那个提醒点是进对话前算的，聊完早已过时；触发词未被 try_play 消耗，
	# 离开对话后 _check_poi 会按当时位置重新提醒。
	if selected == fairy.get("node"):
		_fairy_poi = {}
		target = fairy["logical"] # 对话中：停在原地听小朋友说话（仍轻微浮动）
	elif not _fairy_guide.is_empty():
		# 引路优先于 POI 提醒：正在带小朋友去某处时，别再被路边的风车勾走注意力。
		target = _step_fairy_guide(delta, fairy)
		speed_min = 10.0 # 领飞：稳稳往前带，比闲逛果断
	elif not _fairy_poi.is_empty():
		target = _fairy_poi["point"]
		speed_min = 14.0 # 提醒飞行：果断飞过去
		_step_fairy_poi(delta, fairy, target)
	else:
		var drift := Vector2(cos(_fairy_drift_t * 0.6), sin(_fairy_drift_t * 0.45)) * 1.8
		target = WorldGrid.wrap_pos(player["logical"] + Vector2(2.6, 1.8) + drift)
	var d := WorldGrid.shortest_delta(fairy["logical"], target)
	var speed := clampf(d.length() * 2.0, speed_min, 26.0) # 越远追得越快
	var step := d.normalized() * minf(speed * delta, d.length())
	fairy["logical"] = WorldGrid.wrap_pos(fairy["logical"] + step)
	fairy["hover"] = FAIRY_HOVER + sin(_fairy_drift_t * 2.2) * 0.3
	# intro 建造演出期间点点的嗓子归 IntroNarrator 独占：她照常飘（上面已更新位置），但不闲聊、不扫 POI——
	# 否则 greet/guide_hint/idle 会压在编排旁白上，两个音源叠着孩子一句听不清（Bug①）。
	if _intro_active:
		return
	if not _fairy_guide.is_empty():
		_update_fairy_bubble(fairy) # 引路中：挂气泡，但不闲聊、不扫 POI（别在带路途中被风车勾走）
	elif _fairy_poi.is_empty():
		_fairy_ambient(delta, fairy)
	else:
		_update_fairy_bubble(fairy) # 飞行提醒中也要挂音符气泡
	if _fairy_guide.is_empty():
		_check_poi(delta)

## POI 提醒推进：到位后说台词，说完稍作停留再回到玩家身边。
func _step_fairy_poi(delta: float, fairy: Dictionary, target: Vector2) -> void:
	if WorldGrid.shortest_delta(fairy["logical"], target).length() > 1.0:
		return
	if not _fairy_poi.get("spoke", false):
		fairy_voice.try_play(_fairy_poi["trigger"])
		_fairy_poi["spoke"] = true
		_fairy_poi["hold"] = 2.0
		return
	if not fairy_voice.is_playing():
		_fairy_poi["hold"] = float(_fairy_poi["hold"]) - delta
		if float(_fairy_poi["hold"]) <= 0.0:
			_fairy_poi = {}

# ── 引路（fairy-guide）────────────────────────────────────────────────────────
# 她飞在前面领、小朋友自己走。不碰 BehaviorExecutor（她根本不吃移动脚本），也不动玩家的 avatar
# （那是 stage 的 _stage_drive 才做的事，代价是吞掉输入——幼儿产品不能这么干）。
# 设计与取舍见 docs/fairy-guide-design.md。

## 开始引路：服务端 guide_to 算好的计划下来了。新计划覆盖旧的。
func start_guide(plan: Dictionary) -> void:
	if plan.is_empty():
		return
	_fairy_guide = { "plan": plan, "leg": 0, "nudge_t": GUIDE_NUDGE_INTERVAL, "elapsed": 0.0 }
	_guide_used = true # 他已经会用了：闲聊里不必再提示「我可以带你去」
	_fairy_poi = {} # 引路开始：丢弃进行中的 POI 提醒，别抢她
	_sync_guide_button()

## 「不去了」按钮：客户端侧的取消入口（与语音 guide_stop 双保险，老板 2026-07-13）。
func _on_guide_stop_pressed() -> void:
	end_guide("guide_cancel")

## 按钮只在【引路中且不在对话里】露面：对话有自己的一整套 UI，别在上面再压一个按钮。
## 退出对话时引路继续（它只是挂起，不是取消），按钮也跟着回来。
func _sync_guide_button() -> void:
	if guide_stop_button != null:
		guide_stop_button.visible = not _fairy_guide.is_empty() and selected == null

## 结束引路。trigger 非空则播一句对应的预制台词（到达/取消/超时各有词）。
func end_guide(trigger: String = "") -> void:
	if _fairy_guide.is_empty():
		return
	_fairy_guide = {}
	_sync_guide_button()
	if not trigger.is_empty() and fairy_voice != null:
		fairy_voice.try_play(trigger)

## 换场景落地时推进引路（跨场景引路：她把小朋友带到门口，他自己走进去，到那边接着带）。
## 引路计划是 world.gd 的成员，_unload_scene 不碰它——它天然活过场景切换，这里只推进段号。
func _guide_on_scene_entered(sid: String) -> void:
	if _fairy_guide.is_empty():
		return
	var plan: Dictionary = _fairy_guide["plan"]
	var legs: Array = plan.get("legs", [])
	var leg := int(_fairy_guide.get("leg", 0))
	# 正常推进：走的就是计划里的那道门
	if leg < legs.size() and String((legs[leg] as Dictionary).get("toScene", "")) == sid:
		_fairy_guide["leg"] = leg + 1
		_fairy_guide["nudge_t"] = GUIDE_NUDGE_INTERVAL
		_fairy_guide.erase("last_gap")
		return
	# 抄了近路直达目标场景（孩子自己走了别的门）：不作废，直接领向最终目标
	if sid == String(plan.get("targetScene", "")):
		_fairy_guide["leg"] = legs.size()
		_fairy_guide["nudge_t"] = GUIDE_NUDGE_INTERVAL
		_fairy_guide.erase("last_gap")
		return
	# 走进了计划外的门：引路作废——在错的场景里继续领只会把他带得更偏
	end_guide("guide_cancel")

## 要找的人是否已经不在场了。只在【走完所有 portal 段、人应该就在眼前】时才算数——
## 还在赶路的中途，目标本来就不在当前场景，找不到是理所当然的。
func _guide_target_lost() -> bool:
	var plan: Dictionary = _fairy_guide["plan"]
	if String(plan.get("targetKind", "")) != "character":
		return false
	var legs: Array = plan.get("legs", [])
	if int(_fairy_guide.get("leg", 0)) < legs.size():
		return false
	return _resolve_char_pos(String(plan.get("targetName", ""))) == Vector2.INF

## 当前路点：还有没走完的 portal 段就先去那道门；否则就是最终目标。
## 目标是角色时按【名字实时重解析】——村民自己会走动，下发时的坐标快照早过时了（老板拍板：不钉住他）。
func _guide_waypoint() -> Vector2:
	var plan: Dictionary = _fairy_guide["plan"]
	var legs: Array = plan.get("legs", [])
	var leg := int(_fairy_guide.get("leg", 0))
	if leg < legs.size():
		var portal: Dictionary = legs[leg]
		return TerrainMap.tile_center(_tile_of(portal.get("portalTile", {})))
	if String(plan.get("targetKind", "")) == "character":
		var live := _resolve_char_pos(String(plan.get("targetName", "")))
		if live != Vector2.INF:
			return live
	return TerrainMap.tile_center(_tile_of(plan.get("targetTile", {})))

## 服务端下发的 TilePos {tileX, tileY} → Vector2i。
func _tile_of(t: Variant) -> Vector2i:
	if typeof(t) != TYPE_DICTIONARY:
		return Vector2i.ZERO
	var d: Dictionary = t
	return Vector2i(int(d.get("tileX", 0)), int(d.get("tileY", 0)))

## 引路每帧推进，返回小仙子这一帧该飞向的点。
func _step_fairy_guide(delta: float, fairy: Dictionary) -> Vector2:
	_fairy_guide["elapsed"] = float(_fairy_guide.get("elapsed", 0.0)) + delta
	if float(_fairy_guide["elapsed"]) > GUIDE_TIMEOUT:
		end_guide("guide_timeout") # 走太久了：温柔放弃，别永远挂着
		return fairy["logical"]

	# 要找的人中途没了（他自己走了传送门 / 被删）：宽限一会儿还找不到就作废——
	# 别一直领着小朋友走向一个空坐标，走到了还说「到啦」，那儿却没有人。
	if _guide_target_lost():
		_fairy_guide["lost_t"] = float(_fairy_guide.get("lost_t", 0.0)) + delta
		if float(_fairy_guide["lost_t"]) > GUIDE_LOST_GRACE:
			end_guide("guide_cancel")
			return fairy["logical"]
	else:
		_fairy_guide["lost_t"] = 0.0

	var waypoint := _guide_waypoint()
	var to_wp := WorldGrid.shortest_delta(player["logical"], waypoint)
	if to_wp.length() <= GUIDE_ARRIVE_DIST:
		return _guide_reach_waypoint(fairy)

	# 领飞：站在玩家→路点的方向上，但离玩家不超过 GUIDE_FLY_CAP——她得始终在小朋友视野里。
	var lead := to_wp.normalized() * minf(to_wp.length(), GUIDE_FLY_CAP)
	# 催促：小朋友半天没缩短与路点的距离（跑偏了/看别的去了）→ 回头喊一声。
	var gap := to_wp.length()
	var last_gap := float(_fairy_guide.get("last_gap", gap))
	_fairy_guide["nudge_t"] = float(_fairy_guide.get("nudge_t", GUIDE_NUDGE_INTERVAL)) - delta
	if float(_fairy_guide["nudge_t"]) <= 0.0:
		_fairy_guide["nudge_t"] = GUIDE_NUDGE_INTERVAL
		if gap >= last_gap - 1.0 and fairy_voice != null:
			fairy_voice.try_play("guide_nudge") # 没怎么靠近才催，正走着就别啰嗦
		_fairy_guide["last_gap"] = gap
	return WorldGrid.wrap_pos(player["logical"] + lead)

## 玩家走到了当前路点。portal 段：什么都不做——他自己走进半径，既有 _step_portal 会切场景，
## 引路在 enter_scene 里续上下一段（P3）。最终目标：到达收尾。
func _guide_reach_waypoint(fairy: Dictionary) -> Vector2:
	var plan: Dictionary = _fairy_guide["plan"]
	var legs: Array = plan.get("legs", [])
	if int(_fairy_guide.get("leg", 0)) < legs.size():
		return fairy["logical"] # 在门口悬停等他走进去
	end_guide("guide_arrive")
	return fairy["logical"]

## 周期扫描 POI：玩家进入发现半径且对应台词未冷却 → 小仙子朝 POI 方向飞（距玩家封顶，
## 保持在视野内）。交互/录音/思考/TTS 中不打扰。
func _check_poi(delta: float) -> void:
	if not _fairy_poi.is_empty() or fairy_voice == null:
		return
	if _fairy_napping:
		return # 睡着了不主动飞去指路标
	_poi_check_t -= delta
	if _poi_check_t > 0.0:
		return
	_poi_check_t = 2.0
	if InteractionFsm.player_engaged(_fsm_inputs()):
		return
	for poi in pois:
		var pp := TerrainMap.tile_center(poi["tile"])
		var dp := WorldGrid.shortest_delta(player["logical"], pp)
		if dp.length() <= float(poi["radius"]) and fairy_voice.can_play(String(poi["trigger"])):
			var fly := dp.normalized() * minf(dp.length(), POI_FLY_CAP)
			_fairy_poi = { "point": WorldGrid.wrap_pos(player["logical"] + fly),
				"trigger": String(poi["trigger"]), "spoke": false, "hold": 2.0 }
			return

## 氛围台词引擎：先问候，之后每 15~25s 按周围环境挑话题（水/山/村庄），没有就闲聊。
## 交互/录音/思考/正式 TTS 播放中一律闭嘴，避免叠声。
func _fairy_ambient(delta: float, fairy: Dictionary) -> void:
	if fairy_voice == null:
		return
	_update_fairy_bubble(fairy)
	if InteractionFsm.player_engaged(_fsm_inputs()):
		_fairy_idle_backoff = 0.0 # 孩子在互动 → 退避归零，回到灵敏状态
		_fairy_napping = false    # 孩子一动，点点就醒（能被叫停也能被叫醒）
		return
	if _fairy_napping:
		return # 睡着了：完全闭嘴，等孩子互动来唤醒
	# 村民正在漏话时仙子闭嘴（反向门禁在 NpcWishVoice.update 的 is_speaking 里）：
	# 两个声源叠在一起，小朋友一句也听不清，两边的话都白说了。
	if npc_wish_voice != null and npc_wish_voice.is_speaking():
		return
	_fairy_chat_t -= delta
	if _fairy_chat_t > 0.0:
		return
	_fairy_chat_t = randf_range(15.0, 25.0)
	if not _fairy_greeted:
		_fairy_greeted = fairy_voice.try_play("greet")
		return
	# 引路引导：小朋友不会自己想到「可以让她带路」，闲着时她主动提一句。
	# 只在【还没用过引路】时提——用过之后还一遍遍问「想去哪儿玩呀」就成了唠叨。
	if not _guide_used and fairy_voice.try_play("guide_hint"):
		return
	# B3 复用提示（§4.2）：背包旧物正好能用上当前需求 → 点点点一句（走 ambient，不占 _tts_player、
	# 同 wish-leak 门禁），说完就消费掉（只提一次）。台词是通用句（不含动态物名，因预制 WAV），
	# 顺手 pulse 一下册子按钮把注意力引到背包，孩子自己翻出来摆。
	if not _pending_reuse.is_empty() and fairy_voice.try_play("reuse_hint"):
		_pending_reuse = {}
		_pulse_album_button()
		return
	# 无人回应的 idle 闲话：说得出就把下次等待拉长（退避式，不定时轰炸）。
	if fairy_voice.try_play(_ambient_trigger()):
		_fairy_chat_t += _fairy_idle_backoff
		_fairy_idle_backoff = minf(_fairy_idle_backoff + FAIRY_IDLE_BACKOFF_STEP, FAIRY_IDLE_BACKOFF_MAX)

## 村民心愿漏话：服务端下发台词，模块自己按距离/冷却/全局间隔决定谁在什么时候嘟囔一句。
## 仙子正在说话时全员闭嘴（正向门禁在 _fairy_ambient 里）——两个声源叠着谁也听不清。
## intro 建造演出期间同理闭嘴：编排旁白(IntroNarrator)是另一路音源，村民漏话会压上去（Bug①）。
func _update_npc_wishes(delta: float) -> void:
	if npc_wish_voice == null or player.is_empty():
		return
	var engaged := _intro_active \
			or InteractionFsm.player_engaged(_fsm_inputs()) \
			or (fairy_voice != null and fairy_voice.is_playing())
	npc_wish_voice.update(delta, npcs, player["logical"], engaged)

## 村民主动社交：合格村民（性格×熟识度）主动走过来、停下、面向玩家打招呼。
## 纯调度在 NpcGreeter；本函数只做宿主侧的胶水：标注空闲/被抢标志，按返回的 action 驱动走位/面向/挥手。
## engaged 与漏话同门禁（玩家在交互/录音/听人说话时不迎上来）。P3 在 arrived 加出声，P4 加送花。
func _update_npc_greetings(delta: float) -> void:
	if npc_greeter == null or player.is_empty():
		return
	# 每帧标注两类宿主才知道的状态：
	#  greet_free  —— 可被【新】拉去迎接：没被选中/叫停、且没有执行器在驱动（含自主闲逛）。
	#  greet_hijack—— 活跃迎接者被【抢走】：玩家点它对话(selected) / 把它叫停(_stopped)。
	for n in npcs:
		if n.get("is_fairy", false):
			continue
		var node: Node = n.get("node")
		var hijacked: bool = n == _stopped or (selected != null and node == selected)
		n["greet_hijack"] = hijacked
		# 闲逛(ambient)不算忙——否则村民默认都在闲逛就永远没人能被拉去迎接；只有真任务执行器才算占用。
		n["greet_free"] = not (hijacked or _has_task_executor_for(n))
	var engaged := _intro_active \
			or InteractionFsm.player_engaged(_fsm_inputs()) \
			or (fairy_voice != null and fairy_voice.is_playing())
	var act := npc_greeter.update(delta, npcs, player["logical"], engaged)
	var kind := String(act.get("type", ""))
	if kind.is_empty():
		return
	var gd := _find_npc(String(act.get("cid", "")))
	if gd.is_empty():
		return
	match kind:
		"approach":
			# 复用 follow：跟移动中的玩家走过去，到 FOLLOW_NEAR(3.4) 自停并保持（见 behavior_executor）。
			_run_behavior(gd["node"] as PaperCharacter, { "commands": [{ "type": "follow", "params": { "target_name": "玩家" } }], "loop": false })
		"arrived":
			# 到玩家旁：面向玩家 + 挥手 + 头顶小表情。不取消 follow，靠它把村民钉在原地。
			var d := WorldGrid.shortest_delta(gd["logical"], player["logical"])
			gd["paper_face"] = 0.0 if d.x >= 0.0 else PI
			gd["paper_action"] = "wave"
			gd["paper_action_t"] = 0.0
			_pop_notice_bubble(gd)
			# 开口打招呼（P3）：请服务端给一句招呼词+音色，回来走村民身上的 3D 定位音（见 _on_villager_hail_tts）。
			if backend != null and not world_id.is_empty():
				backend.send_villager_hail(world_id, String(act.get("cid", "")))
				# 送花（P4，仅外向）：请服务端权威加花，回 wallet_update 再飞花庆祝（防刷/封顶在服务端）。
				if String(gd.get("social_type", "")) == "extrovert":
					backend.send_villager_gift(world_id, String(act.get("cid", "")))
		"release", "giveup":
			# 收尾：取消 follow（若还在）+ 恢复闲逛。
			for ex in _executors:
				if (ex as BehaviorExecutor).drives(gd):
					(ex as BehaviorExecutor).cancel()
			_resume_ambient(gd)

## 村民主动打招呼的招呼词回来了（P3）：让【这个村民】用自己音色就地说出来（3D 定位音，复用漏话音源）。
## 村民已不在（换场景/被删）或漏话模块未就绪则静默——招呼是点缀，丢了不影响。
func _on_villager_hail_tts(data: Dictionary) -> void:
	if npc_wish_voice == null:
		return
	var n := _find_npc(String(data.get("villagerId", "")))
	if n.is_empty():
		return
	npc_wish_voice.say_line(n, String(data.get("text", "")), String(data.get("voiceId", "")))

## 外向村民送花（P4）：钱包权威在服务端，这里只同步钱包 + 演飞花庆祝（复用委托奖励的爆点/飞花）。
## 送花村民头顶弹拉炮，一朵小红花从屏幕中心飞进手机按钮；村民已不在则跳过头顶爆点，钱包照样同步。
func _on_villager_gift(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet"))
	var gift: Dictionary = data.get("gift", {})
	var node := _find_npc_by_id(String(gift.get("villagerId", "")))
	if node != null:
		_spawn_burst(node)
	if game_audio != null:
		game_audio.play_sfx("enter")
	_fly_reward_to_album("reward_flower")

## 服务端下发的漏话候选（进世界/换场景/发现新玩法后重发）：整份替换，旧台词立即作废。
## discovered 是【持久】口径：_guide_used 本来只记「本次进世界」，重启就忘——
## 那样小朋友明明早会用引路了，仙子重启后还在念叨，「已发现的不再提」就成了空话。
func _on_npc_wishes(wishes: Array, discovered: Array, reuse_hint: Variant) -> void:
	if npc_wish_voice != null:
		npc_wish_voice.set_wishes(wishes)
	# A4 心愿清单：整份替换缓存并刷新手机页——完成心愿/跑腿后服务端立刻重推，卡的退场与盖章同拍
	wish_board = _derive_wish_board(wishes)
	if phone_ui != null:
		phone_ui.refresh_wishes()
	if discovered.has("guide_to"):
		_guide_used = true
	# B3 复用提示（§4.2）：服务端在「有需求语境」判出背包旧物能用上 → 记下，等 ambient 通道点一句。
	# 服务端已做本会话去重，客户端只在有 itemId 时挂起（空/null 不覆盖已挂起的）。
	if typeof(reuse_hint) == TYPE_DICTIONARY and not String(reuse_hint.get("itemId", "")).is_empty():
		_pending_reuse = reuse_hint

## A4 心愿清单推导（M1 §2.4）：只收「供给信号」（source=wish|chain|errand），纯氛围自语不进清单；
## wish 同 ability 去重（全村同心愿只留第一个村民），chain/errand 本就每村民一条（entry 即去重）；
## 硬 cap WISH_BOARD_MAX——不排序、不标紧急度，任何一张先点都对（§3.1）。
func _derive_wish_board(wishes: Array) -> Array:
	var seen_ability := {}
	var board: Array = []
	for w in wishes:
		if board.size() >= WISH_BOARD_MAX:
			break
		var d := w as Dictionary
		var source := String(d.get("source", ""))
		if source.is_empty():
			continue
		var ability := String(d.get("ability", ""))
		if source == "wish":
			if seen_ability.has(ability):
				continue
			seen_ability[ability] = true
		board.append({ "characterId": String(d.get("characterId", "")), "ability": ability, "source": source })
	return board

## 音符气泡：小仙子出声时挂在头顶（氛围闲聊与 POI 提醒共用）。
func _update_fairy_bubble(fairy: Dictionary) -> void:
	var node: Node3D = fairy["node"]
	_fairy_bubble.visible = fairy_voice.is_playing()
	if _fairy_bubble.visible:
		_fairy_bubble.global_position = node.global_position \
			+ Vector3(0.0, _char_top(node as PaperCharacter) + 0.9, 0.0)

## 按玩家周围地形挑话题：水/高山/村庄优先（各有冷却），否则闲聊。
func _ambient_trigger() -> String:
	var pt := WorldGrid.to_tile(player["logical"])
	var near_water := false
	var near_mountain := false
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			var t := Vector2i((pt.x + dx + WorldGrid.GRID_TILES) % WorldGrid.GRID_TILES,
				(pt.y + dz + WorldGrid.GRID_TILES) % WorldGrid.GRID_TILES)
			if TerrainMap.tile_type(t) == TerrainMap.T_WATER:
				near_water = true
			if TerrainMap.tile_height(t) >= 3:
				near_mountain = true
	if near_water and fairy_voice.can_play("near_water"):
		return "near_water"
	if near_mountain and fairy_voice.can_play("near_mountain"):
		return "near_mountain"
	var center := Vector2(WorldGrid.WORLD_SPAN, WorldGrid.WORLD_SPAN) * 0.5
	if WorldGrid.shortest_delta(player["logical"], center).length() <= 14.0 \
			and fairy_voice.can_play("near_village"):
		return "near_village"
	return "idle"

## 在 around 附近按环形扫描找可站立空位（不压物件/角色、不在水里）；找不到原样返回。
func _find_free_spot(around: Vector2, span: int) -> Vector2:
	for r in range(0, 9):
		var n_ang := 16 if r > 0 else 1
		for k in range(n_ang):
			var ang := float(k) * TAU / float(n_ang)
			var p := WorldGrid.wrap_pos(around + Vector2(cos(ang), sin(ang)) * float(r))
			if TerrainMap.tile_type(WorldGrid.to_tile(p)) == TerrainMap.T_WATER:
				continue
			var origin := OccupancyMap.footprint_origin(p, span)
			if OccupancyMap.is_free_rect(origin, span, span) \
					and OccupancyMap.char_area_free(origin, span, span, PLAYER_ID):
				return p
	return around

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud_layer = layer
	# 舞台 HUD 工厂（计分/倒计时/toast）：倒计时归零经 _on_stage_timer_done 转 StageAgent 上行。
	_hud = HudFactory.new()
	_hud.setup(layer, Callable(self, "_on_stage_timer_done"))

	# 换场景黑幕：独立 CanvasLayer 盖在 HUD 之上，过场期间连按钮一起遮住（顺带吃掉乱点）。
	var fade_layer := CanvasLayer.new()
	fade_layer.layer = 100
	add_child(fade_layer)
	_fade_rect = ColorRect.new()
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.color = Color(0.04, 0.05, 0.08)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_fade_rect.visible = false
	_fade_rect.modulate.a = 0.0
	fade_layer.add_child(_fade_rect)
	# loading 遮罩内容盖在底色之上（同层、同 _fade_a 淡）；缺素材也不崩，最差退化成纯底色黑幕。
	_transition_overlay = _build_transition_overlay()
	fade_layer.add_child(_transition_overlay)
	_load_play_budget() # 恢复跨会话可玩时间预算（隔会话对账：冷却已过/长休息则刷新）

	coord_label = Label.new()
	coord_label.position = Vector2(16.0, 12.0)
	_style_label(coord_label, 22)
	layer.add_child(coord_label)

	# 调试性能浮层：右上角常显 FPS + CPU/GPU 分项耗时（GPU 时间需显式打开测量；
	# 部分安卓驱动不支持 GPU 时间戳会读到 0，届时用「总帧时 - CPU」反推）
	if OS.is_debug_build():
		perf_label = Label.new()
		perf_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		perf_label.offset_left = -430.0
		perf_label.offset_right = -16.0
		perf_label.offset_top = 12.0
		perf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_style_label(perf_label, 20)
		layer.add_child(perf_label)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

		# 语音耗时浮层：贴在 FPS 浮层下方（同为右上角，仅 debug）
		voice_prof_label = Label.new()
		voice_prof_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		voice_prof_label.offset_left = -430.0
		voice_prof_label.offset_right = -16.0
		voice_prof_label.offset_top = 160.0
		voice_prof_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_style_label(voice_prof_label, 20)
		voice_prof_label.text = "语音耗时(ms)\n（说句话看看）"
		layer.add_child(voice_prof_label)

	banner = Label.new()
	banner.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	banner.offset_top = -96.0
	banner.offset_bottom = -36.0
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_label(banner, 28)
	banner.visible = false
	layer.add_child(banner)

	# 专门的创造视图（方案 A）：全屏暗底 + 顶部问题字幕/进度点 + 屏幕中央 2×2 大图标卡。
	# 一进创造就显它、退出普通对话构图（见 _enter_creation_view）；点卡即答复小仙子。
	_build_creation_view(layer)

	# 玩家喊话态的底部表情盘（player-interaction P3）：进喊话态亮起，点一格双端一起演。
	_build_talk_view(layer)

	# NPC 对话态的贴纸盘（character-anchors P4）：背包有贴纸时亮起，选贴纸→选槽位贴上。
	_build_sticker_view(layer)

	# 放置模式 HUD（placement-p1）：从物品 app 进入摆放时亮起——顶部提示 + 底部「转一转/收起来/放这里」。
	_build_placement_view(layer)

	# 试用调整 HUD（A1 试用·还差一点）：村民抱怨「差一点」时亮起——顶部提示 + 底部「变大/变小/好啦」。
	_build_refine_view(layer)

	# 收听 HUD：近身对话期间浮在横幅上方——AIGC 生成的奶油圆角边框贴图（hud_listen，
	# 麦克风+音波+星饰烤进边框），一排珊瑚色声波柱嵌在边框空心内板、随音量跳动，
	# 给不识字的小朋友一个又大又清楚的「现在在听你说话」提示。
	var hud_h := WAVE_HUD_W * WAVE_HUD_ASPECT
	voice_wave = Control.new()
	voice_wave.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	voice_wave.offset_top = -104.0 - hud_h
	voice_wave.offset_bottom = -104.0
	voice_wave.pivot_offset = Vector2(WAVE_HUD_W, hud_h) * 0.5 # 缩放绕自身中心，落位不跑
	voice_wave.mouse_filter = Control.MOUSE_FILTER_IGNORE
	voice_wave.visible = false
	layer.add_child(voice_wave)
	_layout_voice_wave(false)
	# AIGC 边框贴图：整块填满 voice_wave，等比铺满
	var frame := TextureRect.new()
	frame.texture = UiAssets.tex("hud_listen")
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	voice_wave.add_child(frame)
	# 声波柱：共用 VoiceWave 控件（流动波），锚在 HUD 竖直中心、底边落在中心下方 WAVE_BASE_Y
	# 处（内板中下部），只向上长。参数即 world 原口径（九条珊瑚色、idle_floor/gain 默认）。
	var wave := VoiceWave.new()
	wave.bar_count = WAVE_BARS
	wave.bar_width = 12.0
	wave.bar_gap = 8.0
	wave.bar_min_h = WAVE_MIN_H
	wave.bar_max_h = WAVE_MAX_H
	wave.bar_color = Color(0.96, 0.5, 0.36) # 珊瑚色：与边框描边同调、内板上高对比
	wave.level_source = func() -> float: return _vc.level() if _vc != null else 0.0
	wave.anchor_left = 0.5
	wave.anchor_right = 0.5
	wave.anchor_top = 0.5
	wave.anchor_bottom = 0.5
	wave.offset_bottom = WAVE_BASE_Y                 # 底边（柱底）落在中心下方 WAVE_BASE_Y
	wave.offset_top = WAVE_BASE_Y - WAVE_MAX_H       # 上边留出最高柱的空间
	voice_wave.add_child(wave)
	voice_wave_widget = wave

	# 左下角手机菜单：一台竖屏手机（比旧书本按钮更大更好点），点开在 HUD 里弹手机壳+屏幕。
	album_button = Button.new()
	album_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	album_button.offset_left = 20.0
	album_button.offset_top = -168.0
	album_button.offset_right = 128.0
	album_button.offset_bottom = -20.0
	album_button.pressed.connect(_toggle_album)
	# 透明热区：图标就是停靠在此处的 3D 手机本体（_dock_fit 对齐此按钮矩形），按钮只收点击
	album_button.flat = true
	for st in ["normal", "hover", "pressed", "focus"]:
		album_button.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	layer.add_child(album_button)

	# 引路中的「不去了」按钮：取消入口必须【可见】，不能让小朋友猜。
	# 刻意不做成她头顶的可点气泡：点她本体是「进对话」（引路途中想跟她说话是正当需求，不能剥夺），
	# 两个入口挤在一个 3D 身位上必然误触。做成独立 HUD 按钮，位置固定、随时能点。
	guide_stop_button = Button.new()
	guide_stop_button.text = "不去了"
	guide_stop_button.set_anchors_preset(Control.PRESET_CENTER_TOP)
	guide_stop_button.offset_left = -70.0
	guide_stop_button.offset_right = 70.0
	guide_stop_button.offset_top = 96.0
	guide_stop_button.offset_bottom = 152.0
	guide_stop_button.add_theme_font_size_override("font_size", 26)
	guide_stop_button.visible = false
	guide_stop_button.pressed.connect(_on_guide_stop_pressed)
	layer.add_child(guide_stop_button)

	# 手机开着时的全屏透明遮罩：点手机外的任何位置→收起手机（吞掉该点击，不当世界移动指令）。
	# 先于机身入层，机身后入 → 机身盖在遮罩之上；机身区域点击照常给机身，机身外给遮罩。
	_phone_scrim = Control.new()
	_phone_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_phone_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_phone_scrim.visible = false
	_phone_scrim.gui_input.connect(_on_phone_scrim_input)
	layer.add_child(_phone_scrim)

	# ── 3D 纸糊双折叠手机：挂相机前（不被世界物件遮挡的近距持机位）；屏幕内容住在
	# 两块 SubViewport 里（PhoneUi 建 Control 树），点击经遮罩 → 射线 → UV 转发进视口。
	# 开 app = 整机翻转 180° 并展开成双倍宽跨页（PaperPhone 状态机，设计 docs/paper-phone-design.md）。
	paper_phone = PaperPhone.new()
	camera.add_child(paper_phone)
	paper_phone.attach_light_rig() # 自带暖灯挂相机（手机层与世界太阳互相隔离）
	paper_phone.create_screens(PhoneUi.FRONT_PX, PhoneUi.SPREAD_PX)
	# 兜底护栏：手机一进停靠态就无条件收遮罩。遮罩 _phone_scrim 盖在左下角手机热区按钮之上
	# （MOUSE_FILTER_STOP），语义=「手机开着才该在」。真机偶发某次开/关/装扮动画被打断、收尾没
	# 跑到，遮罩留在 visible=true → 点停靠的手机被它吞掉、_toggle_album 永不触发 → 点不开（重启
	# 才好）。此处把「停靠即收遮罩」钉在状态源头，任何收起路径（含被打断的）都逃不掉。
	paper_phone.state_changed.connect(func(s: int) -> void:
		if s == PaperPhone.State.DOCKED and _phone_scrim != null:
			_phone_scrim.visible = false)
	# 白卡纸壳贴图（角部带圆角 alpha 镂空=die-cut 剪影）；缺资产时保持程序化白卡纸占位
	var shell_front := UiAssets.tex("phone3d_front_shell")
	if shell_front != null:
		paper_phone.set_face_texture(PaperPhone.FACE_FRONT, shell_front, true)
	var shell_back := UiAssets.tex("phone3d_back_shell")
	if shell_back != null:
		paper_phone.set_face_texture(PaperPhone.FACE_BACK, shell_back, true)
	phone_ui = PhoneUi.new(self)
	phone_ui.build(paper_phone.front_viewport(), paper_phone.spread_viewport())
	phone_ui.set_screen_off(true) # 停靠常驻=熄屏黑屏，点亮才见主屏
	phone_ui.app_opened.connect(func(_id: String) -> void:
		if game_audio != null:
			game_audio.play_sfx("page") # 翻面纸声（点选 select 已在 PhoneUi 响过）
		_fit_phone(true)
		paper_phone.show_spread())
	phone_ui.back_pressed.connect(func() -> void:
		if paper_phone.state == PaperPhone.State.SPREAD:
			if game_audio != null:
				game_audio.play_sfx("page")
			_fit_phone(false)
			paper_phone.show_front())

	# 进行中委托的提示 chip（右上角，图标为主：委托人头像+目标 ⇒ 奖励贴纸，_update_task_chip 重建）
	# 整个 chip 可点：点一下小仙子会用自己的话提醒该怎么做（跑腿提带路/心愿提一起造）——见 _on_task_chip_input。
	# mouse_filter=STOP 让容器自己收点击；子图标/字设 IGNORE（见 _chip_icon/_chip_label）好让点击穿到容器。
	task_chip = HBoxContainer.new()
	task_chip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	task_chip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	task_chip.offset_right = -16.0
	task_chip.offset_top = 12.0
	task_chip.alignment = BoxContainer.ALIGNMENT_END
	task_chip.add_theme_constant_override("separation", 8)
	task_chip.visible = false
	task_chip.mouse_filter = Control.MOUSE_FILTER_STOP
	task_chip.gui_input.connect(_on_task_chip_input)
	layer.add_child(task_chip)

	# 顶部「听到的文字」反馈：让大人能确认 ASR 是否识别成功
	heard_label = Label.new()
	heard_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	heard_label.offset_top = 36.0
	heard_label.offset_bottom = 96.0
	heard_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heard_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_label(heard_label, 24)
	heard_label.visible = false
	layer.add_child(heard_label)

	# 说完先听一遍：确认条（confirm_mode 开时才亮）。摆屏幕下方三分之一——
	# 别盖住正在对话的角色，孩子的视线本来就在角色脸上。
	confirm_bar = ConfirmBar.new()
	confirm_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	confirm_bar.offset_left = -220.0
	confirm_bar.offset_right = 220.0
	confirm_bar.offset_top = -240.0
	confirm_bar.offset_bottom = -60.0
	confirm_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	confirm_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(confirm_bar)

	# 思考状态：小字弱化到顶部（给家长看），幼儿看角色头顶的 _think_bubble 动画
	thinking_label = Label.new()
	thinking_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	thinking_label.offset_top = 108.0
	thinking_label.offset_bottom = 140.0
	_style_label(thinking_label, 20)
	thinking_label.text = "思考中…"
	thinking_label.visible = false
	layer.add_child(thinking_label)

	# 思考动画气泡：·/··/··· 循环冒泡（挂选中角色头顶，_update_think_bubble 驱动）
	_think_bubble = Label3D.new()
	_think_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_think_bubble.pixel_size = 0.02
	_think_bubble.outline_size = 14
	_think_bubble.font_size = 110
	_think_bubble.visible = false
	add_child(_think_bubble)

	# 角色头顶情绪气泡：AIGC 表情贴纸 + 弹出动画（_show_emotion / _update_emotion_bubble）
	emotion_bubble = UiAssets.bubble_sprite("em_happy", 1.9)
	add_child(emotion_bubble)

	# NPC 间聊天的轮流气泡（chat_with 演出，见 _update_npc_chats）
	_npc_chat_bubble = UiAssets.bubble_sprite("ic_note", 1.7)
	add_child(_npc_chat_bubble)

	# 冷却拦截遮罩：可玩时间用尽后弹出（挡整屏世界交互）；闹钟饼图倒计时，冷却结束自动收起。
	# 末位入层→盖在其余 HUD 之上，MOUSE_FILTER_STOP 吞掉所有点击。
	_cooldown_overlay = _build_cooldown_overlay()
	layer.add_child(_cooldown_overlay)

func _style_label(l: Label, size: int) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)

## 手机遮罩点击：先做 3D 手机命中——打在机身上的鼠标事件转发进屏幕视口（或被壳吞掉）；
## 没打在手机上的按下→收起手机（吞掉事件，不下发为世界移动指令）。
func _on_phone_scrim_input(e: InputEvent) -> void:
	if paper_phone != null and paper_phone.route_gui_event(camera, e):
		_phone_scrim.accept_event()
		return
	# 真机触摸会同时来 ScreenTouch + 模拟鼠标：命中机身的 ScreenTouch 也要吞掉（只转发鼠标事件，防双发）
	if e is InputEventScreenTouch and paper_phone != null \
			and paper_phone.hit_test(camera, (e as InputEventScreenTouch).position):
		_phone_scrim.accept_event()
		return
	var press := (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed) \
			or (e is InputEventMouseButton and (e as InputEventMouseButton).pressed)
	if press:
		_close_phone()
		_phone_scrim.accept_event()

## 打开一个 app（薄壳：页面切换在 PhoneUi，翻转动画由 app_opened 信号驱动）。
func _open_app(id: String) -> void:
	phone_ui.open_app(id)

## 按当前形态贴合持机位（正面贴屏右 / 跨页双宽居中）+ 停靠位（对齐左下角热区按钮）。
func _fit_phone(spread: bool) -> void:
	_phone_fit_vp = get_viewport().get_visible_rect().size
	if spread:
		paper_phone.fit_hand(camera, PHONE_SPREAD_FILL, PHONE_SPREAD_NDC)
	else:
		paper_phone.fit_hand(camera, PHONE_FILL, PHONE_NDC)
	_fit_phone_dock()

## 停靠位从热区按钮矩形反推 NDC/占屏比：布局改按钮即可挪手机图标，零手调常量。
func _fit_phone_dock() -> void:
	var vp := get_viewport().get_visible_rect().size
	if vp.y <= 1.0 or album_button == null:
		return
	var r := album_button.get_global_rect()
	if r.size.y <= 1.0:
		return
	var c := r.get_center()
	var ndc := Vector2(c.x / vp.x * 2.0 - 1.0, 1.0 - c.y / vp.y * 2.0)
	paper_phone.fit_dock(camera, r.size.y / vp.y, ndc)

## 每帧驱动手机：resize/首帧重贴合；停靠态 60s 低频渲一帧（熄屏画面的时钟走字）；
## 使用态跑 banner 秒刷 + 图标分页贴合。
func _step_phone_ui(delta: float) -> void:
	if paper_phone == null:
		return
	if get_viewport().get_visible_rect().size != _phone_fit_vp or not paper_phone.visible:
		var was_hidden := not paper_phone.visible
		_fit_phone(paper_phone.state == PaperPhone.State.SPREAD) # 首帧按钮布局就绪前 visible=false，逐帧兜底
		if was_hidden and paper_phone.visible:
			_phone_dock_t = 0.0 # 首次现身立即渲一帧熄屏画面（视口从未渲过是垃圾纹理）
	if paper_phone.state == PaperPhone.State.DOCKED:
		_phone_dock_t -= delta
		if _phone_dock_t <= 0.0:
			_phone_dock_t = 60.0
			phone_ui.refresh_banner() # 熄屏 AOD 时钟走字
			paper_phone.refresh_dock_screen()
		return
	phone_ui.tick(delta)

## 可玩时间每帧推进（静态纯函数，便于回测）：
## 冷却中→到点则重置(used=0、解锁)，否则维持并算冷却进度；否则累计 delta，满预算则进冷却。
## 返回 {used, cooldown_until, blocked, remaining_frac, cooldown_frac}。
static func tick_play_budget(used: float, cooldown_until: float, now: float, delta: float,
		budget: float, cooldown: float) -> Dictionary:
	if cooldown_until > 0.0:
		if now >= cooldown_until:
			return { "used": 0.0, "cooldown_until": 0.0, "blocked": false, "remaining_frac": 1.0, "cooldown_frac": 0.0 }
		var cdf := clampf(1.0 - (cooldown_until - now) / cooldown, 0.0, 1.0)
		return { "used": used, "cooldown_until": cooldown_until, "blocked": true, "remaining_frac": 0.0, "cooldown_frac": cdf }
	var nu := used + maxf(0.0, delta)
	if nu >= budget:
		return { "used": budget, "cooldown_until": now + cooldown, "blocked": true, "remaining_frac": 0.0, "cooldown_frac": 0.0 }
	return { "used": nu, "cooldown_until": 0.0, "blocked": false, "remaining_frac": 1.0 - nu / budget, "cooldown_frac": 0.0 }

## 进世界时对持久化预算「隔会话对账」（静态纯函数）：冷却已过则清零；未冷却但离开够久(≥cooldown)＝自然休息，刷新预算。
static func reconcile_play_budget(used: float, cooldown_until: float, last_active: float,
		now: float, cooldown: float) -> Dictionary:
	if cooldown_until > 0.0:
		if now >= cooldown_until:
			return { "used": 0.0, "cooldown_until": 0.0 }
		return { "used": used, "cooldown_until": cooldown_until }
	if last_active > 0.0 and (now - last_active) >= cooldown:
		return { "used": 0.0, "cooldown_until": 0.0 }
	return { "used": used, "cooldown_until": cooldown_until }

## 进世界：读持久化预算 + 隔会话对账（冷却期内重进仍被拦、冷却已过/长休息则刷新）。
func _load_play_budget() -> void:
	var pb := PlayerProfile.load_play_budget()
	var now := Time.get_unix_time_from_system()
	var rec := reconcile_play_budget(float(pb["used_sec"]), float(pb["cooldown_until"]),
			float(pb["last_active"]), now, float(PLAY_COOLDOWN_SEC))
	_play_used_sec = float(rec["used"])
	_play_cooldown_until = float(rec["cooldown_until"])

## 每帧推进可玩时间预算：累计活跃游玩、到点进冷却、冷却到点解锁；同步 widget/遮罩，节流落盘。
func _step_play_budget(delta: float) -> void:
	var now := Time.get_unix_time_from_system()
	var was_blocked := _play_blocked
	var st := tick_play_budget(_play_used_sec, _play_cooldown_until, now, delta,
			float(PLAY_BUDGET_SEC), float(PLAY_COOLDOWN_SEC))
	_play_used_sec = float(st["used"])
	_play_cooldown_until = float(st["cooldown_until"])
	_play_blocked = bool(st["blocked"])
	_play_remaining_frac = float(st["remaining_frac"])
	_play_cooldown_frac = float(st["cooldown_frac"])
	if _play_blocked != was_blocked:
		_apply_cooldown_block(_play_blocked) # 进/出冷却的一次性动作（弹/收遮罩、收手机断对话）
	if _cooldown_overlay != null and _cooldown_overlay.visible and _cooldown_pie != null:
		_cooldown_pie.set_state(0.0, true, _play_cooldown_frac)
	# 节流落盘（每 5s + 状态切换即存），关 App 也不丢
	_play_save_t -= delta
	if _play_save_t <= 0.0 or _play_blocked != was_blocked:
		_play_save_t = 5.0
		PlayerProfile.save_play_budget(_play_used_sec, _play_cooldown_until, now)

## 进/出冷却的一次性副作用：进冷却→弹全屏遮罩、收手机、断当前对话、小仙子语音提示；出冷却→收遮罩+语音。
func _apply_cooldown_block(blocked: bool) -> void:
	if _cooldown_overlay != null:
		_cooldown_overlay.visible = blocked
	if blocked:
		_close_phone()
		if _locked != null:
			_exit_interaction() # 断开近身对话，回自由视角（冷却期不许交互）
		if fairy_voice != null:
			fairy_voice.try_play("cooldown_start") # 小仙子语音提示：该休息啦
	elif fairy_voice != null:
		fairy_voice.try_play("cooldown_end") # 冷却结束：休息好啦，继续玩

## ── e2e harness 钩子（docs/voice-e2e-harness-design.md）───────────────────────────
## 供 DebugCmdServer 的 talk_fairy / reset_budget 命令调用。debug 构建才接命令口，release 不触达。

## 不靠屏幕坐标直接进与小仙子「点点」的对话：找到仙子发起 _approach_npc（玩家走过去+进对话，
## 与「点自己=跟身边小仙子说话」同一条已验证路径）。返回是否找到仙子并发起（对话开在几帧后，脚本轮询 vc_open）。
func harness_talk_fairy() -> bool:
	var fairy := _find_fairy()
	if fairy.is_empty() or not is_instance_valid(fairy.get("node")):
		return false
	_approach_npc(fairy["node"])
	return true

## 进与第一个【真实非仙子 NPC】的对话（e2e 验 NPC 招呼链：send_greeting → character_response(greeting)）。
## 盲点选 NPC 不可靠（tap 没命中会把玩家支使走），这条直接从 npcs 找村民发起靠近+进对话，
## 随后轮询 selected/last_greeting 即可。返回 entered=是否找到村民并发起（对话开在几帧后）。
func harness_talk_npc(who := "") -> bool:
	# who 非空＝按名找村民（含子串互配，同 sameName 口径）——deliver/bring 委托要对【指定】角色
	# 进对话才算送达，列表首个村民赌不中（e2e 追猪小弟实证）。空＝原行为（首个真实村民）。
	for n in npcs:
		if bool(n.get("is_fairy", false)):
			continue
		var id := String(n.get("id", ""))
		if id.is_empty() or _is_local_only_id(id):
			continue # 只找有后端 id 的真实村民（跳过本地占位/仙子）
		if not is_instance_valid(n.get("node")):
			continue
		if not who.is_empty():
			var nm := String((n["node"] as PaperCharacter).char_name)
			if nm != who and not nm.contains(who) and not who.contains(nm):
				continue
		_approach_npc(n["node"])
		return true
	return false

## 直接拾起 tile 上的一件物品进背包（e2e 验复用提示需背包里有旧物——长按拾取的手势在真机盲驱不可靠）。
## 走服务端已有的 item_pickup 报文（server 不校验玩家距离，只按 tile 查物），不新增服务端逻辑。
## edge_side<0 = tile 物（造物 prop），≥0 = tile 边贴纸。返回 sent=是否在线发出。
func harness_pickup(tile_x: int, tile_y: int, edge_side := -1) -> bool:
	if not online or backend == null:
		return false
	backend.send_item_pickup(world_id, Vector2i(tile_x, tile_y), edge_side)
	return true

## e2e 引导式造物：按 optionId 点一张引导卡（等同孩子点了那张卡），走现成 _on_creation_card
## → send_creation_reply。仅在引导会话中有效（_in_creation）；不在引导返 false 让 harness 知道没生效。
## card=null：跳过「扔进蛋/炉」动画（harness 无需视觉），其余与真人点卡一字不差。
func harness_pick_option(option_id: String) -> bool:
	if not _in_creation:
		return false
	_on_creation_card(option_id)
	return true

## 清掉游玩时长冷却门（45min 玩满 → 10min 冷却模态挡住造物/交互），供 e2e 连测不被拦。
## 与 _step_play_budget 同口径重置本地预算 + 收遮罩 + 落盘；不碰服务端。
func harness_reset_play_budget() -> void:
	_play_used_sec = 0.0
	_play_cooldown_until = 0.0
	_play_remaining_frac = 1.0
	_play_cooldown_frac = 0.0
	if _play_blocked:
		_play_blocked = false
		_apply_cooldown_block(false) # 收全屏遮罩、恢复交互
	PlayerProfile.save_play_budget(0.0, 0.0, Time.get_unix_time_from_system())

## 摄影模式（menu 相册拍摄，photo 命令）：hud 键控 HUD 层与 3D 手机显隐；cam 键设摄影机位覆盖
## （_update_camera 改走 photo_cam）；clear_cam 撤覆盖还原跟随相机。只动显示与相机，不碰玩法状态——
## 拍完 {"hud":true,"clear_cam":true} 即完全还原。
func harness_photo(args: Dictionary) -> Dictionary:
	if args.has("hud"):
		var on := bool(args["hud"])
		if _hud_layer != null:
			_hud_layer.visible = on
		if paper_phone != null:
			paper_phone.visible = on
	if args.has("cam"):
		photo_cam = args["cam"]
	elif bool(args.get("clear_cam", false)):
		photo_cam = {}
	_update_camera()
	return {"hud": _hud_layer.visible if _hud_layer != null else true,
		"photo_cam": not photo_cam.is_empty()}

## 摄影传送（photo 拍摄找机位）：把玩家（和跟随的仙子）就地搬到目标 tile 附近空位。
## near_npc=true 时改搬到第一个真实非仙子村民身旁（村庄合影机位——相机永远聚焦玩家，
## 玩家不在村民堆里就拍不到村子）。与 _go_home 的就地解卡分支同款调用序列。
func harness_teleport(tile: Vector2i, near_npc: bool) -> bool:
	if player.is_empty():
		return false
	var target := WorldGrid.from_tile_center(tile)
	if near_npc:
		var found := false
		for n in npcs:
			if bool(n.get("is_fairy", false)) or not is_instance_valid(n.get("node")):
				continue
			target = WorldGrid.wrap_pos((n["logical"] as Vector2) + Vector2(2.5, 1.5))
			found = true
			break
		if not found:
			return false
	_cancel_player_move()
	_clear_approach()
	OccupancyMap.char_unregister(PLAYER_ID)
	var spot := _find_free_spot(target, PLAYER_SPAN)
	player["logical"] = spot
	OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)
	focus_logical = spot
	var fairy := _find_fairy()
	if not fairy.is_empty():
		fairy["logical"] = WorldGrid.wrap_pos(spot + Vector2(2.6, 1.8))
	return true

## 摄影切场景：直通 enter_scene（走正常黑幕过场 + 服务端 scene_entered 落位），脚本随后轮询
## state.scene_id / transitioning 等落地。已在目标场景也算成功。
func harness_enter_scene(scene_id: String) -> bool:
	if _scene_id == scene_id:
		return true
	if not online or backend == null or _transitioning:
		return false
	enter_scene(scene_id)
	return _pending_scene == scene_id

## harness（AI 驱动）：手机开/关/开 app。手机屏住在 SubViewport 里、盲坐标 tap 到不了，
## 这条走与真点击相同的内部路径（_open_phone/_open_app），驱动方随后用 state.phone_open/phone_app 核落地。
func harness_phone(action: String, app_id := "") -> bool:
	if paper_phone == null or phone_ui == null:
		return false
	match action:
		"open":
			if paper_phone.state == PaperPhone.State.DOCKED:
				_open_phone()
			return true
		"close":
			_close_phone()
			return true
		"app":
			if app_id.is_empty():
				return false
			if paper_phone.state == PaperPhone.State.DOCKED:
				_open_phone()
			_open_app(app_id)
			return true
	return false

## 冷却拦截遮罩：半透明暗底 + 居中卡片（大闹钟饼图倒计时 + 文案）。整屏 STOP 吞点击，冷却期挡住世界。
func _build_cooldown_overlay() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.visible = false
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.10, 0.07, 0.03, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiAssets.card_style(26.0, 1.0))
	center.add_child(card)
	var pad := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(side, 28)
	card.add_child(pad)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 16)
	pad.add_child(col)
	_cooldown_pie = PlayTimePie.new()
	_cooldown_pie.custom_minimum_size = Vector2(140.0, 140.0)
	_cooldown_pie.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(_cooldown_pie)
	var title := Label.new()
	title.text = "玩得好开心！"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiAssets.style_card_label(title, 34)
	col.add_child(title)
	var msg := Label.new()
	msg.text = "先休息一下，\n等小闹钟转满就能再来玩啦~"
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UiAssets.style_card_label(msg, 24)
	col.add_child(msg)
	return root

## 小红花数：服务端权威钱包（world_state/task_complete/item_created/gen_complete 同步）。
func _red_flower_count() -> int:
	return int(wallet.get("flowers", 0))

func _physics_process(delta: float) -> void:
	# 回家过场中：玩家由 _step_home 脚本驱动走进/走出传送门，吞掉方向键，别让手动操控抢位。
	if _homing:
		return
	# 方向键直接驱动玩家（桌面调试；与点击移动同一 Mover 规则）
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if input != Vector2.ZERO and not player.is_empty():
		_hold_follow = false # 手动操控优先，退出按住跟随
		_cancel_player_move() # 手动操控优先，替换点击移动指令
		var moved := Mover.attempt(player["logical"], input * PLAYER_SPEED * delta, PLAYER_SPAN, PLAYER_ID)
		if moved != player["logical"]:
			player["logical"] = moved
			OccupancyMap.char_register(PLAYER_ID, moved, PLAYER_SPAN)

## _process 分段计时（平板 fps<10 二阶段：真机脚本逻辑 162ms/帧，热点分布只能实测）。
## 累计各段 usec，debug 构建每 ~2s 往 stdout（安卓即 logcat godot tag）吐一行降序分布。
var _prof := {}
var _prof_max := {}      ## 各段窗口内单帧最大值（2s 平均会抹平 200ms 级单帧凶手）
var _prof_frame_acc := 0 ## 本帧各段合计（帧级尖峰即时打印用）
var _frame_worst_key := ""
var _frame_worst_us := 0
var _prof_t := 0.0
var _prof_frames := 0

func _prof_lap(prev: int, key: String) -> int:
	var now := Time.get_ticks_usec()
	var us := now - prev
	_prof[key] = int(_prof.get(key, 0)) + us
	if us > int(_prof_max.get(key, 0)):
		_prof_max[key] = us
	if us > _frame_worst_us:
		_frame_worst_us = us
		_frame_worst_key = key
	_prof_frame_acc += us
	return now

## 帧级尖峰即时打印（带 logcat 时间戳，可与麦克风/TTS 事件对齐）；每帧开头 reset。
func _prof_frame_begin() -> void:
	_prof_frame_acc = 0
	_frame_worst_us = 0
	_frame_worst_key = ""

func _prof_frame_end() -> void:
	if _prof_frame_acc > 80000:
		print("FSPIKE total=%.0fms worst=%s:%.0fms" % [float(_prof_frame_acc) / 1000.0,
				_frame_worst_key, float(_frame_worst_us) / 1000.0])

func _prof_flush(delta: float) -> void:
	_prof_t += delta
	_prof_frames += 1
	if _prof_t < 2.0:
		return
	var total := 0
	for k in _prof:
		total += _prof[k]
	_prof.merge(ProcProf.take())  # 其他脚本的账本（allproc/sdfprop/ws…）并入展示，不计入 world 合计
	var keys := _prof.keys()
	keys.sort_custom(func(a, b): return _prof[a] > _prof[b])
	var n := maxi(_prof_frames, 1)
	# eng = 引擎口径 TIME_PROCESS（整个 process 步，含所有节点 _process 与可能的交换链等待），
	# 与分段合计的差 = world._process 之外的时间，用于判断热点归属
	var line := "PERF %.1fms/f eng=%.1f nodes=%d:" % [float(total) / 1000.0 / n,
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))]
	for k in keys.slice(0, 10):
		line += " %s=%.1f" % [k, float(_prof[k]) / 1000.0 / n]
	print(line)
	# 单帧最大值（找间歇性尖峰的凶手：哪一段曾在单帧内爆过）
	var mkeys := _prof_max.keys()
	mkeys.sort_custom(func(a, b): return _prof_max[a] > _prof_max[b])
	var mline := "PERFMAX"
	for k in mkeys.slice(0, 6):
		mline += " %s=%.0f" % [k, float(_prof_max[k]) / 1000.0]
	print(mline)
	_prof.clear()
	_prof_max.clear()
	_prof_t = 0.0
	_prof_frames = 0

func _process(delta: float) -> void:
	_prof_frame_begin()
	var tp := Time.get_ticks_usec()
	_drain_tts_stream()
	tp = _prof_lap(tp, "tts")
	_step_hold_follow(delta)
	_step_prop_press(delta)
	tp = _prof_lap(tp, "hold/prop")
	_step_task(delta)
	tp = _prof_lap(tp, "task/give")
	_step_executors(delta)
	_step_stage(delta) # 舞台协议：轮询完成型命令（走位/动作/念白）→ 回 ack
	tp = _prof_lap(tp, "executors")
	_step_positions_report(delta)
	_check_approach()
	_step_portal()          # 踏进传送点半径 → enter_scene（黑幕 + 卸旧载新）
	_step_transition(delta) # 过场黑幕推进（淡入/发报文/等区块/淡出）
	_step_home(delta)       # 回家传送门过场推进（召唤门/走进/走出/消散）
	tp = _prof_lap(tp, "approach")
	_update_fairy(delta)
	tp = _prof_lap(tp, "fairy")
	# 空识别退避倒计时：只在「否则就该开麦」时烧（角色说话/思考期本就闭麦，别空烧退避，
	# 否则 TTS 一停麦就全开，退避形同虚设）。开麦门禁/VAD/分片/端侧会话/BGM 静音由 _vc 内部管。
	if _cooldown_t > 0.0:
		var cx := _fsm_inputs()
		if not (cx.thinking or cx.speaking()):
			_cooldown_t = maxf(_cooldown_t - delta, 0.0)
	_vc.step(delta)
	_step_intro_listen(delta) # intro 教学「开口说话」步的本地 VAD 监听（非 intro 期为空转）
	_step_edge_tts(delta)
	_step_pending_leave(delta) # 「说完再走」：回应播完才动身+关对话（缺陷 ④）
	tp = _prof_lap(tp, "voice")
	# 语音链路占用时压低 BGM（音量微降），给人声让路。BGM 静音（比 duck 更狠、断外放回灌）
	# 由 VoiceCapture 内部门控（口径：聆听窗一开即静音、只在角色说话时放行）。
	game_audio.set_ducked(InteractionFsm.voice_busy(_fsm_inputs()))
	tp = _prof_lap(tp, "duck")
	_step_hop(delta)  # 进对话时玩家跳向站位（在焦点/摆位之前推进，相机随之贴合）
	_step_phone_ui(delta)
	_step_play_budget(delta)
	tp = _prof_lap(tp, "phoneui")
	# 视角缓动（跟随 ↔ lock 的 pitch/dist 过渡）
	var t := minf(1.0, CAM_EASE * delta)
	_cur_pitch = lerpf(_cur_pitch, _target_pitch, t)
	_cur_dist = lerpf(_cur_dist, _target_dist, t)
	# 双指手势偏移缓动；松手后无进一步操作 GESTURE_RESET_DELAY 秒自动复原
	if not _gesturing and _gest_reset_t > 0.0:
		_gest_reset_t -= delta
		if _gest_reset_t <= 0.0:
			_gest_yaw = wrapf(_gest_yaw, -PI, PI) # 复原走最短方向，转过几圈也不倒转回去
			_gest_yaw_t = 0.0
			_gest_pitch_t = 0.0
			_gest_zoom_t = 1.0
	_gest_yaw = lerpf(_gest_yaw, _gest_yaw_t, t)
	_gest_pitch = lerpf(_gest_pitch, _gest_pitch_t, t)
	_gest_zoom = lerpf(_gest_zoom, _gest_zoom_t, t)
	# 聚焦缓动：测试 override > 舞台运镜 > 对话构图（站桩+说话人跟随）> 交互对象 > 玩家（饥荒式相机永远跟着「我」）
	var want := focus_logical
	var lift := 0.0  ## 对话构图的焦点竖直抬升（把双方/说话方框在屏幕竖直中段）
	if focus_override != Vector2.INF:
		want = focus_override
	elif not _stage_cam.is_empty():
		# 演出中脚本说了算：戏在地图哪头演，镜头就跟去哪头——否则孩子只看得见自己站着不动。
		var sc := _stage_cam_shot()
		if not sc.is_empty():
			want = sc["want"]
			_target_dist = sc["dist"]
			lift = sc["lift"]
	elif _phone_cam and not player.is_empty():
		# 手机近身：焦点右移让玩家渲染到屏幕偏左、右侧留给手机；距离/抬升在 _recompute_phone_cam 定。
		want = WorldGrid.wrap_pos(player["logical"] + Vector2(_phone_cam_shift, 0.0))
		lift = _phone_cam_lift
	elif _creation_cam and _locked != null and is_instance_valid(_locked):
		# 创造视图特写：推近仙子单人（背景在暗底下弱化）。焦点右移让仙子渲染到屏幕偏左，
		# 右侧留给 2×2 大卡（方案 A）；抬升把她框在屏幕竖直中段。
		want = WorldGrid.wrap_pos(_find_npc_dict(_locked).get("logical", focus_logical) + Vector2(CREATION_CAM_SHIFT, 0.0))
		_target_dist = CREATION_CAM_DIST
		lift = _char_top(_locked) * 0.6
	elif _locked != null and is_instance_valid(_locked) and not player.is_empty():
		var dc := _dialog_camera()
		want = dc["want"]
		_target_dist = dc["dist"]
		lift = dc["lift"]
	elif _locked != null and is_instance_valid(_locked):
		want = _find_npc_dict(_locked).get("logical", focus_logical)
	elif not player.is_empty():
		want = player["logical"]
	var fd := WorldGrid.shortest_delta(focus_logical, want)
	focus_logical = WorldGrid.wrap_pos(focus_logical + fd * t)
	var fy := float(TerrainMap.tile_height(WorldGrid.to_tile(focus_logical))) * TerrainMap.STEP_HEIGHT + lift
	_cur_focus_y = lerpf(_cur_focus_y, fy, t)
	# 相机随焦点抬升后离地更远，雾距同步外推，山顶视角与平地一样通透
	# （RENDER_RADIUS 110 > 最高补偿后的可见地面半径 ~103，不会露出 chunk 边缘）
	_env.fog_depth_begin = FOG_DEPTH_BEGIN + _cur_focus_y
	_env.fog_depth_end = FOG_DEPTH_END + _cur_focus_y
	_step_sky(delta)
	_update_camera()
	tp = _prof_lap(tp, "cam")
	chunk_manager.update(focus_logical)
	tp = _prof_lap(tp, "chunk")
	_step_remote_actors(delta) # 多人复制：先按缓冲推进被复制 NPC/远端副本的 logical，再统一渲染
	_reposition_npcs(delta)
	_update_npc_notice(delta)  # 近身空闲村民偶尔转头看玩家打招呼（在 reposition 后跑，paper_walk 已更新）
	_update_npc_greetings(delta) # 合格村民主动走过来打招呼（性格×熟识度；见 npc_greeter.gd）
	_update_npc_wishes(delta)  # 近身村民偶尔漏一句心愿（3D 定位音，走近才听清）
	_update_portal_markers()   # 传送门拱随世界滚动（与角色同一套环面最短位移）
	_update_home_portals()     # 回家临时门随世界滚动 + 按 rise 从地下升起/沉下
	tp = _prof_lap(tp, "npcs")
	_update_tap_marker(delta)
	_update_intro_hint(delta)
	_update_refine_indicator(delta)
	_update_place_ghost()
	_update_voice_wave(delta)
	tp = _prof_lap(tp, "tap/wave")
	_update_think_bubble(delta)
	_update_emotion_bubble(delta)
	if _emote_press_cd > 0.0:
		_emote_press_cd -= delta # 表情盘节流：动作播完才能再按
	_update_npc_chats(delta)
	_update_speak_anim(delta)
	tp = _prof_lap(tp, "bubbles")
	_update_hud()
	tp = _prof_lap(tp, "hud")
	if perf_label != null:
		_prof_frame_end()
		_prof_flush(delta)

## 世界卸载/退出：把所有执行器的在途异步寻路任务收干净，防 WorkerThreadPool 在
## 引擎关停时销毁在途任务残留的绑定 Callable 崩溃（真机退出/回测退出 exit 134）。
func _exit_tree() -> void:
	# 离开世界 = 会话（Visit）结束：显式发 leave_world 让服务端 flush 批量抽记忆（掉线由服务端 close 兜底）。
	if backend != null and world_id != "":
		backend.send_leave_world(world_id)
	for ex in _executors:
		ex.cancel()  # 把各自在途寻路任务转孤儿
	BehaviorExecutor.flush_all_blocking()  # 阻塞收完（关停允许阻塞）

## 坐标回报节拍：每 POS_REPORT_INTERVAL 秒扫一次，只上报 tile 变过的角色；全静止则整条消息不发。
const POS_REPORT_INTERVAL := 5.0
## 演出/多人期间的高频世界坐标流间隔（~6.6Hz）：owned actors 实时位置，供他端插值 + 服务端 near 求值。
const POS_STREAM_INTERVAL := 0.15
## 离线占位角色的 id 前缀：这些 id 服务端不认识，绝不能上报（在线时 _bootstrap 已清掉，双保险）。
const _LOCAL_ONLY_IDS := ["demo_", "fairy_local"]
var _pos_report_t := 0.0
var _pos_stream_t := 0.0
var _reported_tiles: Dictionary = {} ## id -> Vector2i，上次已上报的 tile（含玩家，键 PLAYER_ID）

## 多人位置复制（P6，见 docs/script-runtime-design.md）：
## 远端玩家 avatar 的渲染副本（本端无本地节点，收 positions_relay 动态生成 + 插值）。
## actorId -> { node:PaperCharacter, logical:Vector2, id, buf:RemoteActorBuffer, is_remote:true }
var _remote_actors: Dictionary = {}
## 非 host 端被 host 复制驱动的本地 NPC 的插值缓冲：char_id -> RemoteActorBuffer。
## 该 NPC 收到复制位置后转「replicated」：本端停模拟（取消执行器、不 wander），logical 改由缓冲插值。
var _replicated_bufs: Dictionary = {}
## 同场景在场玩家名单（服务端 actors_snapshot/actor_join 下发）：playerId -> {playerId,name,spriteAsset,tile?}。
## 位置流只在人动起来时才发，只靠它的话静止的玩家在本端根本不存在；presence 让进场即可见，
## 并提供 spriteAsset —— 远端玩家据此渲染真实立绘，而不是一个泛蓝的占位小生物。
var _presence: Dictionary = {}
## 玩家喊话态（player-interaction P2，见 docs/player-interaction-design.md）：正在面对的远端玩家 id。
## 「喊话」模型无会话锁——对方端无感知、不被钉住；对方走远/离场/换场景时本端自动退出。
## 只存 id 不存条目引用：副本可能被 stale 回收后经 positions_relay 重建（新字典），按 id 现查才不拿旧物。
var _talk_pid := ""
const TALK_LEAVE_DIST := 7.0 ## 对方走出此距离（logical 米）即自动退出喊话态
# ── 喊话态表情盘（P3）──
var _talk_view: Control            ## 喊话态底部表情盘容器（进态显示，退态隐藏）
## peer playerId → 自动回礼冷却截止（ticks_msec）。发出任何 emote（手动/回礼）都记冷却，
## 这样「A 挥手→B 自动回礼→A 又自动回礼→…」的乒乓在第二拍就断掉。
var _emote_cd_until: Dictionary = {}
var _emote_press_cd := 0.0         ## 表情盘按键节流（动作播完前不重发）
var _my_voice_id := ""             ## 自己的稳定音色（world_state 下发）：喊话复述用，与对端听到的同声
## 表情盘八格（❤=送爱心；flip/squish/paper_plane 是纸片动作精选）。加格子注意
## 卡片宽×格数+间距别超 1280 设计宽（_build_talk_view 的尺寸参数配套调）。
const EMOTE_PANEL_ACTIONS := ["wave", "jump", "spin", "nod", "heart", "flip", "squish", "paper_plane"]
const EMOTE_CD_MS := 8000

## 自动回礼判定（纯函数，headless 可测）：对我做的动作 + 不在冷却期才回。
static func emote_should_autoreply(data: Dictionary, my_pid: String, cd_until_ms: int, now_ms: int) -> bool:
	if my_pid.is_empty() or String(data.get("targetPlayerId", "")) != my_pid:
		return false
	return now_ms >= cd_until_ms

static func _is_local_only_id(id: String) -> bool:
	for prefix in _LOCAL_ONLY_IDS:
		if id.begins_with(prefix):
			return true
	return false

## 挑出 tile 变化过的角色（纯函数，便于回测）。entries 形如 [{id, tileX, tileY}]。
## reported 会被就地更新为本轮上报后的状态。
static func collect_moved(entries: Array, reported: Dictionary) -> Array:
	var out: Array = []
	for e in entries:
		var id := String(e["id"])
		if _is_local_only_id(id):
			continue
		var tile: Vector2i = e["tile"]
		if reported.get(id, Vector2i(-1, -1)) == tile:
			continue
		reported[id] = tile
		out.append({ "id": id, "tileX": tile.x, "tileY": tile.y })
	return out

func _step_positions_report(delta: float) -> void:
	if not online or backend == null or world_id.is_empty() or not backend.is_online():
		return
	# 演出/多人期间走高频世界坐标流；平时维持 5s tile 节流（省流量、供重载读回）。
	if _streaming_active():
		_step_position_stream(delta)
		return
	_pos_report_t += delta
	if _pos_report_t < POS_REPORT_INTERVAL:
		return
	_pos_report_t = 0.0

	var entries: Array = []
	for n in npcs:
		entries.append({ "id": String(n.get("id", "")), "tile": WorldGrid.to_tile(n["logical"]) })
	var moved := collect_moved(entries, _reported_tiles)

	# 玩家单独走 player 字段（Player 表），不混进 chars。
	var player_tile := Vector2i(-1, -1)
	if not player.is_empty():
		var t := WorldGrid.to_tile(player["logical"])
		if _reported_tiles.get(PLAYER_ID, Vector2i(-1, -1)) != t:
			_reported_tiles[PLAYER_ID] = t
			player_tile = t

	if moved.is_empty() and player_tile.x < 0:
		return # 全静止：零流量
	backend.send_positions(world_id, moved, player_tile, _scene_id)

## 是否进入高频复制模式：演出中，或世界里已有其他人（收到过复制位置）。
func _streaming_active() -> bool:
	return _stage_active or not _remote_actors.is_empty()

## host = 本连接负责 NPC 模拟。离线/未握手（_stage 缺省非 host）时也按 host 处理：单机自主 NPC 不受影响。
func _owns_npcs() -> bool:
	return _stage == null or _stage.is_host() or not backend.is_online()

## 高频世界坐标流：广播自己拥有的 actor 的实时世界坐标（玩家总是自己拥有；NPC 仅 host 拥有）。
## tile 仍随流带上供服务端持久化；t 为服务端钟毫秒（本地钟 + 时间偏移），接收端据此对齐插值。
func _step_position_stream(delta: float) -> void:
	_pos_stream_t += delta
	if _pos_stream_t < POS_STREAM_INTERVAL:
		return
	_pos_stream_t = 0.0
	_pos_report_t = 0.0 # 复用同一「上次上报」时钟，退出流模式后不立刻再补发一条

	var chars: Array = []
	if _owns_npcs():
		for n in npcs:
			var id := String(n.get("id", ""))
			if id.is_empty() or _is_local_only_id(id) or n.get("is_fairy", false):
				continue # 仙子是本端装饰随从，不复制
			var lg: Vector2 = n["logical"]
			var tile := WorldGrid.to_tile(lg)
			chars.append({ "id": id, "x": lg.x, "y": lg.y, "tileX": tile.x, "tileY": tile.y })

	var player_msg: Dictionary = {}
	if not player.is_empty():
		var pl: Vector2 = player["logical"]
		var pt := WorldGrid.to_tile(pl)
		player_msg = { "x": pl.x, "y": pl.y, "tileX": pt.x, "tileY": pt.y }

	# C 档球（realtime-game-primitives §5）：只广播【我此刻模拟的】球（中立态由 host、被踢期间由踢者），
	# 携速度供他端外推。球不持久化（服务端不落 tile），故不带 tileX/tileY。
	var balls: Array = []
	if not _stage_balls.is_empty():
		var my_id := backend.player_id
		var host := _owns_npcs()
		for bid in _stage_balls:
			var b: StageBall = _stage_balls[bid]
			if not is_instance_valid(b) or not b.own.simulates(my_id, host):
				continue
			var bl: Vector2 = b.body.logical
			balls.append({ "id": bid, "x": bl.x, "y": bl.y, "vx": b.body.velocity.x, "vy": b.body.velocity.y })

	if chars.is_empty() and player_msg.is_empty() and balls.is_empty():
		return
	backend.send_position_stream(world_id, chars, player_msg, Time.get_ticks_msec() + _stage_offset(), balls)

## 服务端时间偏移（serverMs - 本地钟）；无 stage 大脑时按 0（离线不复制）。
func _stage_offset() -> int:
	return _stage.server_offset_ms() if _stage != null else 0

## 收到其他端复制来的位置：喂各 actor 的插值缓冲（远端玩家动态生成副本；本地 NPC 转 host 驱动）。
func _on_positions_relay(data: Dictionary) -> void:
	var now_local := Time.get_ticks_msec()
	var t := int(data.get("t", now_local + _stage_offset()))
	var chars: Array = data.get("chars", [])
	for e in chars:
		var c: Dictionary = e
		_apply_replicated(String(c.get("id", "")), Vector2(float(c.get("x", 0.0)), float(c.get("y", 0.0))), t, now_local, false)
	var p: Variant = data.get("player", null)
	if p is Dictionary and not (p as Dictionary).is_empty():
		var pd: Dictionary = p
		_apply_replicated(String(pd.get("id", "")), Vector2(float(pd.get("x", 0.0)), float(pd.get("y", 0.0))), t, now_local, true)
	# C 档球：喂对应球的复制缓冲（非模拟者端据此插值/外推渲染）。
	for e in data.get("balls", []):
		var b: Dictionary = e
		_apply_ball_replicated(String(b.get("id", "")),
			Vector2(float(b.get("x", 0.0)), float(b.get("y", 0.0))),
			Vector2(float(b.get("vx", 0.0)), float(b.get("vy", 0.0))), t, now_local)

## 把一条复制球位置喂进对应球的缓冲。我若是该球模拟者（权威）则忽略（不吃自己的回声）。
func _apply_ball_replicated(id: String, pos: Vector2, vel: Vector2, t: int, now_local: int) -> void:
	if id.is_empty():
		return
	var ball: StageBall = _stage_balls.get(id)
	if ball == null or not is_instance_valid(ball):
		return # 本端还没 spawn 到这颗球（spawn_ball 广播随后会补齐）
	if ball.own.simulates(backend.player_id, _owns_npcs()):
		return
	ball.buf.push(t, pos, vel, now_local)

## 把一条复制位置喂进对应缓冲。is_player=远端玩家 avatar（渲染副本）；否则=NPC（非 host 端驱动本地节点）。
func _apply_replicated(id: String, pos: Vector2, t: int, now_local: int, is_player: bool) -> void:
	if id.is_empty() or id == backend.player_id or id == PLAYER_ID:
		return # 自己的 avatar 不建副本（服务端已排除发送者，双保险）
	if not is_player:
		if _owns_npcs():
			return # host 自己模拟 NPC，忽略任何 NPC 复制（理论上收不到自己发的）
		var n := _find_npc(id)
		if not n.is_empty():
			var buf: RemoteActorBuffer = _replicated_bufs.get(id)
			if buf == null:
				buf = RemoteActorBuffer.new()
				_replicated_bufs[id] = buf
				_halt_npc_for_replication(n) # 停本端自主模拟，改吃 host 复制位置
			n["replicated"] = true
			buf.push(t, pos, now_local)
			return
		# 本端没有的 NPC（角色列表没同步到）→ 落到远端副本渲染
	var ra: Dictionary = _remote_actors.get(id, {})
	if ra.is_empty():
		# presence 通常已经先把副本立起来了；这里是兜底（快照丢了/本端还没收到 join）。
		var p: Dictionary = _presence.get(id, {})
		var panch: Variant = p.get("anchors")
		var patts: Variant = p.get("attachments")
		ra = _spawn_remote_actor(id, pos, String(p.get("spriteAsset", "")), String(p.get("name", "")),
			panch if typeof(panch) == TYPE_DICTIONARY else {},
			patts if typeof(patts) == TYPE_ARRAY else [])
		_remote_actors[id] = ra
	(ra["buf"] as RemoteActorBuffer).push(t, pos, now_local)

func _find_npc(id: String) -> Dictionary:
	for n in npcs:
		if String(n.get("id", "")) == id:
			return n
	return {}

## 该 NPC 转为「被复制驱动」：取消其一切执行器（wander/stage 走位跟随），本端不再自主移动它。
func _halt_npc_for_replication(n: Dictionary) -> void:
	for ex in _executors:
		if (ex as BehaviorExecutor).drives(n):
			(ex as BehaviorExecutor).cancel()
	_executors = _executors.filter(func(e: BehaviorExecutor) -> bool: return not e.drives(n))
	_stage_holds = _stage_holds.filter(func(e: BehaviorExecutor) -> bool: return not e.drives(n))
	_stage_drives = _stage_drives.filter(func(m: Dictionary) -> bool: return not (m["ex"] as BehaviorExecutor).drives(n))

## 远端玩家 avatar 的渲染副本。先用占位立起来（网络往返期间也得有个人在那儿），
## 拿到 presence 的 spriteAsset 就换成那个小朋友的真实立绘（与本地玩家同一套归一化）。
func _spawn_remote_actor(id: String, pos: Vector2, sprite := "", disp_name := "", anchors := {}, attachments := []) -> Dictionary:
	var node := PaperCharacter.new()
	add_child(node)
	var label := disp_name if not disp_name.is_empty() else id
	node.setup(critter_tex, Color(0.86, 0.92, 1.0), label) # setup 内部归一尺寸 + 挂脚下暗斑
	# anchors 由 presence 转发（服务端 §5）：别人看到的我，贴纸位吃真锚点；缺省（老档）留空走 alpha 兜底。
	# attachments 同经 presence 转发：别人看到我戴的贴纸，真立绘就位后按正确尺寸挂上（见 _apply_player_sprite_to）。
	_apply_player_sprite_to(node, sprite, anchors, attachments) # fire-and-forget：空 asset 直接返回，图到了替换占位
	return { "node": node, "logical": pos, "id": id, "buf": RemoteActorBuffer.new(), "is_remote": true }

## 在场名单（进世界/换场景一次性下发）：把同场景的其他小朋友立起来——包括站着不动的。
func _on_actors_snapshot(data: Dictionary) -> void:
	if String(data.get("sceneId", "")) != _scene_id:
		return
	for a in data.get("actors", []):
		_upsert_presence(a as Dictionary)

## 某玩家进场：立起他的副本（带真实立绘）。
func _on_actor_join(data: Dictionary) -> void:
	if String(data.get("sceneId", "")) != _scene_id:
		return
	_upsert_presence(data.get("actor", {}) as Dictionary)

## 记下在场玩家并立刻立起副本。初始位置用服务端存的 tile（没有就落在镜头焦点附近），
## 之后由 positions_relay 的插值缓冲接管——所以这里只需要一个「不突兀」的起点。
func _upsert_presence(a: Dictionary) -> void:
	var pid := String(a.get("playerId", ""))
	if pid.is_empty() or pid == backend.player_id:
		return # 自己不建副本
	_presence[pid] = a
	if _remote_actors.has(pid):
		return
	var tile: Variant = a.get("tile", null)
	var pos := focus_logical
	if tile is Dictionary and (tile as Dictionary).has("tileX"):
		pos = Vector2(float(tile["tileX"]), float(tile["tileY"]))
	var anch: Variant = a.get("anchors")
	var atts: Variant = a.get("attachments")
	_remote_actors[pid] = _spawn_remote_actor(pid, pos, String(a.get("spriteAsset", "")), String(a.get("name", "")),
		anch if typeof(anch) == TYPE_DICTIONARY else {},
		atts if typeof(atts) == TYPE_ARRAY else [])

## 别人造出了新伙伴：本端就地降生（否则要重进场景才看得到它）。
func _on_character_spawned(data: Dictionary) -> void:
	if String(data.get("sceneId", "")) != _scene_id:
		return
	var c: Dictionary = data.get("character", {})
	var cid := String(c.get("id", ""))
	if cid.is_empty() or not _find_npc(cid).is_empty():
		return # 已经有了（自己造的那份走 gen_complete 降生）
	await _spawn_server_character(c, Vector2.INF)

## 升任 host（原 host 掉线重指派）：立即收回本端被复制驱动的 NPC，恢复本端自主模拟。
## 非升任（降为非 host，理论不发生——host 只增不减直到掉线）时不动。
func _on_world_host_changed(is_host: bool) -> void:
	if not is_host:
		return
	for id in _replicated_bufs.keys():
		var n := _find_npc(id)
		if not n.is_empty():
			n["replicated"] = false
			if not _stage_active and not n.get("is_fairy", false):
				_start_ambient_wander(n) # 演出中静候舞台命令；非演出恢复闲逛
	_replicated_bufs.clear()

## 某玩家离场：即时移除其远端副本节点（不等插值缓冲陈旧回收）。
func _on_actor_leave(player_id: String) -> void:
	if player_id.is_empty():
		return
	if player_id == _talk_pid:
		_exit_player_talk() # 正面对的小朋友退出了游戏：立即解锁，别对着空气
	_presence.erase(player_id)
	var ra: Dictionary = _remote_actors.get(player_id, {})
	if ra.is_empty():
		return
	_free_remote_actor(ra)
	_remote_actors.erase(player_id)

## 释放一个远端副本的挂件（立绘节点 + 头顶表情泡）。erase 前调用，别留孤儿 Sprite3D。
func _free_remote_actor(ra: Dictionary) -> void:
	var node: Variant = ra.get("node", null)
	if node != null and is_instance_valid(node):
		(node as Node).queue_free()
	var bub: Variant = ra.get("notice_bubble", null)
	if bub != null and is_instance_valid(bub):
		(bub as Node).queue_free()

## 清掉所有远端副本与在场名单（换场景时调用：旧场景的人不在新场景里）。
func _clear_remote_actors() -> void:
	_exit_player_talk() # 面对的人随旧场景清掉，喊话态一并退
	for id in _remote_actors.keys():
		_free_remote_actor(_remote_actors[id])
	_remote_actors.clear()
	_replicated_bufs.clear()
	_presence.clear()

## 每帧：按插值缓冲推进被复制的本地 NPC 与远端副本的 logical；缓冲陈旧（拥有者停流/掉线）则回收/恢复自主。
func _step_remote_actors(_delta: float) -> void:
	if _replicated_bufs.is_empty() and _remote_actors.is_empty():
		return
	var now_local := Time.get_ticks_msec()
	var render_ms := now_local + _stage_offset() # 渲染时刻换算到服务端钟，与发送端同一时间轴
	# 被复制的本地 NPC
	for id in _replicated_bufs.keys():
		var buf: RemoteActorBuffer = _replicated_bufs[id]
		var n := _find_npc(id)
		if n.is_empty():
			_replicated_bufs.erase(id)
			continue
		if buf.is_stale(now_local):
			_replicated_bufs.erase(id) # 拥有者停流/掉线：恢复本端自主
			n["replicated"] = false
			if not _stage_active and not n.get("is_fairy", false):
				_start_ambient_wander(n)
			continue
		n["logical"] = buf.sample(render_ms, n["logical"])
	# 远端玩家副本
	for id in _remote_actors.keys():
		var ra: Dictionary = _remote_actors[id]
		var buf2: RemoteActorBuffer = ra["buf"]
		if buf2.is_stale(now_local):
			_free_remote_actor(ra)
			_remote_actors.erase(id)
			continue
		ra["logical"] = buf2.sample(render_ms, ra["logical"])
		_animate_notice_bubble(ra, _delta) # emote 表情泡跟头顶（与村民打招呼泡同一套演出）
	# 喊话态维持判定：对方副本没了（掉线回收）或走远了 → 自动退出，不把孩子钉在空位前
	if not _talk_pid.is_empty():
		var tra: Dictionary = _remote_actors.get(_talk_pid, {})
		if tra.is_empty():
			_exit_player_talk()
		elif not player.is_empty() \
				and WorldGrid.shortest_delta(player["logical"], tra["logical"]).length() > TALK_LEAVE_DIST:
			_exit_player_talk()

func _step_executors(delta: float) -> void:
	# benchmark 采样期【不冻结】村民：让固定巡逻（A* 寻路 + 走动 CPU）全程计入 p95，才是弱机真实卡顿来源。
	# （真机 PoC 实证：冻死静态场景无逐帧 CPU 尖峰、p95 假性达标 → 采纳过高档 → 真机反而卡；见 bench-determinism。）
	for ex in _executors:
		ex.step(delta)
	# 单趟分拣（旧版两次 filter 每帧各分配一个数组+Callable，无人完成时纯浪费）
	var done: Array = []
	var has_done := false
	for ex in _executors:
		if (ex as BehaviorExecutor).is_done():
			has_done = true
			break
	if not has_done:
		return
	var alive: Array = []
	for ex in _executors:
		if (ex as BehaviorExecutor).is_done():
			done.append(ex)
		else:
			alive.append(ex)
	_executors = alive
	# 指令跑完的村民恢复自主闲逛，否则永远呆立。被替换（已有新执行器）、
	# 正被交互叫停（_stopped/selected）、玩家、小仙子都不恢复。
	# 观演/游戏态：演出角色跑完一条命令不自作主张闲逛，静候下一条舞台命令。
	if _stage_active:
		return
	for e in done:
		for n in npcs:
			if (e as BehaviorExecutor).drives(n):
				_resume_ambient(n)
				break

## 恢复某角色的自主闲逛。玩家、小仙子、正被交互叫停（_stopped/selected/in_chat）、
## 已有别的执行器在驱动的，都不动——避免用闲逛盖掉刚下发的指令。
func _resume_ambient(n: Dictionary) -> void:
	if n.is_empty() or n.get("id", "") == PLAYER_ID or n.get("is_fairy", false) \
			or n == _stopped or n.get("in_chat", false) \
			or (selected != null and n.get("node") == selected) \
			or _has_executor_for(n):
		return
	_start_ambient_wander(n)

## 有执行器**正在**驱动这个角色吗。cancel 过的（is_done）不算：它当帧还赖在 _executors 里
## 等 _step_executors 回收，若算数就会挡住紧接着的闲逛恢复（收场时演员集体呆立）。
func _has_executor_for(dict: Dictionary) -> bool:
	for ex in _executors:
		if not (ex as BehaviorExecutor).is_done() and (ex as BehaviorExecutor).drives(dict):
			return true
	return false

## 有【非 ambient】执行器（真任务：送信/跑腿/正在被主动迎接的 follow）正在驱动这个角色吗。
## 主动社交资格判定用它——ambient 闲逛不算忙，否则每个村民默认都在闲逛就永远没人能被拉去迎接
## （主动迎接本就用 _run_behavior 抢占闲逛，见 _update_npc_greetings 的 approach 分支）。
func _has_task_executor_for(dict: Dictionary) -> bool:
	for ex in _executors:
		var e := ex as BehaviorExecutor
		if not e.is_done() and e.drives(dict) and not e.ambient:
			return true
	return false

func _reposition_npcs(delta: float) -> void:
	# 固定小倾角：随当前相机角度调（站立感 + 面向相机的折中），绕脚底前倾；含手势俯仰偏移
	var lean := deg_to_rad((90.0 - clampf(_cur_pitch + _gest_pitch, GESTURE_PITCH_MIN, GESTURE_PITCH_MAX)) * SPRITE_LEAN_FACTOR)
	for n in npcs:
		_place_char(n, lean, delta)
	if not player.is_empty():
		_place_char(player, lean, delta)
	for id in _remote_actors: # 远端玩家副本：与本地角色同一套弯地表摆放 + 纸片动作
		_place_char(_remote_actors[id], lean, delta)

## 按角色字典的逻辑坐标摆到弯曲地表（含台阶高度跟随，短 lerp 平滑 2m 跳变）。
func _place_char(n: Dictionary, lean: float, delta: float) -> void:
	var d: Vector2 = WorldGrid.shortest_delta(focus_logical, n["logical"])
	var node: Node3D = n["node"]
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(n["logical"]))) * TerrainMap.STEP_HEIGHT
	var ry := lerpf(float(n.get("ry", ty)), ty, minf(1.0, 12.0 * delta))
	n["ry"] = ry
	_place_on_bent_ground(node, Vector3(d.x, ry + float(n.get("hover", 0.0)), d.y))
	_update_paper_motion(n, node as PaperCharacter, lean, delta)
	# 参演光环寄生在角色节点下（跟着走位/弯曲），但纸片的倾角/摇摆/点头会把它一起掀起来，
	# 转身时 lean 还随 cos(fry) 反号——直接钉死世界基，让它永远平躺在脚下。
	var ring: Variant = n.get("stage_ring")
	if ring != null and is_instance_valid(ring):
		(ring as Node3D).global_basis = STAGE_RING_BASIS

## 纸片动作演出（每帧）：走路左右摇摆+下摆飘动 / 横向变向绕竖轴翻面 / 待机呼吸微卷。
## 朝向约定：立绘统一朝右（sprite_style.ts），ry=0 朝右、ry=PI 背面即水平镜像=朝左；
## 翻面中途侧对相机变成一条纸边——纸片马里奥的标志性转身。
## 动画状态记在角色字典（paper_* 键），节点只吃结果，无需自带脚本。
func _update_paper_motion(n: Dictionary, node: PaperCharacter, lean: float, delta: float) -> void:
	var cur: Vector2 = n["logical"]
	# 小跳中：冻结位移速度（不触发走路摇摆/换面），保持进对话设定的相对朝向，只做翻面收敛
	if bool(n.get("_hop", false)):
		n["paper_prev"] = cur
		var face_h := float(n.get("paper_face", 0.0))
		var fry_h := move_toward(float(n.get("paper_fry", face_h)), face_h, FLIP_SPEED * delta)
		n["paper_fry"] = fry_h
		node.rotation = Vector3(-lean * cos(fry_h), fry_h + _gest_yaw, 0.0)
		node.set_paper_motion(0.0, 0.0)
		_update_anim_clip(n, node, 0.0) # 小跳中位移被冻结 = 不算走路（但可能在说话）
		return
	var vel := WorldGrid.shortest_delta(n.get("paper_prev", cur), cur) / maxf(delta, 0.0001)
	n["paper_prev"] = cur
	# 朝向目标：横向速度超过阈值才换面（防原地抖动）；纵向移动保持上次朝向
	var face := float(n.get("paper_face", 0.0))
	if absf(vel.x) > FACE_MOVE_EPS:
		face = 0.0 if vel.x > 0.0 else PI
		n["paper_face"] = face
	var fry := move_toward(float(n.get("paper_fry", face)), face, FLIP_SPEED * delta)
	n["paper_fry"] = fry
	# 走路强度 0..1（缓动）：驱动摇摆/飘动，停步平滑归零
	var w := lerpf(float(n.get("paper_walk", 0.0)), clampf(vel.length() / PLAYER_SPEED, 0.0, 1.0), minf(1.0, 10.0 * delta))
	n["paper_walk"] = w
	var phase := float(n.get("paper_phase", randf() * TAU)) + delta * TAU * WALK_SWAY_HZ
	n["paper_phase"] = phase
	var sway := deg_to_rad(WALK_SWAY_DEG) * w * sin(phase)
	node.position.y += walk_bob(w, phase) # 踏步弹跳（走路是程序化的，没有 moving 图集段）
	# 翻面后节点本地 X 轴反向，倾角随 cos(fry) 连续反号才始终「顶朝远离相机」；
	# 相机手势环绕时整体加 _gest_yaw（Y 最外层）保持纸面正对相机方位
	node.rotation = Vector3(-lean * cos(fry), fry + _gest_yaw, sway)
	# 待机呼吸微卷用慢相位（走动时让位给飘动）；飘动幅度随走路强度
	node.set_paper_motion(WALK_FLUTTER * w, IDLE_CURL * (1.0 - w) * sin(phase * 0.22))
	_update_anim_clip(n, node, w)
	_update_action_anim(n, node, delta)

## 按角色状态选 sprite-sheet 动画段：talking > moving > idle。
## set_clip 对「已经是这一段」是零成本快路径（只比一个字符串），所以每帧调没问题。
## 只有拿到了动画图集的角色才有段可切；还是静态立绘的（图集没到/生成失败）current_clip 为空，直接跳过。
##
## 注意这里的分层：段（sprite 帧）管「角色本身在做什么」，而 set_paper_motion/action_pose
## 那套顶点位移管「纸片被怎么摆弄」。两者叠加——走路时既播 moving 帧，又有纸片摇摆飘动。
func _update_anim_clip(n: Dictionary, node: PaperCharacter, walk: float) -> void:
	if node == null or node.current_clip().is_empty():
		return
	var r := pick_clip(_is_char_speaking(n, node), walk, bool(n.get("clip_moving", false)))
	n["clip_moving"] = bool(r[1])
	node.set_clip(String(r[0]))

## 踏步弹跳（米，加到脚底高度上）。纯函数，供单测。
## |sin| 而非 sin：走路摇摆一个周期里左右脚各落一次地，弹跳要一个周期颠两下，且恒为正
## （只往上颠，不会把角色压进地里）。幅度随走路强度缩放，停步自然归零。
static func walk_bob(walk: float, phase: float) -> float:
	return WALK_BOB * walk * absf(sin(phase))

## 段选择的纯函数（同 action_pose 的路子：判定逻辑可单测，应用层只负责灌进节点）。
## 返回 [段名, 新的 moving 态]；was_moving 传上一帧的 moving 态以实现滞回。
##
## 滞回是必需的：paper_walk 是缓动量，单阈值会让角色在起步/刹车经过阈值的那几帧来回抖段。
## 进 moving 要越过 CLIP_MOVE_ON(0.30)，退回 idle 要落到 CLIP_MOVE_OFF(0.12) 以下。
## 说话优先级最高——村民边走边被搭话时，嘴动比腿动重要。
static func pick_clip(speaking: bool, walk: float, was_moving: bool) -> Array:
	var moving := was_moving
	if moving:
		if walk < CLIP_MOVE_OFF:
			moving = false
	elif walk > CLIP_MOVE_ON:
		moving = true
	if speaking:
		return ["talking", moving]
	return ["moving" if moving else "idle", moving]

## 这个角色此刻在出声吗——三个来源，与 _update_speak_anim 的说话判定同源：
##   ① 对话 TTS：只有当前对话对象（selected）会出声，_tts_player 是全局单播放器
##   ② 仙子预制语音（fairy_voice）
##   ③ 村民心愿漏话（npc_wish_voice，per-character 的 3D 定位音）
## 玩家自己没有 TTS，恒为假（他说话是对着麦克风，不是角色出声）。
func _is_char_speaking(n: Dictionary, node: PaperCharacter) -> bool:
	if node == selected and _tts_player != null and _tts_player.playing:
		return true
	if bool(n.get("is_fairy", false)):
		return fairy_voice != null and fairy_voice.is_playing()
	if npc_wish_voice != null:
		return npc_wish_voice.is_character_speaking(String(n.get("id", "")))
	return false

## 指令动作演出（do_action 契约键 paper_action，见 BehaviorExecutor.ACTION_DUR）：
## 动作数学在纯函数 action_pose（可单测），这里只负责应用与生命周期（推进 t/清键/scale 复位）。
## 旋转/位移叠加在正常姿态之上（姿态每帧重算，加性安全）；scale 无人复位，动作层自管：
## 动作期间写绝对值，结束硬复位 ONE，动作被外部清除（交互叫停等）时弹性回正兜底。
const _FOLD_ID := Vector4(0.0, 0.0, 0.0, 1.0) ## 恒等折痕（角度 0，方向占位竖直）

func _update_action_anim(n: Dictionary, node: PaperCharacter, delta: float) -> void:
	var action := String(n.get("paper_action", ""))
	if action.is_empty():
		if node.scale != Vector3.ONE: # 动作中途被外部清键：scale 弹性回正
			node.scale = node.scale.lerp(Vector3.ONE, minf(1.0, 12.0 * delta))
			if node.scale.is_equal_approx(Vector3.ONE):
				node.scale = Vector3.ONE
		node.set_paper_fold(_FOLD_ID, 0.0, _FOLD_ID, 0.0, 0.0, 0.0) # 外部清键兜底（恒等零上传）
		return
	var t := float(n.get("paper_action_t", 0.0)) + delta
	var dur := float(BehaviorExecutor.ACTION_DUR.get(action, 1.2))
	if t >= dur:
		n.erase("paper_action")
		n.erase("paper_action_t")
		node.scale = Vector3.ONE
		node.set_paper_fold(_FOLD_ID, 0.0, _FOLD_ID, 0.0, 0.0, 0.0)
		return
	n["paper_action_t"] = t
	var p := action_pose(action, t, dur)
	node.rotation += p["rot"] as Vector3
	node.position.y += float(p["y"])
	if p.has("xz"): # 视觉位移（纸飞机绕圈）：只动渲染节点，逻辑坐标/占用图不动
		var xz := p["xz"] as Vector2
		node.position.x += xz.x
		node.position.z += xz.y
	var sc := p["scale"] as Vector3
	if sc != Vector3.ONE:
		node.scale = sc
	elif node.scale != Vector3.ONE: # 本动作不用 scale 但残留了旧值（动作被新动作顶替）
		node.scale = Vector3.ONE
	if p.has("motion"): # 覆盖本帧呼吸/走路的 shader 参数（下一帧姿态层自动恢复）
		var m := p["motion"] as Vector2
		node.set_paper_motion(m.x, m.y)
	# 折纸机关：折纸类动作逐帧驱动；其余动作恒等调用=零上传快路径（并顺手清掉顶替残留）
	var f: Dictionary = p.get("fold", {})
	node.set_paper_fold(
		f.get("f1", _FOLD_ID), float(f.get("a1", 0.0)),
		f.get("f2", _FOLD_ID), float(f.get("a2", 0.0)),
		float(f.get("pleat", 0.0)), float(f.get("crumple", 0.0)))

## 「起-保持-收」包络：[0,up] 平滑升到 1，保持，[down,1] 平滑落回 0。翻面/躺平类动作用。
static func _hold_env(k: float, up: float, down: float) -> float:
	return smoothstep(0.0, up, k) * (1.0 - smoothstep(down, 1.0, k))

## 纯函数（可单测）：动作在 t 时刻的演出偏移。26 种纸片动作的动画数学单一来源。
## 返回 { "rot": Vector3 加性欧拉角, "y": float 加性抬升, "scale": Vector3 绝对值（ONE=不动）,
## "motion": Vector2(flutter, curl) 仅在覆盖 shader 纸形变时存在,
## "xz": Vector2 视觉平移 仅纸飞机绕圈存在,
## "fold": {f1,a1,f2,a2,pleat,crumple} 仅折纸类动作存在（格式见 paper_character.gdshader）}。
## 朝向约定：相机在 +Z；rotation.x 正=顶朝相机倒（扑街脸着地），负=后仰（躺平脸朝天）。
static func action_pose(action: String, t: float, dur: float) -> Dictionary:
	var k := clampf(t / dur, 0.0, 1.0)
	var e := sin(k * PI) # 通用起收包络
	var rot := Vector3.ZERO
	var y := 0.0
	var sc := Vector3.ONE
	var motion := Vector2.INF # INF = 不覆盖
	var fold := {}
	var xz := Vector2.INF # INF = 无视觉平移
	match action:
		# —— 基础 4 种（与旧版一致）——
		"wave":
			rot.z = deg_to_rad(16.0) * sin(t * TAU * 2.2) * e
		"jump":
			y = absf(sin(k * PI * 2.0)) * 1.4 # 两小跳
		"spin":
			rot.y = TAU * smoothstep(0.0, 1.0, k) # 一整圈，中途露纸边
		"nod":
			rot.x = deg_to_rad(12.0) * sin(t * TAU * 1.6) * e
		# —— 翻滚旋转 ——
		"flip": # 前滚翻：绕 X 一整圈 + 抛物线小跳
			rot.x = TAU * smoothstep(0.0, 1.0, k)
			y = e * 1.3
		"backflip": # 后空翻：反向整圈 + 跳更高
			rot.x = -TAU * smoothstep(0.0, 1.0, k)
			y = e * 1.8
		"cartwheel": # 侧手翻：绕 Z 滚一整圈
			rot.z = TAU * smoothstep(0.0, 1.0, k)
			y = e * 0.8
		"twirl": # 芭蕾旋：快转两圈 + 微微踮起
			rot.y = 2.0 * TAU * smoothstep(0.0, 1.0, k)
			y = e * 0.5
		"helicopter": # 直升机：匀速狂转，边升空边飘落
			rot.y = 3.0 * TAU * k
			y = e * 2.4
			motion = Vector2(0.12 * e, 0.0) # 轻飘动强化"被风带起"
		# —— 纸片专属梗 ——
		"paperflip": # 翻面：转 180° 停一拍露镜像背面再转回
			rot.y = PI * _hold_env(k, 0.25, 0.75)
		"peek": # 侧身隐身：转到 90° 侧立成一条纸边，停一拍闪回
			rot.y = (PI / 2.0) * _hold_env(k, 0.2, 0.8)
		"lie_down": # 躺平：绕脚底后仰脸朝天躺一拍，再弹起。80°+抬升——90° 纯平会整张
			# 陷进弯曲地表（world-bending 地面随距离上翘，带窗实录里角色完全消失）
			var lie := _hold_env(k, 0.2, 0.85)
			rot.x = -deg_to_rad(80.0) * lie
			y = 0.6 * lie
		"faceplant": # 扑街：快速前扑趴平（脸着地），慢慢爬起
			rot.x = (PI / 2.0) * _hold_env(k, 0.12, 0.72)
		# —— 纸形变（shader curl/flutter）——
		"curl_up": # 卷纸筒：curl 拉满卷起，整体转一圈再展开
			motion = Vector2(0.0, 1.1 * e)
			rot.y = TAU * smoothstep(0.0, 1.0, k)
		"shiver": # 瑟瑟发抖：flutter 高频爆发 + 微缩 + 小幅高频摆
			motion = Vector2(0.3 * e, 0.15 * e)
			rot.z = deg_to_rad(2.5) * sin(t * 50.0) * e
			sc = Vector3.ONE * (1.0 - 0.06 * e)
		"wiggle": # 扭扭舞：大幅慢波 S 形扭动 + 左右摆
			motion = Vector2(0.45 * e, 0.0)
			rot.z = deg_to_rad(10.0) * sin(t * TAU * 1.5) * e
		"puff": # 挺胸鼓气：反向 curl 朝相机鼓起 + 微胀
			motion = Vector2(0.0, -0.55 * e)
			sc = Vector3.ONE * (1.0 + 0.06 * e)
		# —— squash & stretch ——
		"bounce": # 弹弹球三连跳：落地压扁、腾空拉长（首末淡入淡出防起收突跳）
			var s := absf(sin(k * PI * 3.0))
			var ramp := clampf(sin(k * PI) * 3.0, 0.0, 1.0)
			y = s * 1.1
			var sy := 1.0 + (lerpf(0.75, 1.15, s) - 1.0) * ramp
			sc = Vector3(1.0 + (1.0 - sy) * 0.6, sy, 1.0)
		"squish": # 拍扁：压到 30% 高摊宽，再 Q 弹回
			var env := _hold_env(k, 0.25, 0.6)
			sc = Vector3(1.0 + 0.55 * env, 1.0 - 0.7 * env, 1.0)
		"stretch": # 长高高：拉到 140% 高变窄，微微晃
			var env2 := _hold_env(k, 0.3, 0.7)
			sc = Vector3(1.0 - 0.22 * env2, 1.0 + 0.4 * env2, 1.0)
			rot.z = deg_to_rad(6.0) * sin(t * TAU * 1.2) * env2
		# —— 折纸（shader 折痕机关）——
		"fold": # 对折躲猫猫：沿竖中线把左半张朝相机折过来盖住右半，停一拍弹开
			var fe := _hold_env(k, 0.25, 0.75)
			fold = { "f1": Vector4(0.0, 0.0, 0.0, 1.0), "a1": deg_to_rad(165.0) * fe }
			rot.y = deg_to_rad(-14.0) * fe # 微侧身让对折立体可读
		"bow_fold": # 折纸鞠躬：上半张沿横中线向前折下（道谢/道歉）
			var be := _hold_env(k, 0.3, 0.7)
			fold = { "f1": Vector4(0.0, 0.55, 1.0, 0.0), "a1": deg_to_rad(115.0) * be }
		"corner_wink": # 折角卖萌：右上角沿斜痕折下来再弹回，像给书页折个角。
			# 痕要切得深（穿过头/耳区）：立绘内容居中，四角是透明 alpha，浅痕折了个寂寞
			var ce := _hold_env(k, 0.25, 0.55)
			fold = { "f1": Vector4(-0.1, 0.9, 0.93, -0.38), "a1": deg_to_rad(140.0) * ce }
			rot.z = deg_to_rad(-4.0) * ce # 顺势歪头
		"paper_plane": # 纸飞机：两肩向后折成箭头，前倾滑翔原地绕一小圈再展开
			var pe := _hold_env(k, 0.22, 0.8)
			# 两条痕都从头顶中点出发：f1 向右下（法侧=右肩）、f2 向右上（法侧=左肩），
			# 角度同为负=向后（-Z）折；痕线方向决定法侧在哪半边，改动须重验折的是肩不是身
			fold = {
				"f1": Vector4(0.0, 1.0, 0.48, -0.88), "a1": -deg_to_rad(120.0) * pe,
				"f2": Vector4(0.0, 1.0, 0.48, 0.88), "a2": -deg_to_rad(120.0) * pe,
			}
			rot.x = deg_to_rad(55.0) * pe # 机头前倾
			var prog := smoothstep(0.2, 0.8, k) # 飞行段：绕圈一周
			rot.y = TAU * prog
			xz = Vector2(sin(TAU * prog), cos(TAU * prog) - 1.0) * 1.0
			y = e * 1.2
		"accordion": # 风琴折：zigzag 折成半高的小风琴，"啵"地弹开
			var ae := _hold_env(k, 0.3, 0.65)
			fold = { "pleat": 0.32 * ae }
			sc = Vector3(1.0 + 0.12 * ae, 1.0 - 0.45 * ae, 1.0)
			rot.z = deg_to_rad(5.0) * sin(t * TAU * 3.0) * e * (1.0 - ae) # 弹开时的余晃
		"crumple_ball": # 揉纸团：揉皱缩成一团滚一整圈，再展开抖平
			var re := _hold_env(k, 0.3, 0.7)
			fold = { "crumple": 0.45 * re }
			sc = Vector3.ONE * (1.0 - 0.5 * re)
			# 旋转绕的是脚底锚点：不抬升的话滚到侧面/头朝下时整团甩进地里（实录实证）。
			# 按 y=R(1-cosθ) 抬升让"纸团中心"保持定高≈贴地滚动；整圈收尾角度归零不跳变
			var roll := TAU * smoothstep(0.15, 0.85, k)
			rot.z = roll
			y = 1.5 * (1.0 - cos(roll)) # R≈缩团后半高，θ=π 时抬满一个团高，脚底锚点滚不进地
	var p := { "rot": rot, "y": y, "scale": sc }
	if motion != Vector2.INF:
		p["motion"] = motion
	if not fold.is_empty():
		p["fold"] = fold
	if xz != Vector2.INF:
		p["xz"] = xz
	return p

## 纯判定（可单测）：近身空闲村民本帧是否该打招呼。busy=选中/聊天/叫停/正在做动作。
## size_scale=目标体型（明显档 0.7~1.4）：大角色注意半径同比放大，更早注意到玩家（缺省 1.0 不变）。
static func notice_ready(dist: float, walk: float, busy: bool, cd: float, size_scale := 1.0) -> bool:
	return cd <= 0.0 and not busy and walk <= NOTICE_WALK_EPS and dist <= NOTICE_RADIUS * size_scale

## 「主动看你」（借鉴 Pokopia「生物即角色」）：每帧扫描村民，近身且站定的空闲村民
## 冷却到点时转头面向玩家 + 随机挥手/点头，让世界里的小伙伴主动注意到你而非呆立。
## 仅村民；仙子/被选中/聊天中/被叫停/正在做动作/走动中的都跳过。
func _update_npc_notice(delta: float) -> void:
	if player.is_empty():
		return
	# 已弹出的气泡永远继续 pop/淡出/跟头顶（即便随后暂停触发，也让它自然收尾）
	for n in npcs:
		_animate_notice_bubble(n, delta)
	# 有脚本化互动进行中（送信/跑腿/靠近对话等非 ambient 执行器）时暂停触发新的打招呼，
	# 让脚本场景读得干净、不被随机挥手污染演出与信号。
	for e in _executors:  # 手写循环替代 any(lambda)：省每帧一个 Callable 分配
		if not (e as BehaviorExecutor).ambient:
			return
	var pl: Vector2 = player["logical"]
	for n in npcs:
		if n.get("is_fairy", false):
			continue
		if not n.has("notice_cd"):  # 首次见到：随机初始冷却，天然错峰
			n["notice_cd"] = randf_range(NOTICE_CD_MIN, NOTICE_CD_MAX)
		var cd := float(n["notice_cd"]) - delta
		n["notice_cd"] = cd
		if cd > 0.0:
			continue
		var node := n["node"] as PaperCharacter
		var busy: bool = n == _stopped or bool(n.get("in_chat", false)) \
				or (selected != null and node == selected) \
				or not String(n.get("paper_action", "")).is_empty()
		var d := WorldGrid.shortest_delta(n["logical"], pl)
		if not notice_ready(d.length(), float(n.get("paper_walk", 0.0)), busy, cd, float(n.get("scale", 1.0))):
			# 忙碌/走动中：保持到点（不惩罚性重置），条件一解除即打招呼；
			# 只是玩家不在近旁：短歇再看，省得每帧算距离。
			n["notice_cd"] = 0.0 if (busy or float(n.get("paper_walk", 0.0)) > NOTICE_WALK_EPS) \
					else randf_range(NOTICE_CD_MIN, NOTICE_CD_MAX) * 0.5
			continue
		# 触发：转头面向玩家（立绘朝右为 0）+ 随机挥手/点头 + 头顶小表情气泡，重置冷却
		n["paper_face"] = 0.0 if d.x >= 0.0 else PI
		n["paper_action"] = "wave" if randf() < 0.6 else "nod"
		n["paper_action_t"] = 0.0
		_pop_notice_bubble(n)
		n["notice_cd"] = randf_range(NOTICE_CD_MIN, NOTICE_CD_MAX)

## 在角色头顶弹一个小表情气泡（per-角色懒建 Sprite3D，不复用 selected 单例的 emotion_bubble）。
## emotion 显式给定用那张（玩家 emote 互动）；空串保持旧行为随机友好表情（村民主动打招呼）。
func _pop_notice_bubble(n: Dictionary, emotion := "") -> void:
	var bub := n.get("notice_bubble") as Sprite3D
	if bub == null or not is_instance_valid(bub):
		bub = UiAssets.bubble_sprite("em_happy", NOTICE_BUBBLE_H)
		add_child(bub)
		n["notice_bubble"] = bub
	var pick := emotion if not emotion.is_empty() else String(NOTICE_EMOTES[randi() % NOTICE_EMOTES.size()])
	bub.texture = UiAssets.emotion_tex(pick)
	bub.visible = true
	bub.modulate = Color.WHITE
	bub.scale = Vector3.ONE * 0.4
	n["notice_bub_t"] = 0.0

## 打招呼气泡每帧演出：弹出过冲 → 稳定 → 尾段淡出隐藏；跟随村民头顶。
func _animate_notice_bubble(n: Dictionary, delta: float) -> void:
	var bub := n.get("notice_bubble") as Sprite3D
	if bub == null or not is_instance_valid(bub) or not bub.visible:
		return
	var node := n["node"] as PaperCharacter
	bub.global_position = node.global_position + Vector3(0.0, _char_top(node) + 1.1, 0.0)
	var t := float(n.get("notice_bub_t", 0.0)) + delta
	n["notice_bub_t"] = t
	if t < 0.2:  # 0→1.2 过冲
		bub.scale = Vector3.ONE * lerpf(0.4, 1.2, t / 0.2)
	elif t < 0.35: # 1.2→1.0 回落
		bub.scale = Vector3.ONE * lerpf(1.2, 1.0, (t - 0.2) / 0.15)
	else:
		bub.scale = Vector3.ONE
	var left := NOTICE_BUBBLE_LIFE - t
	if left <= 0.0:
		bub.visible = false
	elif left < 0.5:  # 尾段淡出
		bub.modulate.a = left / 0.5

## 把节点放到「弯曲后」的地表位置。与 world_bend.gdshader 同一公式：
## 世界空间、以原点（玩家）为中心的水平距离平方下沉（shadow pass 一致，见着色器注释）。
func _place_on_bent_ground(node: Node3D, base_world: Vector3) -> void:
	var drop := BendMat.CURVATURE * (base_world.x * base_world.x + base_world.z * base_world.z)
	node.global_position = base_world - Vector3(0.0, drop, 0.0)

## 底部收听 HUD：选中角色时显示 AIGC 边框 + 声波柱；各柱子相位错开随音量拔高；
## 无输入时轻微待机滚动（让孩子看出「一直在听」），有声时随 _vad.level 整体拔高。
## 收听 HUD 落位：普通对话居中底部原尺寸；创造视图缩小左移，避开右侧大卡与左下的蛋/炉。
func _layout_voice_wave(creation: bool) -> void:
	if voice_wave == null:
		return
	var dx := CREATION_WAVE_DX if creation else 0.0
	voice_wave.offset_left = -WAVE_HUD_W * 0.5 + dx
	voice_wave.offset_right = WAVE_HUD_W * 0.5 + dx
	voice_wave.scale = Vector2.ONE * (CREATION_WAVE_SCALE if creation else 1.0)

## 只管收听 HUD 的显隐（选中角色时显示）：声波起伏由 VoiceWave 自跑，隐藏时它自动停。
func _update_voice_wave(_delta: float) -> void:
	# intro 说话教学步没有 selected（不走近身对话），靠 _intro_mic_hint 放行，让"话筒亮了"这句旁白有对应画面。
	var active := (selected != null and is_instance_valid(selected)) or _intro_mic_hint
	if voice_wave.visible != active:
		voice_wave.visible = active

## 角色立绘的可见世界宽度（米）：quad 的宽就是单格立绘的宽（sprite-sheet 已按 cellW 归一）。
func _char_quad_w(npc: PaperCharacter) -> float:
	var q := npc.mesh as QuadMesh
	return q.size.x if q != null and q.size.x > 0.0 else PaperCharacter.PLACEHOLDER_HEIGHT

## 角色立绘顶端相对节点原点（脚底）的高度——头顶挂饰（耳朵/气泡）按此定位，小仙子等小体型不悬空。
func _char_top(npc: PaperCharacter) -> float:
	if npc.texture == null:
		return 3.2
	# 可见单格高度：动画图集角色的 texture 是整张图集(rows×cellH)，直接用会算高 rows 倍
	# → 对话构图距离暴涨、头顶气泡飘太高。visible_height 按 sprite-sheet cellH 归一。
	return npc.visible_height()

func _update_hud() -> void:
	var t := WorldGrid.to_tile(player["logical"] if not player.is_empty() else focus_logical)
	if t != _hud_tile:  # 没跨 tile 不重排字符串（旧版每帧 format+赋值触发排版）
		_hud_tile = t
		coord_label.text = "tile (%d, %d)  /  %d×%d  环面循环" % [t.x, t.y, WorldGrid.GRID_TILES, WorldGrid.GRID_TILES]
	if perf_label == null:
		return
	_perf_accum += get_process_delta_time()
	if _perf_accum < 0.25:
		return
	_perf_accum = 0.0
	var fps := Engine.get_frames_per_second()
	var vp := get_viewport().get_viewport_rid()
	# 注意：TIME_PROCESS 的计时窗含 RenderingServer sync/draw（等上帧 GPU + 提交 + present），
	# 且是 1s 内最大值——不是纯脚本时间，标「主循环」防误读（本浮层曾因标「脚本逻辑」误导排查）
	perf_label.text = "%d fps（帧 %.1f ms）\n主循环 %.1f + 物理 %.1f ms\n渲染CPU %.1f ms / GPU %.1f ms\nDC %d  物体 %d  三角 %.1f 万" % [
		int(fps), 1000.0 / maxf(fps, 1.0),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		RenderingServer.viewport_get_measured_render_time_cpu(vp),
		RenderingServer.viewport_get_measured_render_time_gpu(vp),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 10000.0,
	]

func _unhandled_input(event: InputEvent) -> void:
	# benchmark 采样期：吞掉一切玩家输入（点击移动/手势/缩放），玩家不动→相机不动→可复现帧。
	# 注：将来若把「家长长按跳过 intro」接到输入，须让它绕过这道门（否则采样期跳不了）。
	if _bench_freeze:
		return
	# 回家过场中：玩家被脚本驱动走进/走出传送门，吞掉点击移动/手势/缩放，别让点击抢位或起新移动。
	if _homing:
		return
	# 观演/游戏态：StageAgent 全权调度演出，吞掉一切玩家输入（点击移动/进对话/手势/缩放）。
	# 唯一例外——「点角色」这类游戏规则（躲猫猫抓人/点选）仍要探测：命中被 watch 的演员即上行 tap 事件。
	# 玩家想退场（"不玩了"）走别的通道（提词/横幅按钮），不从这里放行。
	if _stage_active:
		if _stage != null:
			var tap_pos := _stage_tap_pos(event)
			if tap_pos != Vector2.INF:
				var aid := _stage_tapped_actor(tap_pos)
				if not aid.is_empty():
					_stage.on_local_tap(aid)
		return
	# 自贴装扮态（self-stickers）：给自己贴纸时吞掉世界点击（走路/拾取/跟随/缩放/手势都停），
	# 交互全交给底部贴纸盘（在 CanvasLayer 上层，按钮先吃命中）；点盘外空白 = 退出装扮。
	if _dress_self:
		if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
			if not event.pressed:
				_end_dress_self()
		return
	# 放置模式（placement-p1）：单指点地 → 幽灵挪到该 tile（贴纸吸附最近边）；吞掉走路/拾取/
	# 跟随/缩放，交互都交给底部 HUD。双指相机手势本模式下不接（避免幽灵与镜头抢手）。
	if _placing:
		if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
			if not event.pressed:
				var g := _pick_ground(event.position)
				if g != Vector2.INF:
					_place_tile = WorldGrid.to_tile(g)
					if _place_is_edge:
						_place_edge = _nearest_edge(g)
					_refresh_place_ghost()
		return
	# 调试：选中角色后按 Enter/空格。点点→造角色；其他→本地 move_to（离线演示）。
	if event.is_action_pressed("ui_accept") and selected != null:
		var d := _find_npc_dict(selected)
		if d.get("is_fairy", false) and online:
			_request_create("一只戴帽子的小猫")
		else:
			_show_emotion("wave")
			_run_behavior(selected, { "commands": [{ "type": "move_to", "params": {} }], "loop": false })
		return
	# 平板双指手势：捏合缩放 + 双指位移环绕/俯仰（临时视角，松手 5s 复原）。
	# 触点跟踪放在单指逻辑之前：第二指落下即接管，手势期间吞掉单指拾取/跟随
	# 以及第一指的鼠标仿真事件（emulate_mouse_from_touch）。
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 2:
				_begin_gesture()
		else:
			_touches.erase(event.index)
			if _gesturing:
				if _touches.is_empty():
					_gesturing = false
					_gest_reset_t = GESTURE_RESET_DELAY
				return
	elif event is InputEventScreenDrag and _touches.has(event.index):
		var prev: Vector2 = _touches[event.index]
		_touches[event.index] = event.position
		if _gesturing:
			if _touches.size() == 2:
				_apply_gesture_drag(event.index, prev, event.position)
			return
	elif _gesturing and (event is InputEventMouseButton or event is InputEventMouseMotion):
		return
	if _gesturing:
		return
	# 缩放（滚轮）
	if event is InputEventMouseButton and event.pressed and _locked == null:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_dist = clampf(_target_dist - 3.0, ZOOM_MIN, ZOOM_MAX)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_dist = clampf(_target_dist + 3.0, ZOOM_MIN, ZOOM_MAX)
			return
	# 鼠标：按在空地即走（暗黑式），按住拖动持续跟随；按在角色上仍走松开拾取
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = false
			_press_pos = event.position
			_try_begin_hold_follow(event.position)
			_begin_prop_press(event.position)
		else:
			_prop_press_tile = NO_PRESS_TILE # 抬指：长按候选作废
			if _hold_follow:
				_end_hold_follow(event.position)
			elif not _dragging:
				_tap_pick(event.position)
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if _hold_follow:
			_hold_pos = event.position
		if event.position.distance_to(_press_pos) > 6.0:
			_dragging = true # 防误触发拾取；按住空地的移动由 hold_follow 承担
		return
	# 触屏：与鼠标同一套按住跟随/拾取判定
	if event is InputEventScreenDrag:
		_dragging = true
		if _hold_follow:
			_hold_pos = event.position
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_dragging = false
			_press_pos = event.position
			_try_begin_hold_follow(event.position)
			_begin_prop_press(event.position)
		else:
			_prop_press_tile = NO_PRESS_TILE # 抬指：长按候选作废
			if _hold_follow:
				_end_hold_follow(event.position)
			elif not _dragging:
				_tap_pick(event.position)
		return

## 第二指落下：接管为相机手势——取消按住跟随和第一指已下发的走路指令，抬指不得触发拾取。
func _begin_gesture() -> void:
	_gesturing = true
	_hold_follow = false
	_dragging = true
	_prop_press_tile = NO_PRESS_TILE # 长按候选作废
	_cancel_player_move()
	_gest_reset_t = 0.0 # 手势进行中不倒计时，全部抬起才开始

## 双指拖动增量：两指间距变化 → 距离倍率（张开=拉近）；中点位移 → 环绕(横)+俯仰(纵)。
func _apply_gesture_drag(index: int, prev: Vector2, cur: Vector2) -> void:
	var other := Vector2.ZERO
	for i in _touches:
		if i != index:
			other = _touches[i]
	var prev_span := prev.distance_to(other)
	var new_span := cur.distance_to(other)
	if prev_span > 1.0 and new_span > 1.0:
		_gest_zoom_t = clampf(_gest_zoom_t * prev_span / new_span, GESTURE_ZOOM_MUL_MIN, GESTURE_ZOOM_MUL_MAX)
	var mid_delta := (cur - prev) * 0.5 # 另一指本事件内不动，中点位移即本指位移的一半
	_gest_yaw_t += mid_delta.x * GESTURE_YAW_SENS
	_gest_pitch_t = clampf(_gest_pitch_t + mid_delta.y * GESTURE_PITCH_SENS,
			GESTURE_PITCH_MIN - _target_pitch, GESTURE_PITCH_MAX - _target_pitch)

func _tap_pick(screen_pos: Vector2) -> void:
	var hit := _pick_npc(screen_pos)
	if hit != null:
		_approach_npc(hit)
		return
	# 点别的小朋友：跑过去进喊话态（表情盘/喊话在 P3/P5 叠加）
	var rhit := _pick_remote_actor(screen_pos)
	if not rhit.is_empty():
		_approach_remote(rhit)
		return
	# 点自己 = 跟身边的小仙子说话（她是「我」的引导精灵，语音路由到精灵角色）
	if _pick_player(screen_pos):
		var fairy := _find_fairy()
		if not fairy.is_empty():
			_approach_npc(fairy["node"])
		return
	# 点空地：退出交互（恢复被叫停的 NPC），玩家走过去
	if selected != null:
		_exit_interaction()
	_exit_player_talk()
	_clear_approach()
	var ground := _pick_ground(screen_pos)
	if ground != Vector2.INF and not player.is_empty():
		_show_tap_marker(ground)
		_move_player_to(ground)

## 玩家移动指令：新点击替换旧指令（寻路 waypoint 队列 + Mover 规则由执行器统一处理）。
func _move_player_to(target: Vector2, arrive := 0.0) -> void:
	_cancel_player_move()
	var ex := BehaviorExecutor.new()
	ex.setup(player, {
		"commands": [{ "type": "move_to", "params": { "target": [target.x, target.y], "arrive": arrive } }],
		"loop": false,
	})
	_player_executor = ex
	_executors.append(ex)

func _cancel_player_move() -> void:
	if _player_executor != null:
		_player_executor.cancel()
		_player_executor = null

## 暗黑式按住跟随：仅当按点落在空地（非 NPC/非玩家）时进入，立即下发首个目标。
func _try_begin_hold_follow(screen_pos: Vector2) -> void:
	if _hold_follow or player.is_empty():
		return
	if _pick_npc(screen_pos) != null or _pick_player(screen_pos) \
			or not _pick_remote_actor(screen_pos).is_empty():
		return
	if _pick_ground(screen_pos) == Vector2.INF:
		return
	if selected != null:
		_exit_interaction()
	_exit_player_talk()
	_clear_approach()
	_hold_follow = true
	_hold_pos = screen_pos
	_hold_timer = 0.0
	_steer_hold_follow()

func _end_hold_follow(screen_pos: Vector2) -> void:
	_hold_pos = screen_pos
	_steer_hold_follow() # 停在松开处
	_hold_follow = false

## 按住期间每 HOLD_FOLLOW_INTERVAL 秒把指针下地面重下发为移动目标（新指令替换旧指令）。
func _step_hold_follow(delta: float) -> void:
	if not _hold_follow:
		return
	_hold_timer += delta
	if _hold_timer < HOLD_FOLLOW_INTERVAL:
		return
	_hold_timer = 0.0
	_steer_hold_follow()

func _steer_hold_follow() -> void:
	if player.is_empty():
		return
	var ground := _pick_ground(_hold_pos)
	if ground == Vector2.INF:
		return
	_show_tap_marker(ground)
	_move_player_to(ground)

## 屏幕点 → 弯曲地表交点的逻辑坐标；无交点返回 Vector2.INF。
## 地表 y = tile 台阶高度 - 弯曲下沉（与 _place_on_bent_ground 同公式）；
## 台阶/曲面无解析解，射线步进找穿越区间再二分细化（0.5m 步进对 2m tile 足够）。
func _pick_ground(screen_pos: Vector2) -> Vector2:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var prev_t := 0.0
	var t := 0.0
	while t < 220.0:
		t += 0.5
		var p := from + dir * t
		if p.y <= _surface_y(p):
			var lo := prev_t
			var hi := t
			for i in range(10):
				var mid := (lo + hi) * 0.5
				if (from + dir * mid).y <= _surface_y(from + dir * mid):
					hi = mid
				else:
					lo = mid
			var hit := from + dir * hi
			return WorldGrid.wrap_pos(focus_logical + Vector2(hit.x, hit.z))
		prev_t = t
	return Vector2.INF

## 渲染空间点位下方的弯曲地表高度（渲染原点 = focus_logical）。
func _surface_y(p: Vector3) -> float:
	var logical := WorldGrid.wrap_pos(focus_logical + Vector2(p.x, p.z))
	var h := float(TerrainMap.tile_height(WorldGrid.to_tile(logical))) * TerrainMap.STEP_HEIGHT
	return h - BendMat.CURVATURE * (p.x * p.x + p.z * p.z)

## 点击落点标记：黄色小圆片淡出（每帧随世界滚动重摆）。
func _show_tap_marker(logical: Vector2) -> void:
	if _tap_marker == null:
		_tap_marker = MeshInstance3D.new()
		var m := CylinderMesh.new()
		m.top_radius = 0.7
		m.bottom_radius = 0.7
		m.height = 0.06
		_tap_marker.mesh = m
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.95, 0.4, 0.85)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tap_marker.material_override = mat
		add_child(_tap_marker)
	_tap_marker_logical = logical
	_tap_marker_t = TAP_MARKER_LIFE
	_tap_marker.visible = true
	game_audio.play_sfx("pluck")

func _update_tap_marker(delta: float) -> void:
	if _tap_marker == null or not _tap_marker.visible:
		return
	_tap_marker_t -= delta
	if _tap_marker_t <= 0.0:
		_tap_marker.visible = false
		return
	var d := WorldGrid.shortest_delta(focus_logical, _tap_marker_logical)
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(_tap_marker_logical))) * TerrainMap.STEP_HEIGHT
	_place_on_bent_ground(_tap_marker, Vector3(d.x, ty + 0.05, d.y))
	var mat := _tap_marker.material_override as StandardMaterial3D
	mat.albedo_color.a = 0.85 * clampf(_tap_marker_t / TAP_MARKER_LIFE, 0.0, 1.0)

## 玩家角色的屏幕空间拾取（与 _pick_npc 同一套 unproject 判定）。
func _pick_player(screen_pos: Vector2) -> bool:
	if player.is_empty():
		return false
	var node: Node3D = player["node"]
	var wp := node.global_position + Vector3(0.0, 1.6, 0.0)
	if camera.is_position_behind(wp):
		return false
	return screen_pos.distance_to(camera.unproject_position(wp)) < PICK_RADIUS_PX

## 屏幕空间拾取：精灵未弯曲，其屏幕位置 = unproject(实际渲染坐标)，与点击对比。
func _pick_npc(screen_pos: Vector2) -> PaperCharacter:
	var best: PaperCharacter = null
	var best_d := PICK_RADIUS_PX
	for n in npcs:
		var node: PaperCharacter = n["node"]
		var wp := node.global_position + Vector3(0.0, 1.6, 0.0)
		if camera.is_position_behind(wp):
			continue
		var sp := camera.unproject_position(wp)
		var dd := screen_pos.distance_to(sp)
		if dd < best_d:
			best_d = dd
			best = node
	return best

## 远端玩家副本的屏幕空间拾取（与 _pick_npc 同一套 unproject 判定）。返回副本条目，未命中 {}。
func _pick_remote_actor(screen_pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_d := PICK_RADIUS_PX
	for id in _remote_actors:
		var ra: Dictionary = _remote_actors[id]
		var node: PaperCharacter = ra["node"]
		if not is_instance_valid(node):
			continue
		var wp := node.global_position + Vector3(0.0, 1.6, 0.0)
		if camera.is_position_behind(wp):
			continue
		var dd := screen_pos.distance_to(camera.unproject_position(wp))
		if dd < best_d:
			best_d = dd
			best = ra
	return best

## 观演态点击 → 按下事件的屏幕坐标；非按下（拖拽/松手/键盘）返回 INF。
## 触屏一次点击会同时来 ScreenTouch + 仿真 MouseButton，两者都返回坐标，去重交 StageAgent（TAP_DEBOUNCE_MS）。
func _stage_tap_pos(event: InputEvent) -> Vector2:
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		return (event as InputEventScreenTouch).position
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			return mb.position
	return Vector2.INF

## 观演态点击 → 命中的舞台演员 id（玩家归本场占的角色 id，NPC 归其后端 id）；未命中空串。
func _stage_tapped_actor(screen_pos: Vector2) -> String:
	if _pick_player(screen_pos):
		return _stage_player_actor_id if not _stage_player_actor_id.is_empty() else PLAYER_ID
	var npc := _pick_npc(screen_pos)
	if npc != null:
		return String(_find_npc_dict(npc).get("id", ""))
	return ""

## 点 NPC：对象停下等待，玩家跑到旁边后再进近身视图（饥荒式）。
func _approach_npc(npc: PaperCharacter) -> void:
	if npc == selected:
		return # 已在与它交互
	var d := _find_npc_dict(npc)
	if d.is_empty():
		return
	if selected != null:
		_exit_interaction()
	_exit_player_talk()
	_clear_approach()
	_halt_npc(d)
	_approach = d
	# 到达半径按体型放大：走向大角色早点停（别把脸怼进大恐龙），小角色可贴得更近。
	_move_player_to(d["logical"], APPROACH_ARRIVE * float(d.get("scale", 1.0)))

## 点别的小朋友：跑到他旁边进喊话态。不 halt——对方是真人玩家，钉不住也不该钉。
func _approach_remote(entry: Dictionary) -> void:
	if String(entry.get("id", "")) == _talk_pid:
		return # 已在跟他喊话
	if selected != null:
		_exit_interaction()
	_exit_player_talk()
	_clear_approach()
	_approach = entry # is_remote 条目：_check_approach 到位后分流进喊话态
	_move_player_to(entry["logical"], APPROACH_ARRIVE)

## 叫停一个 NPC 的所有行为（闲逛/服务端指令），退出交互时恢复。
## 正在跟随的记下目标（resume_follow），恢复时继续跟而不是回去闲逛。
func _halt_npc(d: Dictionary) -> void:
	for ex in _executors:
		if (ex as BehaviorExecutor).drives(d):
			var fid := (ex as BehaviorExecutor).following_id()
			if not fid.is_empty():
				d["resume_follow"] = fid
			(ex as BehaviorExecutor).cancel()
	_stopped = d

func _resume_stopped_npc() -> void:
	if not _stopped.is_empty() and not _stopped.get("is_fairy", false) \
			and is_instance_valid(_stopped.get("node")) \
			and not _has_executor_for(_stopped):
		# 已有执行器（如刚下发的立去系指令）就别用闲逛覆盖它，让它把指令走完。
		var fid := String(_stopped.get("resume_follow", ""))
		if not fid.is_empty():
			_stopped.erase("resume_follow")
			_run_behavior(_stopped["node"], {
				"commands": [{ "type": "follow", "params": { "target_name": fid } }],
				"loop": false,
			})
		else:
			_start_ambient_wander(_stopped)
	_stopped = {}

## 放弃当前「跑向 NPC」目标（点了别处/换目标），恢复被叫停的对象。
func _clear_approach() -> void:
	if _approach.is_empty():
		return
	_approach = {}
	if selected == null:
		_resume_stopped_npc()

## 每帧检查：玩家跑到目标 NPC 旁了就进近身视图；走不到（路被围死）则恢复对象。
func _check_approach() -> void:
	if _approach.is_empty() or _player_executor == null or not _player_executor.is_done():
		return
	var d := _approach
	_approach = {}
	_player_executor = null
	if not is_instance_valid(d.get("node")):
		_resume_stopped_npc()
		return
	var dist: float = WorldGrid.shortest_delta(player["logical"], d["logical"]).length()
	if dist <= APPROACH_ARRIVE + 0.6:
		if d.get("is_remote", false):
			_enter_player_talk(d)
		else:
			_enter_interaction(d["node"])
	else:
		_resume_stopped_npc()

func _enter_interaction(npc: PaperCharacter) -> void:
	selected = npc
	_sync_guide_button() # 进对话：引路挂起（不取消），「不去了」按钮先收起，别压在对话 UI 上
	game_audio.play_sfx("enter")
	_check_deliver_task(npc) # 带话委托：亲自走到目标角色旁开始对话 = 送达
	# 面对面 + 站桩：玩家按进入侧跳到 NPC 对应侧站位（NPC 原地不动）。落点必须可通行——
	# 首选侧被建筑/物件占用就改站对侧，两侧都站不下则不跳（留在已可达的到位点，防跳进房子卡死）。
	var d := _find_npc_dict(npc)
	if not d.is_empty() and not player.is_empty():
		var target := _pick_stage_target(d["logical"], player["logical"])
		# 朝向按最终落点相对 NPC 定（保证换到对侧时也朝对方，不用进入侧 dx）
		var fdx := WorldGrid.shortest_delta(d["logical"], target).x
		d["paper_face"] = 0.0 if fdx > 0.0 else PI
		player["paper_face"] = 0.0 if fdx <= 0.0 else PI
		if WorldGrid.shortest_delta(target, player["logical"]).length() > 0.05:
			_cancel_player_move()
			_hop_from = player["logical"]
			_stage_player_logical = target
			player["_hop"] = true
			_hop_t = 0.0
	# lock：相机平滑切到更低角(3/4)；距离/焦点交给对话构图（_dialog_camera）逐帧算
	_locked = npc
	_target_pitch = LOCK_PITCH_DEG
	banner.text = "想说什么就直接跟%s说吧" % npc.char_name
	banner.visible = true
	thinking_label.visible = false
	# 开放麦：进近身即聆听——开口就说、说完自动发送，全程无按钮无模式（见 VoiceCapture/_voice_should_capture）
	_vc.open() # 进近身即聆听（VoiceCapture 起麦+建 VAD）
	_reset_empty_streak() # 新一场对话不继承上一场的空识别退避
	# 点委托 chip 来的：进对话直接问点点「这个任务怎么做呀」，不走进场招呼（招呼会跟提示撞成两句）。
	if _pending_task_hint and d.get("is_fairy", false):
		_pending_task_hint = false
		if not _send_task_hint_question():
			_greet_on_enter(d) # 发不出去（离线）就退回正常招呼，别冷场
	else:
		_pending_task_hint = false # 中途改点了别人：清掉挂起的提示意图
		_greet_on_enter(d) # 对方先开口打招呼（播放期间 should_capture 自动闭麦，说完再放开）
	_sticker_pick = ""
	_refresh_sticker_view() # 背包有贴纸就亮贴纸盘（character-anchors P4）

## 进「玩家喊话」态：站桩构图面对对方副本。对方端无感知（无会话锁）——他继续玩他的；
## 走远/离场/换场景由 _step_remote_actors 的维持判定自动退出。P3 在此态叠表情盘，P5 叠开放麦喊话。
func _enter_player_talk(entry: Dictionary) -> void:
	_talk_pid = String(entry.get("id", ""))
	if _talk_pid.is_empty():
		return
	game_audio.play_sfx("enter")
	if not player.is_empty():
		var target := _pick_stage_target(entry["logical"], player["logical"])
		var fdx := WorldGrid.shortest_delta(entry["logical"], target).x
		player["paper_face"] = 0.0 if fdx <= 0.0 else PI
		if WorldGrid.shortest_delta(target, player["logical"]).length() > 0.05:
			_cancel_player_move()
			_hop_from = player["logical"]
			_stage_player_logical = target
			player["_hop"] = true
			_hop_t = 0.0
	# lock：对话构图相机对着两人（_find_npc_dict 兼容远端副本条目）
	_locked = entry["node"]
	_target_pitch = LOCK_PITCH_DEG
	banner.text = "跟%s打个招呼吧！" % (entry["node"] as PaperCharacter).char_name
	banner.visible = true
	if _talk_view != null:
		_talk_view.visible = true # 底部表情盘亮起：点一格双端一起演
	# 开放麦（喊话）：与近身对话同一套 VAD 断句；端侧 ASR 未就绪时 _voice_should_capture 门禁不实际开录
	_vc.open() # 喊话态与近身对话同一套 VAD 断句（端侧未就绪时 should_capture 门禁不实际开录）
	_reset_empty_streak()

## 退出喊话态：解锁相机回自由视角。幂等——不在喊话态时调用是 no-op（各退出路径可放心乱叫）。
func _exit_player_talk() -> void:
	if _talk_pid.is_empty():
		return
	_talk_pid = ""
	game_audio.play_sfx("exit")
	_vc.close() # 关麦（录音中则先静默取消，不留半开会话）
	if _talk_view != null:
		_talk_view.visible = false
	if not player.is_empty():
		player.erase("_hop") # 中途退出清掉未完成的小跳（保留当前位置，不瞬移回落点）
	_hop_t = -1.0
	_locked = null
	_target_pitch = GOD_PITCH_DEG
	_target_dist = GOD_DIST
	banner.visible = false

## 喊话态底部表情盘：一排大图标卡（挥手/跳跳/转圈/点头），点一下双端一起演。
## 摆底部横排而不是居中 2×2——对话构图的两个小人在画面中央，卡不能挡脸。
func _build_talk_view(host: CanvasLayer) -> void:
	_talk_view = Control.new()
	_talk_view.name = "TalkView"
	_talk_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_talk_view.mouse_filter = Control.MOUSE_FILTER_IGNORE # 只有卡吃点击，不挡世界
	_talk_view.visible = false
	host.add_child(_talk_view)
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	row.offset_top = -190.0
	row.offset_bottom = -34.0
	row.add_theme_constant_override("separation", 16)
	_talk_view.add_child(row)
	for action in EMOTE_PANEL_ACTIONS:
		var card := Button.new()
		# 128px：八格 8×128+7×16=1136 < 1280 设计宽（五格时代 156 会溢出）；仍够 3 岁点击
		card.custom_minimum_size = Vector2(128.0, 128.0)
		UiAssets.style_card_button(card, 24.0) # 奶油圆角卡片，与造角色选项卡同调
		card.icon = UiAssets.emotion_tex(action)
		card.expand_icon = true
		card.pressed.connect(_on_talk_emote_card.bind(String(action)))
		row.add_child(card)

# ── NPC 贴纸盘（character-anchors P4）────────────────────────────────────────
# 对话态底部两段式：第一段列背包贴纸（点选进第二段），第二段列三个槽位（头顶/左手/右手）。
# 贴上/摘下都是发 character_attach 等广播落地（服务端权威扣还背包）。

var _sticker_view: Control          ## 贴纸盘容器（NPC 对话态 / 自贴装扮态显示）
var _sticker_row: HBoxContainer     ## 动态格子行
var _sticker_pick := ""             ## 已选中的贴纸实体 id（空=贴纸选择段）
var _dress_self := false            ## 自贴装扮态（贴纸 app 详情「装到身上」进入）：贴纸盘对着玩家自己
var _my_attachments: Array = []     ## 自己身上贴的贴纸权威副本（world_state 下发/player_attach 增量维护，供换形象/重挂）
const STICKER_SLOTS := [["headTop", "头顶"], ["handL", "左手"], ["handR", "右手"]]

# ── 放置模式（placement-p1 §3.1/§3.2）────────────────────────────────────────
# 从物品 app 点物品进入：一次一件，跟手幽灵(footprint 高亮片)随点地移动，合法绿/非法红，
# 点「放这里」发 item_place 带玩家选的 tile+yaw(+edge)，取消退出。服务端零改（真权威校验
# 仍在 validateTerrainItems，客户端高亮只是好用的预判）。
var _placing := false               ## 是否在放置模式
var _place_item_id := ""            ## 正在放的物品实体 id
var _place_is_edge := false         ## true=贴纸（贴 tile 边），false=tile 物品
var _place_tile := Vector2i.ZERO    ## 当前目标 tile（锚点）
var _place_yaw := 0.0               ## tile 物品朝向 0/90/180/270
var _place_edge := TerrainMap.EDGE_S ## 贴纸选中的边（吸附光标最近边）
var _place_legal := false           ## 当前位置是否合法（决定绿/红 + 能否确认）
var _place_ghost: MeshInstance3D    ## footprint 高亮片（贴弯曲地表，随世界滚动重摆）
var _place_nub: MeshInstance3D      ## 朝向指示小块（footprint 正面半格外）
var _place_ghost_logical := Vector2.ZERO ## 幽灵中心逻辑坐标（每帧据此重摆）
var _place_view: Control            ## 放置 HUD（放这里/转一转/收起来）
var _place_hint: Label              ## HUD 顶部提示条
var _place_confirm_btn: Button      ## 「放这里」按钮（按合法性启用/灰显）

# ── 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md §4.2）──────────────────
# 造物类心愿造成功后不当场盖章：村民抱怨「差一点」，refineItemRef 那件东西旁出一对变大/变小箭头，
# 小朋友点箭头调体型（3 岁点选不拖拽）。体型重渲染由服务端做（wish_refine → terrain_patch/character_resized）。
# 仙子只问不给答案（refine_hint 预制 WAV，走 FairyVoice 独立通道不碰 _tts_player）。
const REFINE_SIZES := ["small", "medium", "big"] ## 三档阶梯（与服务端 SIZE_TO_SCALE 同序）
var _refine_active := false          ## 是否在试用调整态
var _refine_item_ref := ""           ## 正在调的那件东西（item id / character id）
var _refine_dir := ""                ## 抱怨方向 smaller/bigger（服务端定，仅作提示，判定在服务端）
var _refine_size := "medium"         ## 当前体型档（本地乐观跟踪，按箭头步进）
var _refine_view: Control            ## 试用 HUD（变大/变小/收起来）
var _refine_hint: Label              ## HUD 顶部提示条
var _refine_indicator: Sprite3D      ## 指向 refineItemRef 的悬浮提示（3D，随实体位置）
var _refine_prop_tile := Vector2i(-1, -1) ## 造物落地的 tile（角色则用 npc 节点定位，此值 -1）
var _refine_bob := 0.0               ## 指示器上下浮动相位

func _build_sticker_view(host: CanvasLayer) -> void:
	_sticker_view = Control.new()
	_sticker_view.name = "StickerView"
	_sticker_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sticker_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sticker_view.visible = false
	host.add_child(_sticker_view)
	_sticker_row = HBoxContainer.new()
	_sticker_row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_sticker_row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_sticker_row.offset_top = -170.0
	_sticker_row.offset_bottom = -34.0
	_sticker_row.add_theme_constant_override("separation", 22)
	_sticker_view.add_child(_sticker_row)

## 重建贴纸盘（进对话/背包变化/选中切段时调）。对话目标无真立绘或背包无贴纸 → 整盘隐藏。
func _refresh_sticker_view() -> void:
	if _sticker_view == null:
		return
	for c in _sticker_row.get_children():
		c.queue_free()
	# 目标：自贴装扮态=玩家自己；否则=对话中的 NPC（selected）。
	var target: PaperCharacter = null
	if _dress_self:
		target = player.get("node") as PaperCharacter if not player.is_empty() else null
	else:
		target = selected
	if target == null or not online or _in_creation:
		_sticker_view.visible = false
		return
	var ids: Array = []
	for item_id in bag:
		if int(bag[item_id]) > 0 and _sticker_tex(String(item_id)) != null:
			ids.append(String(item_id))
	ids.sort()
	# NPC 态：无贴纸且未选中即隐藏；自贴态：始终显示（至少给个「收起」键退出装扮）。
	if not _dress_self and ids.is_empty() and _sticker_pick.is_empty():
		_sticker_view.visible = false
		return
	_sticker_view.visible = true
	if _sticker_pick.is_empty():
		for item_id in ids.slice(0, 6): # 一排最多 6 格（3 岁大点击区放不下更多）
			var card := Button.new()
			card.custom_minimum_size = Vector2(120.0, 120.0)
			UiAssets.style_card_button(card, 20.0)
			card.icon = _sticker_tex(String(item_id))
			card.expand_icon = true
			card.pressed.connect(func() -> void:
				_sticker_pick = String(item_id)
				game_audio.play_sfx("bell")
				_refresh_sticker_view())
			_sticker_row.add_child(card)
		if _dress_self: # 自贴态：末尾一个「✓ 收起」键退出装扮
			var done := Button.new()
			done.custom_minimum_size = Vector2(120.0, 120.0)
			UiAssets.style_card_button(done, 20.0)
			done.text = "✓"
			done.pressed.connect(_end_dress_self)
			_sticker_row.add_child(done)
	else:
		for pair in STICKER_SLOTS:
			var slot_btn := Button.new()
			slot_btn.custom_minimum_size = Vector2(150.0, 120.0)
			UiAssets.style_card_button(slot_btn, 20.0)
			slot_btn.text = String(pair[1])
			slot_btn.pressed.connect(_on_sticker_slot.bind(String(pair[0])))
			_sticker_row.add_child(slot_btn)
		var back := Button.new()
		back.custom_minimum_size = Vector2(120.0, 120.0)
		UiAssets.style_card_button(back, 20.0)
		back.text = "↩"
		back.pressed.connect(func() -> void:
			_sticker_pick = ""
			_refresh_sticker_view())
		_sticker_row.add_child(back)

## 选了槽位：发 attach（服务端扣包+广播，本端等广播落地渲染），回到贴纸选择段。
## 自贴态发 player_attach（贴自己），NPC 态发 character_attach（贴对话对象）。
func _on_sticker_slot(slot: String) -> void:
	if _sticker_pick.is_empty():
		return
	if _dress_self:
		if player.is_empty():
			return
		backend.send_player_attach(world_id, slot, _sticker_pick)
	else:
		var d := _find_npc_dict(selected) if selected != null else {}
		var cid := String(d.get("id", ""))
		if cid.is_empty():
			return
		backend.send_character_attach(world_id, cid, slot, _sticker_pick)
	game_audio.play_sfx("pop")
	_sticker_pick = ""
	_refresh_sticker_view()

## 贴纸实体 → 贴图；非贴纸/未注册 → null。保持同步（贴纸盘/角色锚点都是同步 UI 构建）。
## 打包贴纸 renderRef 'sticker:<name>' 经 PackRegistry 同步 load；
## 造贴纸 'sticker:@<hash>' 从 ChunkManager 资产缓存读（_prewarm_sticker_assets 已按哈希预热网络贴图）；
## 未预热到则返回 null（贴纸盘据此暂不列，角色锚点暂不挂）——预热在实体入目录时触发，通常已就绪。
func _sticker_tex(item_id: String) -> Texture2D:
	var rref := String(ItemCatalog.get_def(item_id).get("renderRef", ""))
	if not rref.begins_with("sticker:"):
		return null
	var skey := rref.get_slice(":", 1)
	if skey.begins_with("@"):
		return ChunkManager.get_sticker_asset(skey.substr(1))
	return PackRegistry.load_resource(skey) as Texture2D

## 角色锚点贴纸取图（可 await，attach 信号处理器用）：先走同步 _sticker_tex（打包/已缓存）；
## 造贴纸未缓存（别的客户端收到 attach 广播时可能还没预热）则 await 拉网络并回灌缓存，避免贴不上。
func _resolve_sticker_tex(item_id: String) -> Texture2D:
	var tex := _sticker_tex(item_id)
	if tex != null:
		return tex
	var rref := String(ItemCatalog.get_def(item_id).get("renderRef", ""))
	if rref.begins_with("sticker:@") and api != null:
		var hash := rref.substr("sticker:@".length())
		tex = await api.fetch_texture(hash)
		if tex != null:
			ChunkManager.cache_sticker_asset(hash, tex)
	return tex

## 把一次 attach/detach 落到某节点（itemId 空/null=摘该槽）。attach/detach 共用一条路径。
## 走 _resolve_sticker_tex（异步）：仙子现造的贴纸 renderRef sticker:@<hash> 冷缓存时要向服务端拉取，
## 只查本地 PackRegistry 会漏渲染（与 _on_character_attach 原路径一致，别回归）。
func _render_attach(node: PaperCharacter, slot: String, item_v: Variant) -> void:
	if node == null or not is_instance_valid(node):
		return
	if item_v == null or String(item_v).is_empty():
		node.detach_sticker(slot)
		return
	var tex := await _resolve_sticker_tex(String(item_v))
	if tex != null and is_instance_valid(node):
		node.attach_sticker(slot, tex)

## 把一次 attach/detach 增量并进 attachments 列表副本（item_id 空=摘该槽）。纯函数，便于回测。
static func _merge_attach(list: Array, slot: String, item_id: String) -> Array:
	var out: Array = []
	for a in list:
		if typeof(a) == TYPE_DICTIONARY and String((a as Dictionary).get("slot", "")) != slot:
			out.append(a)
	if not item_id.is_empty():
		out.append({ "slot": slot, "itemId": item_id })
	return out

## character_attach 广播落地：按 id 现查角色副本（勿持引用），挂/摘贴纸。
func _on_character_attach(data: Dictionary) -> void:
	if String(data.get("sceneId", "village")) != _scene_id:
		return
	var npc := _find_npc_by_id(String(data.get("characterId", "")))
	if npc == null:
		return
	_render_attach(npc, String(data.get("slot", "")), data.get("itemId"))

## player_attach 广播落地（含自己，同 character_attach 哲学：靠广播落地渲染）。
## 自己=挂到玩家节点并维护 _my_attachments（换形象重挂用）；别人=挂到远端副本并更新 presence。
func _on_player_attach(data: Dictionary) -> void:
	if String(data.get("sceneId", _scene_id)) != _scene_id:
		return
	var pid := String(data.get("playerId", ""))
	var slot := String(data.get("slot", ""))
	var item_v: Variant = data.get("itemId")
	var item_id := String(item_v) if (item_v != null and not String(item_v).is_empty()) else ""
	if pid == backend.player_id:
		_my_attachments = _merge_attach(_my_attachments, slot, item_id)
		if not player.is_empty():
			_render_attach(player["node"] as PaperCharacter, slot, item_v)
		if _dress_self:
			_refresh_sticker_view() # 背包数变了，贴纸盘跟着刷
	else:
		if _presence.has(pid):
			_presence[pid]["attachments"] = _merge_attach(_presence[pid].get("attachments", []), slot, item_id)
		var ra: Dictionary = _remote_actors.get(pid, {})
		if not ra.is_empty():
			_render_attach(ra.get("node") as PaperCharacter, slot, item_v)

## 角色降生时应用已有贴纸（attachments 随角色整对象下发）。
func _apply_attachments(npc: PaperCharacter, c: Dictionary) -> void:
	_apply_attachments_list(npc, c.get("attachments", []))

## 把 attachments 列表挂到某节点（先清 3 槽再挂，按当前立绘尺寸；itemId 无效则跳过）。
## 换形象/真立绘就位后重挂用——立绘尺寸变了需按新尺寸重算贴纸大小。
func _apply_attachments_list(node: PaperCharacter, list: Array) -> void:
	if not is_instance_valid(node):
		return
	for pair in STICKER_SLOTS:
		node.detach_sticker(String(pair[0]))
	for a in list:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		var tex := await _resolve_sticker_tex(String((a as Dictionary).get("itemId", "")))
		if tex != null:
			node.attach_sticker(String((a as Dictionary).get("slot", "")), tex)

## 把 _my_attachments 挂到本地玩家节点（world_state 下发/真立绘就位后调，按当前尺寸重挂）。
func _apply_player_attachments() -> void:
	if player.is_empty():
		return
	_apply_attachments_list(player["node"] as PaperCharacter, _my_attachments)

## 从手机「贴纸」app 详情里点「装到身上」进入（placement-interaction §3.3 入口 b）：
## 手机已把这张贴纸选好（item_id 传进来），所以直接预置 _sticker_pick 进「选身上哪个槽」段。
## 收起手机跨页停靠、近身相机框住玩家、亮自贴盘。装扮态吞世界点击（见 _unhandled_input），
## 点盘外空白 = 退出装扮；选完一个槽发 player_attach 后 _sticker_pick 清空、回到可再贴/✓收起段。
func _begin_self_attach(item_id: String) -> void:
	if player.is_empty() or not online:
		return
	if _sticker_tex(item_id) == null:
		return # 不是贴纸/未注册贴图：装不上，直接不进装扮态
	if selected != null:
		_exit_interaction() # 万一开手机前正对着 NPC：先退干净，装扮只对自己
	if paper_phone != null and paper_phone.state != PaperPhone.State.DOCKED:
		paper_phone.dock()
		phone_ui.set_screen_off(true)
		paper_phone.refresh_dock_screen()
	if _phone_scrim != null:
		_phone_scrim.visible = false # 装扮态不用遮罩（会盖住贴纸盘按钮），改由 _unhandled_input 吞点击
	_dress_self = true
	_sticker_pick = item_id # 手机已选好这张 → 直接进选槽段
	_enter_phone_cam() # 幂等：把玩家框在屏上好贴
	_refresh_sticker_view()

## 退出装扮：还原相机、隐藏贴纸盘。
func _end_dress_self() -> void:
	if not _dress_self:
		return
	_dress_self = false
	_sticker_pick = ""
	_exit_phone_cam()
	if game_audio != null:
		game_audio.play_sfx("exit")
	_refresh_sticker_view()

## 点了表情盘某格：本端立即演 + 发给服务端转发（对端在我的副本上演同款）。
func _on_talk_emote_card(action: String) -> void:
	if _talk_pid.is_empty() or _emote_press_cd > 0.0:
		return
	_emote_press_cd = float(BehaviorExecutor.ACTION_DUR.get(action, 1.2))
	game_audio.play_sfx("bell")
	_send_emote(_talk_pid, action)

## 发出一个 emote（手动点卡/自动回礼共用）：自己的角色演起来 + 上行 + 记冷却。
func _send_emote(target_pid: String, action: String) -> void:
	if not player.is_empty():
		_play_emote_on(player, action)
	_emote_cd_until[target_pid] = Time.get_ticks_msec() + EMOTE_CD_MS
	if online and backend != null:
		backend.send_player_emote(world_id, target_pid, action)

## 在某个角色条目（本地玩家/远端副本）上演 emote：纸片动作 + 头顶表情泡。
func _play_emote_on(entry: Dictionary, action: String) -> void:
	if not UiAssets.EMOTION_ICONS.has(action):
		return # 未知动作（新旧版本混跑）：静默忽略，别演成错的
	# heart 无专属纸片动作：挥手 + 爱心泡（泡才是主角）
	var anim := action if BehaviorExecutor.ACTION_DUR.has(action) else "wave"
	entry["paper_action"] = anim
	entry["paper_action_t"] = 0.0
	_pop_notice_bubble(entry, action)

## 收到别的小朋友的 emote：他的副本演起来；对我做的且冷却期外 → 自动回一个挥手
## （孩子不操作也有来有往；发出方自己也记了冷却，乒乓在第二拍断掉）。
func _on_player_emote(data: Dictionary) -> void:
	var from := String(data.get("fromPlayerId", ""))
	var action := String(data.get("action", ""))
	var ra: Dictionary = _remote_actors.get(from, {})
	if not ra.is_empty():
		_play_emote_on(ra, action)
	# 收到送给我的爱心：自己头顶也冒爱心 + 音效（计数入账走 hearts_update，钱包权威在服务端）
	if action == "heart" and String(data.get("targetPlayerId", "")) == backend.player_id \
			and not player.is_empty():
		_pop_notice_bubble(player, "heart")
		game_audio.play_sfx("reveal")
	if emote_should_autoreply(data, backend.player_id, int(_emote_cd_until.get(from, 0)), Time.get_ticks_msec()):
		_send_emote(from, "wave")

## 喊话文本落地（端侧 ASR final，玩家对话路由）：本端用自己的音色复述一遍——孩子听到
## 自己被识别成了什么；复述窗口 ≈ 对端收听窗口（同文本同音色时长近似），节奏天然对齐。
## 同时上行 player_speech 让服务端场景定向转发。lang 恒 zh（跨语言翻译钩子在服务端）。
func _handle_talk_transcript(t: String) -> void:
	heard_label.text = "我说：%s" % t # 家长可读字幕；幼儿靠复述音
	heard_label.visible = true
	if online and backend != null:
		backend.send_player_speech(world_id, _talk_pid, t)
	_speak_line(t, _my_voice_id) # pending/播放期间 FSM 自动闭麦，说完自动恢复聆听

## 收到别的小朋友的喊话：他的副本头顶亮个说话泡 + 用他的音色（服务端盖章）把话念出来。
## 「喊话」模型：不用进任何状态就能听见（现实里有人跟你说话你也不用先按接听）。
func _on_player_speech(data: Dictionary) -> void:
	var text := String(data.get("text", ""))
	if text.is_empty():
		return
	var from := String(data.get("fromPlayerId", ""))
	var ra: Dictionary = _remote_actors.get(from, {})
	if not ra.is_empty():
		_pop_notice_bubble(ra, "happy") # 说话泡：头顶亮表情（内容靠 TTS 念，幼儿不识字）
	var disp := String((_presence.get(from, {}) as Dictionary).get("name", ""))
	banner.text = ("%s：%s" % [disp, text]) if not disp.is_empty() else text
	banner.visible = true
	_speak_line(text, String(data.get("voiceId", ""))) # 播放期间 FSM 闭麦（半双工防自听）

## 进对话对方先打招呼：小仙子走预制语音（离线可用、零延迟），普通 NPC 走服务端招呼
## （按角色风格选词、用其 voiceId 流式 TTS，回 character_response 走 _on_character_response 播放）。
## 招呼是可选点缀：仙子无预制词/NPC 离线或服务端静默跳过时，直接进开放麦，玩家仍可开口。
func _greet_on_enter(d: Dictionary) -> void:
	if d.is_empty():
		return
	if d.get("is_fairy", false):
		if fairy_voice != null:
			fairy_voice.try_play("greet")
		return
	var id := String(d.get("id", ""))
	if not id.is_empty() and backend != null:
		backend.send_greeting(world_id, id)

func _exit_interaction() -> void:
	_flush_pending_leave() # 玩家自己走开：孩子下的指令照发，不丢（幂等，正常路径已清空）
	game_audio.play_sfx("exit")
	if _in_creation:
		_in_creation = false # 退出与小仙子的交互：取消未完成的造角色会话
		_hide_creation_cards()
		_clear_creation_placeholder() # 造还没开工：引导期立的蛋/炉跟着收，别留在地上空烧
		_clear_build_preview() # 拼装台同理：走开即收，别把半拼的骨架留在仙子身旁
		if online:
			backend.send_creation_cancel()
	_vc.close() # 关麦（录音中则先静默取消，不留半开会话）
	selected = null
	_sync_guide_button() # 退出对话：引路继续，按钮跟着回来
	if _sticker_view != null:
		_sticker_view.visible = false # 退对话收贴纸盘
	_sticker_pick = ""
	_reset_empty_streak()
	# 中途退出时清掉未完成的小跳（保留当前位置，不瞬移回落点）
	if not player.is_empty():
		player.erase("_hop")
		player.erase("hover")
	_hop_t = -1.0
	_resume_stopped_npc() # 被叫停等玩家的对象恢复闲逛
	# 切回跟随玩家视角（平滑过渡）
	_locked = null
	_target_pitch = GOD_PITCH_DEG
	_target_dist = GOD_DIST
	banner.visible = false
	heard_label.visible = false
	thinking_label.visible = false

# ── M2 语音交互 ──────────────────────────────────────────────────────────

func _setup_backend() -> void:
	backend = Backend.new()
	backend.name = "Backend"
	add_child(backend)
	backend.connected.connect(_send_world_info) # 每次连上（含重连）上报地点名，喂意图 LLM
	backend.connected.connect(backend.send_time_sync) # 连上即做时间偏移握手（倒计时 HUD 双端读数一致）
	backend.character_response.connect(_on_character_response)
	backend.world_state.connect(_on_world_state)
	backend.task_complete.connect(_on_task_complete)
	backend.task_offer.connect(_on_task_offer)          # 剧情互动委托（M2）：演出收场直接递

	backend.npc_wishes.connect(_on_npc_wishes)
	backend.praise_tts.connect(_on_praise_tts)
	backend.wish_trial.connect(_on_wish_trial)          # A1 试用：开变大/变小箭头
	backend.wish_retry.connect(_on_wish_retry)          # 调反：仙子升级问句
	backend.character_resized.connect(_on_character_resized) # 造角色体型改了：重渲染
	backend.tts_chunk.connect(_on_tts_chunk)
	# 残余积压由 _drain_tts_stream 排空；generator 不会自己停，标记后播完主动 stop
	# （否则 _tts_player.playing 永真 → 开放麦永久闭麦、小仙子永久闭嘴）
	backend.tts_end.connect(func() -> void: _tts_ending = true)
	# tts_request 降级流：tts_start 开流并解除 pending；tts_failed 静默放弃本句（只解除 pending）
	backend.tts_start.connect(_on_tts_start)
	backend.tts_failed.connect(func() -> void: _tts_pending = false)
	backend.gen_progress.connect(_on_gen_progress)
	backend.gen_complete.connect(_on_gen_complete)
	backend.creation_prompt.connect(_on_creation_prompt)
	backend.build_prompt.connect(_on_build_prompt)
	backend.build_options.connect(_on_build_options)
	backend.creation_cancelled.connect(_on_creation_cancelled)
	backend.prop_pending.connect(_on_prop_pending)
	backend.item_created.connect(_on_item_created)
	backend.item_updated.connect(_on_item_updated) # B3 起名回填：就地更新背包里那件的 nameVoiceAsset
	backend.prop_failed.connect(_on_prop_failed)
	backend.sticker_pending.connect(_on_sticker_pending)
	backend.sticker_failed.connect(_on_sticker_failed)
	backend.prop_denied.connect(_on_reward_denied)
	backend.bag_update.connect(_on_bag_update)
	backend.sticker_bought.connect(_on_sticker_bought)
	backend.character_attach.connect(_on_character_attach)
	backend.player_attach.connect(_on_player_attach) # 自己/别人的贴纸挂摘广播（self-stickers）
	backend.sticker_denied.connect(_on_sticker_denied)
	backend.gen_denied.connect(_on_reward_denied)
	backend.failed.connect(_on_failed)
	# 舞台协议（剧本系统）：StageAgent 消费下行、经 send_stage_event 回执；world 作能力宿主。
	_stage = StageAgent.new()
	_stage.setup(self, Callable(backend, "send_stage_event"))
	backend.stage_begin.connect(_stage.on_stage_begin)
	backend.stage_cmd.connect(_stage.on_stage_cmd)
	backend.stage_end.connect(_stage.on_stage_end)
	backend.stage_abort.connect(_stage.on_stage_abort)
	backend.world_host.connect(_stage.on_world_host)
	backend.world_host.connect(_on_world_host_changed) # 升任 host：立即接管 NPC 模拟（不等复制缓冲陈旧）
	backend.time_sync.connect(_stage.on_time_sync)
	backend.positions_relay.connect(_on_positions_relay) # 多人位置复制：远端 actor 插值渲染
	backend.ball_kick.connect(_on_ball_kick)             # C 档球：他端踢球→转所有权+播种缓冲
	backend.ball_settle.connect(_on_ball_settle)         # C 档球：他端滚停→交回 host 中立
	backend.actor_leave.connect(_on_actor_leave)         # 玩家离场：即时清掉其远端副本
	backend.actors_snapshot.connect(_on_actors_snapshot) # 在场名单：静止的小朋友也立起来
	backend.actor_join.connect(_on_actor_join)           # 玩家进场：带真实立绘立副本
	backend.character_spawned.connect(_on_character_spawned) # 别人造的新伙伴：就地降生
	backend.player_emote.connect(_on_player_emote)       # 别的小朋友的表情动作：副本演起来+自动回礼
	backend.hearts_update.connect(func(d: Dictionary) -> void: _apply_wallet(d.get("wallet"))) # 收到爱心：钱包同步,集邮册点亮
	backend.villager_hail_tts.connect(_on_villager_hail_tts) # 村民主动打招呼：村民身上的 3D 定位音（P3）
	backend.wallet_update.connect(_on_villager_gift) # 外向村民送花：钱包同步 + 飞花庆祝（P4）
	backend.player_speech.connect(_on_player_speech)     # 别的小朋友的喊话：TTS 念出来+说话泡
	backend.scene_entered.connect(_on_scene_entered) # 走 portal 换场景：卸旧场景、载新场景
	backend.terrain_patch.connect(_on_terrain_patch) # 地形矩阵增量更新（tile 编辑广播）
	# 「思考中」兜底超时：即使 voice_failed/character_response 都没回来（响应丢失/TLS/网络），
	# 也在 THINK_TIMEOUT 秒后自动解卡——这是无论后端如何都不再永久卡死的最后一道保险。
	_think_timer = Timer.new()
	_think_timer.one_shot = true
	_think_timer.timeout.connect(_on_think_timeout)
	add_child(_think_timer)
	# B3 起名静默超时：点点问完孩子没吭声就放弃（起名是邀请不是关卡）。
	_naming_timer = Timer.new()
	_naming_timer.one_shot = true
	_naming_timer.timeout.connect(_on_naming_timeout)
	add_child(_naming_timer)

func _on_think_timeout() -> void:
	if thinking_label.visible:
		_on_failed("响应超时（没收到回复）")

## 语音/造角色失败：清掉「思考中」，温和提示重试——否则客户端会一直卡在思考中。
func _on_failed(reason: String) -> void:
	if _think_timer != null:
		_think_timer.stop()
	thinking_label.visible = false
	# gen_failed 也走这里（backend 把它并进 failed）：造砸了就把传送门收起来，
	# 否则它会一直亮着，孩子等一个永远不来的新朋友。
	# 传送门真立起过 → 是造角色翻车（非 ASR 没听清），点点笑自己手笨；ASR 没听清不发这句。
	if _clear_placeholder(PLACEHOLDER_PORTAL_ID).x >= 0:
		_fairy_say("create_fail")
	game_audio.play_sfx("oops")
	push_warning("voice/gen failed: %s" % reason)
	if selected != null:
		banner.text = "我没听清呀，再说一次好不好？"
		banner.visible = true
		_vc.cancel() # 录音中则静默丢弃本段，麦克风继续开着让孩子重说（幂等）

## 在线引导：GET /worlds/default → 连 WS → 按世界状态生成角色（含点点）。离线则保留占位 NPC。
## _bootstrapping 全程置位，无论在线/离线都在收尾清零——world_ready 就绪判定据此知道引导已结束。
## 当前场景 id（模型 B：world 含多 scene）。进世界时按初始场景置初值，走 portal（enter_scene）时更新。
var _scene_id := "village"

## 「家」= 初始世界（初始场景 village）的原点 tile(0,0)。手机「回家」app 的目的地：
## scene_compose 保证原点 8 tile 内保持开阔空地（出生林间空地），落这里绝不会被围死。
const HOME_SCENE := "village"
const HOME_TILE := Vector2i.ZERO

## 当前场景的传送点（服务端 scenes[].portals / scene_entered 的 scene.portals 下发）。
## 运行期结构 { tile: Vector2i, radius: float, to_scene: String, to_tile: Vector2i }。
var _portals: Array = []
## 传送去抖：刚换完场景玩家就站在返回传送点上，必须先走出所有半径才重新武装，否则来回弹。
var _portal_armed := false

const FADE_TIME := 0.35          ## 过场遮罩淡入/淡出各自的时长（秒）
const TRANSITION_TIMEOUT := 8.0  ## 服务端不回 scene_entered / 区块铺不完时的兜底：强行淡出，别把小朋友关在黑屏里
var _fade_rect: ColorRect        ## 过场遮罩底色（纯色兜底 + 吃掉乱点；水彩底/仙子缺素材时至少不透光）
var _fade_a := 0.0               ## 过场遮罩当前不透明度
var _fade_target := 0.0          ## 过场遮罩目标不透明度（1=遮住，0=露出世界）
var _transitioning := false      ## 过场进行中：禁止再次触发传送
var _pending_scene := ""         ## 全黑之后才发 enter_scene——卸旧载新绝不在半透明时发生
var _await_skin := false         ## 新场景已落地，等区块重铺完（all_skinned）再淡出
var _transition_t := 0.0         ## 本次过场累计秒（超时兜底用）
var _arrive_tile := Vector2i(-1, -1) ## 走 portal 的目标落点（优先于服务端记的该场景最后位置）

# —— 过场 loading 遮罩：水彩底 + 呼吸小仙子 + 「传送中」脉动点，与 _fade_rect 同步淡入淡出，
#    让换场景看起来像在读条而非闪屏 bug。素材复用开场加载页（Loading 的图集常量/贴图）。——
var _transition_overlay: Control        ## loading 内容根（bg + 仙子 + 文字，整体随 _fade_a 淡）
var _tr_fairy: TextureRect              ## 过场小仙子（idle 图集逐帧）
var _tr_fairy_atlas: AtlasTexture       ## 取帧窗口（每帧移 region）
var _tr_dots: Array[ColorRect] = []     ## 「传送中」后的三个脉动点
var _tr_anim_t := 0.0                   ## 过场动画累计秒（帧步进/呼吸/脉动共用）

## 传送门视觉标记（每个 portal 一座拱门）。刻意不走 chunk_manager 的 SDF 物件通道：那条路会
## 登记占地（把传送点本身挡住）并进 _dynamic_props（长按就被当语音物件揣走）。这里由 world 直接
## 持有节点、逐帧按环面最短位移摆位；SdfProp 材质自带 world-bend，不再 CPU 端压 y（与区块内物件同口径）。
const PORTAL_MARKER_SPEC := "res://assets/sdf_props/portal_arch.json"
var _portal_markers: Array = [] ## [{ node: SdfProp, logical: Vector2 }]

## —— 回家传送门过场（home-portal-anim）——
## 「回家」逃生舱从瞬移重做成「召唤门 → 走进 → 幕后传送 → 走出 → 门消散」的动画。
## 临时门存 _home_portals（独立于 _portal_markers：换场景 _unload_scene 不误清、也绝不进 _portals，
## 故 _step_portal 不理它、Mover 不参与脚本 lerp——被树围死也必定走完动画）。状态机见 _step_home；
## 跨场景与同场景（软过场）共用 _step_transition 的黑幕中段。SdfProp 禁缩放（sdf_prop.gd 契约）、
## shader 不透明无 alpha，故召唤/消散只能用 position.y 从地下升起/沉下（地面不透明网格天然裁掉埋下的部分）。
enum { HP_IDLE, HP_RISE_NEAR, HP_WALK_IN, HP_CROSS_WAIT, HP_SOFT_BLACK, HP_WALK_OUT_WAIT, HP_WALK_OUT, HP_DISPEL }
const HOME_WALK_DUR := 0.55          ## 走进/走出单程时长（秒）
const HOME_RISE_DUR := 0.35          ## 门从地下升起/沉下时长（秒）
const HOME_NEAR_MAX_R := 2           ## 近门离玩家最多几格；超了退脚下（逃生舱：保证卡死也能走进）
const HOME_PORTAL_SINK := 3.6        ## 召唤前把门沉到地下的深度（拱高≈3.56，够藏住）
const HOME_FAILSAFE := 12.0          ## 总超时兜底（秒）：强制收尾回原点，别把小朋友卡在动画里
var _homing := false                 ## 回家动画进行中（锁玩家输入，见 _physics_process/_unhandled_input）
var _home_cross := false             ## 本次回家是否跨场景（true=enter_scene 换场景；false=同场景软过场）
var _home_phase := HP_IDLE           ## 当前阶段
var _home_t := 0.0                   ## 当前阶段计时（走进/走出 lerp 进度、升起进度按它算，切阶段清零）
var _home_total_t := 0.0             ## 整段过场累计秒（超时兜底 HOME_FAILSAFE 用，跨阶段不清零）
var _home_from := Vector2.ZERO       ## 走进/走出 lerp 起点（逻辑坐标）
var _home_to := Vector2.ZERO         ## 走进/走出 lerp 终点（逻辑坐标）
var _home_portals: Array = []        ## 临时门 [{ node: SdfProp, logical: Vector2, rise: float }]

## 服务端下发的 portals → 运行期结构。非法条目跳过（坏一条不连坐整批）。
static func parse_server_portals(list: Variant) -> Array:
	if typeof(list) != TYPE_ARRAY:
		return []
	var out: Array = []
	for e in (list as Array):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		var t: Variant = d.get("tile", null)
		var tt: Variant = d.get("toTile", null)
		if typeof(t) != TYPE_ARRAY or (t as Array).size() != 2:
			continue
		if typeof(tt) != TYPE_ARRAY or (tt as Array).size() != 2:
			continue
		var to_scene := String(d.get("toScene", ""))
		if to_scene.is_empty():
			continue
		var tile := Vector2i(int((t as Array)[0]), int((t as Array)[1]))
		var to_tile := Vector2i(int((tt as Array)[0]), int((tt as Array)[1]))
		if not WorldGrid.is_valid_tile(tile) or not WorldGrid.is_valid_tile(to_tile):
			continue
		var radius := float(d.get("radius", 3.0))
		if radius <= 0.0:
			continue
		out.append({ "tile": tile, "radius": radius, "to_scene": to_scene, "to_tile": to_tile })
	return out

## pos 落在哪个传送点半径内（环面最短距离，世界坐标单位）；都不在返回 {}。纯函数便于回测。
static func portal_hit(portals: Array, pos: Vector2) -> Dictionary:
	for p in portals:
		var center := WorldGrid.from_tile_center(p["tile"] as Vector2i)
		if WorldGrid.shortest_delta(pos, center).length() <= float(p["radius"]):
			return p
	return {}

## 每帧检查玩家是否踏进传送点。走出所有半径才重新武装——刚从对面穿过来时玩家正站在
## 返回传送点上，若不去抖会立刻被弹回去。
func _step_portal() -> void:
	if _transitioning or _portals.is_empty() or player.is_empty():
		return
	var hit := portal_hit(_portals, player["logical"])
	if hit.is_empty():
		_portal_armed = true
		return
	if not _portal_armed:
		return
	enter_scene(String(hit["to_scene"]), hit["to_tile"] as Vector2i)

## 为当前 _portals 各立一座传送门拱（换场景时先 _clear_portal_markers 再重建）。
## spec 坏了就不立——世界照常能玩，只是传送点没有地标。
func _spawn_portal_markers() -> void:
	_clear_portal_markers()
	for p in _portals:
		var prop := SdfProp.from_json_file(PORTAL_MARKER_SPEC)
		if prop == null:
			push_warning("[portal] 传送门标记 spec 载入失败：%s" % PORTAL_MARKER_SPEC)
			return
		add_child(prop)
		_portal_markers.append({ "node": prop, "logical": WorldGrid.from_tile_center(p["tile"] as Vector2i) })

func _clear_portal_markers() -> void:
	for m in _portal_markers:
		var node: Variant = m.get("node", null)
		if node != null and is_instance_valid(node):
			(node as Node).queue_free()
	_portal_markers.clear()

## 召唤一座临时回家门：初始埋在地下（rise=0），随后由 _step_home 的升起/沉下阶段推进 rise。
## 门只是装饰，绝不进 _portals（_step_portal 不理它、Mover 不参与脚本 lerp）。返回门记录字典。
func _summon_home_portal(tile: Vector2i) -> Dictionary:
	var prop := SdfProp.from_json_file(PORTAL_MARKER_SPEC)
	if prop == null:
		push_warning("[home] 回家门 spec 载入失败：%s" % PORTAL_MARKER_SPEC)
		return {}
	add_child(prop)
	var rec := { "node": prop, "logical": WorldGrid.from_tile_center(tile), "rise": 0.0 }
	_home_portals.append(rec)
	_place_portal_node(prop, rec["logical"], -HOME_PORTAL_SINK) # 先埋地下，避免召唤当帧闪现半空
	return rec

## 逐帧把临时回家门摆到渲染空间，按各自 rise∈[0,1] 从地下升起（extra_y = -(1-rise)*sink）。
## SdfProp 禁缩放，故用 position.y 平移做召唤/消散，地面不透明网格天然裁掉埋在下面的部分。
func _update_home_portals() -> void:
	for rec in _home_portals:
		var node: Variant = rec.get("node", null)
		if node == null or not is_instance_valid(node):
			continue
		var rise := clampf(float(rec.get("rise", 1.0)), 0.0, 1.0)
		_place_portal_node(node as Node3D, rec["logical"], -(1.0 - rise) * HOME_PORTAL_SINK)

## 消散并释放所有临时回家门（沉下动画由 HP_DISPEL 阶段先把 rise 推回 0 再调用）。
func _dispel_home_portals() -> void:
	for rec in _home_portals:
		var node: Variant = rec.get("node", null)
		if node != null and is_instance_valid(node):
			(node as Node).queue_free()
	_home_portals.clear()

## 切回家过场阶段并复位阶段计时（走进/走出的 lerp 进度按 _home_t 算）。
func _home_set_phase(p: int) -> void:
	_home_phase = p
	_home_t = 0.0

## 走进/走出：把 player["logical"] 从 _home_from smoothstep 插值到 _home_to。刻意**不设 _hop 标志**——
## _update_paper_motion 的 _hop 分支会冻结位移速度、压掉 walk_bob；走正常分支才有踏步。返回 true=到位。
func _step_home_walk(delta: float) -> bool:
	if player.is_empty():
		return true
	_home_t += delta
	var k := clampf(_home_t / HOME_WALK_DUR, 0.0, 1.0)
	var seg := WorldGrid.shortest_delta(_home_from, _home_to)
	player["logical"] = WorldGrid.wrap_pos(_home_from + seg * smoothstep(0.0, 1.0, k))
	if k >= 1.0:
		player["logical"] = _home_to
		OccupancyMap.char_register(PLAYER_ID, _home_to, PLAYER_SPAN)
		return true
	return false

## 给所有临时门设升起进度（同一时刻只有一座活动门：升起时是近门、走出时是远门）。
func _set_home_portals_rise(v: float) -> void:
	var r := clampf(v, 0.0, 1.0)
	for rec in _home_portals:
		rec["rise"] = r

## 回家走进/走出的落脚点：给定位置正前方约 2 格找可走空位（看得见「走一步」）；那一带被挡就返回原位
## （走 0 步）。逃生舱铁律：走进/走出是直线 lerp、不寻路、终点必可走，被树围死也走得完（≤2 格、直线穿过）。
func _home_step_spot(from_pos: Vector2) -> Vector2:
	var here := WorldGrid.to_tile(from_pos)
	var max_d := float(HOME_NEAR_MAX_R) * WorldGrid.TILE_SIZE + 0.1
	for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1)]:
		var spot := _find_free_spot(WorldGrid.from_tile_center(here + d * 2), PLAYER_SPAN)
		if WorldGrid.shortest_delta(from_pos, spot).length() <= max_d:
			return spot
	return from_pos

## 起动回家传送门过场：召唤近门（玩家正前方可走格）→ 走进 → (跨场景)enter_scene /(同场景)软过场 → 走出 → 消散。
func _begin_homing(cross: bool) -> void:
	# 清掉会干扰过场/镜头的在飞态：摆放/试用直接丢弃；在交互中就退出——否则走路镜头会锁在
	# NPC 身上（焦点分支 _locked 优先于 player），玩家走出画面外。
	if _placing:
		_end_placement()
	if _refine_active:
		_end_refine()
	if selected != null:
		_exit_interaction()
	_cancel_player_move()
	_clear_approach()
	_home_cross = cross
	_homing = true
	_home_total_t = 0.0
	_home_from = player["logical"]
	var near := _home_step_spot(player["logical"])
	_home_to = near
	_summon_home_portal(WorldGrid.to_tile(near))
	_home_set_phase(HP_RISE_NEAR)
	if game_audio != null:
		game_audio.play_sfx("whoosh")

## 强制收尾回家过场（兜底/异常）：清临时门、解锁，玩家留在当前逻辑位。
func _abort_homing() -> void:
	_dispel_home_portals()
	_home_phase = HP_IDLE
	_homing = false

## 超时兜底：不管卡在哪个阶段，强制把玩家硬着陆到原点、清门、收黑幕、解锁——
## 宁可硬跳也不能把小朋友永久卡在动画/黑屏里（逃生舱的底线）。
func _force_finish_homing() -> void:
	push_warning("[home] 回家过场超时（%.1fs），强制收尾" % _home_total_t)
	if not player.is_empty():
		OccupancyMap.char_unregister(PLAYER_ID)
		var spot := _find_free_spot(WorldGrid.from_tile_center(HOME_TILE), PLAYER_SPAN)
		player["logical"] = spot
		OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)
		focus_logical = spot
	_dispel_home_portals()
	_fade_target = 0.0        # 收黑幕（_step_transition 会把 _fade_a 淡回 0）
	_transitioning = false
	_home_phase = HP_IDLE
	_homing = false

## 同场景回家软过场：直接驱动 _step_transition 的黑幕（_pending_scene 留空→不发换场景报文），
## 全黑时刻再把玩家瞬移到原点（黑幕遮住），召远门、定走出端点，然后淡出、走出。复用同一张
## 水彩+仙子 loading 遮罩，与跨场景观感一致；需求 2：村里回家也走完整动画，不再静默 snap。
func _begin_soft_home() -> void:
	_transitioning = true
	_transition_t = 0.0
	_fade_target = 1.0
	_pending_scene = ""            # 空→_step_transition 全黑时不发任何报文
	_await_skin = false
	_arrive_tile = Vector2i(-1, -1)
	if game_audio != null:
		game_audio.play_sfx("whoosh")
	_home_set_phase(HP_SOFT_BLACK)

## 软过场全黑时刻的重定位：把玩家（和跟随的仙子）搬到原点空位，销近门、在落点召远门（揭幕即立），
## 定走出端点。全在黑幕背后发生，瞬移不穿帮。
func _relocate_home_and_summon_far() -> void:
	if player.is_empty():
		return
	OccupancyMap.char_unregister(PLAYER_ID)
	var spot := _find_free_spot(WorldGrid.from_tile_center(HOME_TILE), PLAYER_SPAN)
	player["logical"] = spot
	OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)
	focus_logical = spot
	var fairy := _find_fairy()
	if not fairy.is_empty():
		fairy["logical"] = WorldGrid.wrap_pos(focus_logical + Vector2(2.6, 1.8))
	_dispel_home_portals() # 近门先销
	var rec := _summon_home_portal(WorldGrid.to_tile(spot))
	if not rec.is_empty():
		rec["rise"] = 1.0 # 远门立着（玩家从里走出）
	_home_from = player["logical"]
	_home_to = _home_step_spot(player["logical"])

## 回家传送门过场状态机推进（home-portal-anim）。
## RISE_NEAR(门升起) → WALK_IN(走进) → 跨场景 CROSS_WAIT(黑幕换场景) / 同场景软过场(P6) → WALK_OUT(走出) → DISPEL(门沉下消散)。
func _step_home(delta: float) -> void:
	if not _homing:
		return
	_home_total_t += delta
	if _home_total_t > HOME_FAILSAFE: # 卡死兜底：任何阶段超时都硬着陆回原点
		_force_finish_homing()
		return
	match _home_phase:
		HP_RISE_NEAR:
			_home_t += delta
			_set_home_portals_rise(_home_t / HOME_RISE_DUR)
			if _home_t >= HOME_RISE_DUR:
				_home_set_phase(HP_WALK_IN)
		HP_WALK_IN:
			if _step_home_walk(delta):
				if _home_cross:
					enter_scene(HOME_SCENE, HOME_TILE) # 跨场景：黑幕接管，_on_scene_entered 落原点+接走出
					_home_set_phase(HP_CROSS_WAIT)
				else:
					_begin_soft_home() # 同场景软过场（P6 填入黑幕；P5 未接线走不到这里）
		HP_CROSS_WAIT:
			# 黑幕/换场景由 _step_transition + _on_scene_entered 接管：那边销近门、在落点召远门、
			# 把玩家坐门上、定走出端点。等过场彻底收尾（不再 _transitioning）再走出。
			if not _transitioning:
				_home_set_phase(HP_WALK_OUT)
		HP_SOFT_BLACK:
			# 同场景软过场：等黑幕全黑再瞬移到原点（遮住），召远门、定走出端点，然后淡出。
			if _fade_a >= 1.0:
				_relocate_home_and_summon_far()
				_fade_target = 0.0
				_home_set_phase(HP_WALK_OUT_WAIT)
		HP_WALK_OUT_WAIT:
			# 等黑幕淡出（露出站在门里的玩家）再迈步走出。
			if _fade_a <= 0.0:
				_home_set_phase(HP_WALK_OUT)
		HP_WALK_OUT:
			if _step_home_walk(delta):
				_home_set_phase(HP_DISPEL)
		HP_DISPEL:
			_home_t += delta
			_set_home_portals_rise(1.0 - _home_t / HOME_RISE_DUR) # 门沉回地下
			if _home_t >= HOME_RISE_DUR:
				_dispel_home_portals()
				_home_phase = HP_IDLE
				_homing = false
		_:
			pass

## 把一座拱门摆到渲染空间（渲染原点 = focus_logical），高度取所在 tile 的台阶高 + extra_y。
## extra_y 给回家临时门做「从地下升起/沉下」的召唤/消散动画（负值=埋在地下，见 _step_home）。
func _place_portal_node(node: Node3D, logical: Vector2, extra_y: float = 0.0) -> void:
	var d := WorldGrid.shortest_delta(focus_logical, logical)
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(logical))) * TerrainMap.STEP_HEIGHT
	node.position = Vector3(d.x, ty + extra_y, d.y)

## 逐帧把拱门摆到渲染空间（渲染原点 = focus_logical），高度取所在 tile 的台阶高。
func _update_portal_markers() -> void:
	for m in _portal_markers:
		var node: Variant = m.get("node", null)
		if node == null or not is_instance_valid(node):
			continue
		_place_portal_node(node as Node3D, m["logical"], 0.0)

## 过场黑幕推进：淡入 → 全黑后才发 enter_scene → 卸旧载新 → 区块铺完 → 淡出。
func _step_transition(delta: float) -> void:
	if not _transitioning and _fade_a <= 0.0:
		return
	_transition_t += delta
	var step := delta / FADE_TIME
	_fade_a = clampf(_fade_a + (step if _fade_target > _fade_a else -step), 0.0, 1.0)
	if _fade_rect != null:
		_fade_rect.visible = _fade_a > 0.001
		_fade_rect.modulate.a = _fade_a
	if _transition_overlay != null:
		_transition_overlay.visible = _fade_a > 0.001
		_transition_overlay.modulate.a = _fade_a
		if _transition_overlay.visible:
			_step_transition_fairy(delta)

	# 全黑了才发报文：换场景的卸旧载新一律发生在黑幕背后
	if not _pending_scene.is_empty() and _fade_a >= 1.0:
		if online and backend != null:
			backend.send_enter_scene(world_id, _pending_scene)
		_pending_scene = ""

	# 兜底：服务端没回 scene_entered，或区块迟迟铺不完——到点强行淡出，宁可看见半铺的地也不黑屏
	if _transitioning and _transition_t >= TRANSITION_TIMEOUT and _fade_target > 0.0:
		push_warning("[portal] 换场景超时（%.1fs），强制淡出" % _transition_t)
		_pending_scene = ""
		_await_skin = false
		_arrive_tile = Vector2i(-1, -1)
		_fade_target = 0.0

	if _await_skin and (chunk_manager == null or chunk_manager.all_skinned()):
		_await_skin = false
		_fade_target = 0.0

	if _transitioning and _fade_target <= 0.0 and _fade_a <= 0.0 \
			and _pending_scene.is_empty() and not _await_skin:
		_transitioning = false

## 过场 loading 遮罩内容：水彩底（bg_menu，COVERED 铺满）+ 居中呼吸小仙子（idle 图集，
## 缺图集回落静态立绘、再缺就不放）+「传送中」脉动点。整体随 _fade_a 淡入淡出（父 modulate）。
## 素材/图集常量复用开场加载页（Loading），避免两处画风漂移；不自己造轮子。
func _build_transition_overlay() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.visible = false
	root.modulate.a = 0.0
	# 水彩底：撑满屏、等比裁切铺满（与菜单/加载页同一张）
	var bg_tex := UiAssets.tex("bg_menu")
	if bg_tex != null:
		var bg := TextureRect.new()
		bg.texture = bg_tex
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(bg)
	# 居中一列：小仙子 +「传送中」文字+脉动点
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 18)
	center.add_child(col)
	# 小仙子：idle 图集逐帧（AtlasTexture 每帧移 region，见 _step_transition_fairy）
	_tr_fairy = TextureRect.new()
	var sheet := load("res://assets/fairy_idle.webp") as Texture2D
	if sheet != null:
		_tr_fairy_atlas = AtlasTexture.new()
		_tr_fairy_atlas.atlas = sheet
		_tr_fairy_atlas.region = Rect2(0, 0, Loading.FAIRY_CELL_W, Loading.FAIRY_CELL_H)
		_tr_fairy.texture = _tr_fairy_atlas
	elif ResourceLoader.exists("res://assets/fairy.png"):
		_tr_fairy.texture = load("res://assets/fairy.png")
	_tr_fairy.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tr_fairy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_tr_fairy.custom_minimum_size = Vector2(Loading.FAIRY_W, Loading.FAIRY_H)
	_tr_fairy.pivot_offset = Vector2(Loading.FAIRY_W * 0.5, Loading.FAIRY_H * 0.5) # 呼吸缩放绕框心
	_tr_fairy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_tr_fairy)
	# 「传送中」+三个脉动点（少文字，纯 UI 提示在读条）
	var dot_row := HBoxContainer.new()
	dot_row.alignment = BoxContainer.ALIGNMENT_CENTER
	dot_row.add_theme_constant_override("separation", 10)
	var label := Label.new()
	label.text = "传送中"
	UiAssets.style_card_label(label, 40)
	label.add_theme_color_override("font_color", Color(0.42, 0.30, 0.18)) # 暖棕（水彩底上可读）
	dot_row.add_child(label)
	_tr_dots.clear()
	for _i in 3:
		var d := ColorRect.new()
		d.color = Color(0.42, 0.30, 0.18)
		d.custom_minimum_size = Vector2(12.0, 12.0)
		d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot_row.add_child(d)
		_tr_dots.append(d)
	col.add_child(dot_row)
	return root

## 每帧推进过场小仙子（图集帧步进 8fps + 轻微呼吸缩放）与「传送中」三点波浪脉动。
func _step_transition_fairy(delta: float) -> void:
	_tr_anim_t += delta
	if _tr_fairy_atlas != null:
		var frame := int(_tr_anim_t * Loading.FAIRY_SHEET_FPS) % Loading.FAIRY_SHEET_FRAMES
		var cx := (frame % Loading.FAIRY_SHEET_COLS) * Loading.FAIRY_CELL_W
		var cy := (frame / Loading.FAIRY_SHEET_COLS) * Loading.FAIRY_CELL_H
		_tr_fairy_atlas.region = Rect2(cx, cy, Loading.FAIRY_CELL_W, Loading.FAIRY_CELL_H)
	if _tr_fairy != null:
		var breath := 1.0 + 0.04 * sin(_tr_anim_t * 3.0)
		_tr_fairy.scale = Vector2(breath, breath)
	for i in _tr_dots.size():
		var ph := _tr_anim_t * 3.2 - float(i) * 0.6
		_tr_dots[i].modulate.a = 0.35 + 0.65 * (0.5 + 0.5 * sin(ph))

## 当前场景的地形矩阵版本（terrain_patch 严格 +1 对齐；0 = 打包/离线矩阵无版本）。
var _terrain_version := 0

## 地形矩阵增量更新（服务端 tile 编辑广播）。版本恰 +1 → 原地应用 + 精准重铺；
## 乱序/漏包/应用失败 → 全量重拉兜底（gzip 几 KB，代价可忽略）。
func _on_terrain_patch(data: Dictionary) -> void:
	if String(data.get("sceneId", "")) != _scene_id:
		return # 其他场景的编辑：下次进那场景时按 version 全量对齐
	ItemCatalog.set_defs(data.get("items", [])) # 新引用的造物实体定义随 patch 带上
	_prewarm_sticker_assets(data.get("items", [])) # 造贴纸摆到边缘随 patch 到:预热网络贴图
	var version := int(data.get("version", 0))
	if version == _terrain_version + 1:
		var r: Dictionary = TerrainMap.apply_patch(data)
		if r["ok"]:
			_terrain_version = version
			ItemCatalog.apply_static_occupancy()
			if chunk_manager != null:
				chunk_manager.rebuild_tiles(r["tiles"])
			_relocate_illegal_actors()
			return
		push_warning("[terrain] patch 应用失败(%s)，全量重拉" % r["error"])
	else:
		push_warning("[terrain] patch 版本 %d 与本地 %d 不衔接，全量重拉" % [version, _terrain_version])
	_refetch_terrain()

## 全量重拉当前场景矩阵（patch 对不上的自愈路径）。失败保留当前矩阵（宁可旧不可乱）。
func _refetch_terrain() -> void:
	if not online or api == null:
		return
	var tr: Dictionary = await api.fetch_terrain(world_id, _scene_id, 0)
	var buf: PackedByteArray = tr["bytes"]
	if buf.is_empty():
		push_warning("[terrain] 全量重拉失败，保留当前矩阵")
		return
	var r := TerrainMap.load_from_bytes(buf)
	if not r["ok"]:
		push_warning("[terrain] 全量重拉载荷非法(%s)" % r["error"])
		return
	_terrain_version = int(tr["version"])
	ItemCatalog.apply_static_occupancy()
	if r["changed"] and chunk_manager != null:
		chunk_manager.rebuild()
	_relocate_illegal_actors()

## 地形编辑后的兜底：站进新水面/新物品占地的角色就近挪位（挖水淹角色/物品压角色）。
## 只查脚下 tile 与占用位图，挪位复用降生同款 _find_free_spot（保守、确定性）。
func _relocate_illegal_actors() -> void:
	if not player.is_empty():
		var pl: Vector2 = player["logical"]
		if _spot_illegal(pl, PLAYER_SPAN, PLAYER_ID):
			var spot := _find_free_spot(pl, PLAYER_SPAN)
			player["logical"] = spot
			OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)
	for n_ in npcs:
		if bool(n_.get("is_fairy", false)):
			continue # 仙子悬浮飞行，不受地面占用/水面影响
		var lg: Vector2 = n_["logical"]
		var span := int(n_.get("span", 2))
		var nid := String(n_.get("id", ""))
		if _spot_illegal(lg, span, nid):
			var spot2 := _find_free_spot(lg, span)
			n_["logical"] = spot2
			OccupancyMap.char_register(nid, spot2, span)

## 角色站位是否非法：脚下 tile 变水，或脚印撞上静态/动态物件占用。
func _spot_illegal(pos: Vector2, span: int, _id: String) -> bool:
	if TerrainMap.tile_type(WorldGrid.to_tile(pos)) == TerrainMap.T_WATER:
		return true
	var origin := OccupancyMap.footprint_origin(pos, span)
	return not OccupancyMap.is_free_rect(origin, span, span)

## 打包默认矩阵（assets/terrain/village.mltr，导出工具产 v2）：离线/服务端未回前的
## 世界数据源。加载失败静默回落 _paint()（纯地貌、无物品的秃世界——极端兜底）。
func _load_packaged_terrain() -> void:
	var f := FileAccess.open("res://assets/terrain/%s.mltr" % _scene_id, FileAccess.READ)
	if f == null:
		push_warning("[terrain] 打包矩阵缺失（%s），回落 _paint 秃世界" % _scene_id)
		return
	var r := TerrainMap.load_from_bytes(f.get_buffer(f.get_length()))
	if not r["ok"]:
		push_warning("[terrain] 打包矩阵非法(%s)，回落 _paint" % r["error"])

## 从服务端下发的场景数组里取当前场景并载入（初始进世界用）。任何一步不成就静默保留本地
## 打包矩阵——离线、老服务端、地形未入库、载荷损坏，都必须能照常进世界。
func _load_server_terrain(scenes: Variant) -> void:
	if typeof(scenes) != TYPE_ARRAY or (scenes as Array).is_empty():
		return # 地形还没入库：走本地确定性生成，与改动前一致
	var scene: Dictionary = {}
	for s in scenes:
		if typeof(s) == TYPE_DICTIONARY and String((s as Dictionary).get("sceneId", "")) == _scene_id:
			scene = s
			break
	if scene.is_empty():
		return
	await _apply_scene(scene)

## 应用单个场景的 POI + 地形（初始进世界与换场景 enter_scene 共用）。terrain 变了就重铺全图
## 区块——见 docs/multi-scene-design.md 步骤⑤边界1：地形必须在 chunk 重铺之前就位（本函数
## load_from_bytes 先落地、changed 时才 rebuild），玩家落位在调用方于地形就位后再定。
func _apply_scene(scene: Dictionary) -> void:
	# POI 先应用：与地形字节相互独立，地形拉取失败不该把地点名一起丢了。
	# 解析不出任何合法 POI 时保留内置常量——绝不让世界变成没有地点的空壳。
	var sp := parse_server_pois(scene.get("pois", []))
	if not sp.is_empty():
		pois = sp

	# 传送点同理：地形拉不下来也要认这张图的 portal（走过去还能换场景）。
	# 没有 portal 的场景就是没有出口，_portals 置空即可（离线/老服务端下发不了 portals）。
	_portals = parse_server_portals(scene.get("portals", []))
	_spawn_portal_markers()

	# 地形拉取：有版本号走矩阵端点（(world,scene,version) 缓存，terrain_patch 对齐依据）；
	# 老服务端（version 0）回落内容寻址 asset 路径。
	var ver := int(scene.get("terrainVersion", 0))
	var buf: PackedByteArray
	if ver > 0:
		var tr: Dictionary = await api.fetch_terrain(world_id, String(scene.get("sceneId", _scene_id)), ver)
		buf = tr["bytes"]
		if not buf.is_empty():
			_terrain_version = int(tr["version"]) if int(tr["version"]) > 0 else ver
	else:
		var asset := String(scene.get("terrainAsset", ""))
		if asset.is_empty():
			return
		buf = await api.fetch_bytes(asset)
	if buf.is_empty():
		push_warning("[terrain] 拉取地形失败，沿用现有地形")
		return
	var r := TerrainMap.load_from_bytes(buf)
	if not r["ok"]:
		push_warning("[terrain] 服务端地形非法(%s)，沿用现有地形" % r["error"])
		return
	# 静态占用从矩阵物品层重派生（changed 与否都做：palette/实体定义可能更新）
	ItemCatalog.apply_static_occupancy()
	if r["changed"]:
		# 地形与当前 chunk 首铺用的不同：chunk_manager 缓存的区块 mesh 得整图重铺才能反映新地形
		# （初始进世界：首铺用本地 _paint()，今天导出字节 == _paint() 输出故 changed 恒 false；
		# 换场景：目标场景地形必然不同，changed=true）。玩家/角色落位由调用方在地形就位后再定。
		push_warning("[terrain] 地形与当前区块不一致，重铺全图区块")
		if chunk_manager != null:
			chunk_manager.rebuild()

## 走 portal 换场景的入口（_step_portal 调用）：黑幕淡入 → 全黑后 _step_transition 才发报文 →
## 服务端回 scene_entered → _on_scene_entered 卸旧载新 → 区块铺完淡出。离线/未连时静默忽略。
## arrive_tile 是传送点出口，落位优先于服务端记的该场景最后位置（否则会掉回上次离开的地方）。
func enter_scene(scene_id: String, arrive_tile := Vector2i(-1, -1)) -> void:
	if scene_id.is_empty() or scene_id == _scene_id or _transitioning:
		return
	if not online or backend == null:
		return # 离线：没有目标场景的数据，什么也别做
	_transitioning = true
	_transition_t = 0.0
	_portal_armed = false
	_arrive_tile = arrive_tile
	_pending_scene = scene_id
	_fade_target = 1.0
	if game_audio != null:
		game_audio.play_sfx("whoosh") # 黑幕淡入时的过场滑动声

## 手机「回家」app：把迷路/卡住的玩家送回初始世界原点。逃生舱语义——玩家穿传送门进森林后
## 可能落在被密林围死的落点动不了（森林落点根因），这个 app 保证一键脱困。
## 在线且不在 village → 走正常换场景过场（黑幕/loading 遮罩 + 服务端 scene_entered 落位），
## 落在原点空位；已在 village 或离线（无换场景数据）→ 就地把玩家（和跟随的仙子）挪回原点
## 附近空位解卡，不发换场景报文。
func _go_home() -> void:
	if _transitioning or _homing or _stage_active:
		return # 过场/回家进行中，或演出/游戏态：忽略（别把跑着的游戏一个人传走）
	_close_phone() # 传送前先收起手机（近身相机/遮罩一并还原）
	if player.is_empty():
		return
	if online and backend != null and _scene_id != HOME_SCENE:
		_begin_homing(true) # 跨场景：召唤门 → 走进 → enter_scene 落原点 → 走出 → 门消散
	else:
		_begin_homing(false) # 同场景/离线：软过场（黑幕遮住原地瞬移 → 走出），不发换场景报文

## 收到 scene_entered：卸载当前场景的角色/物件 → 上新地形并重铺区块 → 生成新场景角色/物件
## → 按该场景玩家最后位置落位。顺序保证「地形在 chunk 重铺、角色/玩家落位之前就位」
## （docs/multi-scene-design.md 步骤⑤边界1）。
func _on_scene_entered(data: Dictionary) -> void:
	var sid := String(data.get("sceneId", ""))
	if sid.is_empty():
		return
	_portal_armed = false # 落地时多半正站在返回传送点上：走出去才重新武装（_step_portal）
	_guide_on_scene_entered(sid) # 跨场景引路：推进到下一段（她在门这边送，到那边接着领）
	if _placing:
		_end_placement() # 换场景丢弃在飞的摆放（tile 索引跨场景无意义）
	if _refine_active:
		_end_refine() # 换场景丢弃在飞的试用调整（refineItemRef 跨场景无意义）
	_unload_scene()
	ItemCatalog.set_defs(data.get("items", [])) # 新场景可能引用没见过的造物实体
	_prewarm_sticker_assets(data.get("items", [])) # 造贴纸:预热网络贴图

	# 地形先就位（_apply_scene changed 时会 rebuild 区块）；scene 为 null 表示该场景未入库，
	# 保留当前地形（离线/未入库容错）。
	var scene: Variant = data.get("scene", null)
	if typeof(scene) == TYPE_DICTIONARY:
		await _apply_scene(scene as Dictionary)
	_scene_id = sid

	# 新场景角色：与初始进世界同一条并发预取 + 顺序降生链路。
	var chars: Array = data.get("characters", [])
	var prefetched := await _prefetch_characters(chars)
	for c in chars:
		await _spawn_server_character(c as Dictionary, Vector2.INF, prefetched)

	# 玩家落位：走 portal 来的落在传送点出口（_arrive_tile），否则用该场景的最后位置（服务端下发），
	# 再否则留在当前逻辑位。都会就近找空位避让新地形。
	var target := focus_logical
	if WorldGrid.is_valid_tile(_arrive_tile):
		target = WorldGrid.from_tile_center(_arrive_tile)
	else:
		var pp: Variant = data.get("playerPos", null)
		if typeof(pp) == TYPE_DICTIONARY:
			var tile := Vector2i(int((pp as Dictionary).get("tileX", -1)), int((pp as Dictionary).get("tileY", -1)))
			if WorldGrid.is_valid_tile(tile):
				target = WorldGrid.from_tile_center(tile)
	_arrive_tile = Vector2i(-1, -1)
	if not player.is_empty():
		OccupancyMap.char_unregister(PLAYER_ID)
		var spot := _find_free_spot(target, PLAYER_SPAN)
		player["logical"] = spot
		OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)
		focus_logical = spot
	# 点点跨场景跟随：服务端记的还是旧场景的坐标，重新降生后直接搬到玩家身旁
	# （黑幕遮着瞬移不穿帮），免得揭幕后从半张地图外飞一大段追过来。
	var fairy := _find_fairy()
	if not fairy.is_empty():
		fairy["logical"] = WorldGrid.wrap_pos(focus_logical + Vector2(2.6, 1.8))
	# 回家过场（跨场景）：黑幕后销毁旧场景的近门、在落点召唤远门（揭幕即立着），把玩家坐在门上、
	# 定走出端点。揭幕后玩家从门里走出到相邻空位，再由 HP_DISPEL 让门沉下消失。
	if _homing and _home_phase == HP_CROSS_WAIT and not player.is_empty():
		_dispel_home_portals() # 近门在旧场景，销掉（黑幕遮着不穿帮）
		var rec := _summon_home_portal(WorldGrid.to_tile(player["logical"]))
		if not rec.is_empty():
			rec["rise"] = 1.0
		_home_from = player["logical"]              # 从门里
		_home_to = _home_step_spot(player["logical"]) # 走到相邻空位
	# 新场景就位后向服务端重报地点名（意图 LLM 认新场景的 POI）。
	if online:
		_send_world_info()
	# 过场收尾交给 _step_transition：等新地形的区块全铺完（all_skinned）再淡出，
	# 否则黑幕撤掉时槽位还挂着旧场景的网格（rebuild 是逐帧重铺的）。
	if _transitioning:
		_await_skin = true

## 卸载当前场景的所有角色与物件（换场景时调用）。玩家节点跨场景保留（同一个小朋友）。
func _unload_scene() -> void:
	if selected != null:
		_exit_interaction() # 交互中切场景：先干净退出（清麦/相机/HUD/选中态）
	# 停掉所有 NPC 自主行为 + 玩家当前移动（都指向即将释放的节点）。
	# 必须先 cancel 再丢：cancel 把在途 A* 任务转孤儿交给集中回收；直接 clear() 的话任务
	# 既没转孤儿也没人 wait，其绑定 Callable 攥着 GDScript 对象活到引擎关停，
	# WorkerThreadPool 析构它时崩（退出期 exit 134/139，见 _exit_tree 与 flush_all_blocking）。
	for ex in _executors:
		(ex as BehaviorExecutor).cancel()
	_executors.clear()
	if _player_executor != null:
		_player_executor.cancel()
	_player_executor = null
	_approach = {}
	_stopped = {}
	# 占位符的节点随区块一起被清；只留下 id→tile 的记账，下次 _clear_placeholder 会去 pickup
	# 一个不存在的 prop，成品还会落到旧场景的坐标上。
	_placeholders.clear()
	_fairy_poi = {} # 旧场景的 POI 提醒点在新场景是野坐标，别让点点飞过去
	for n in npcs:
		if not bool(n.get("is_fairy", false)):
			OccupancyMap.char_unregister(String(n.get("id", "")))
		var node: Variant = n.get("node", null)
		if node != null and is_instance_valid(node):
			(node as Node).queue_free()
	npcs.clear()
	_villager_count = 0
	_reported_tiles.clear() # 位置去重重置：新场景角色从头全报一次
	# 动态物件（占位符/演出道具）：释放占地 + 清运行时清单（rebuild 后不再把旧场景的重生成过来）。
	# 矩阵物品随新场景地形自然重摆；背包是全世界共享的，跨场景保留。
	if chunk_manager != null:
		chunk_manager.clear_dynamic_props()
	_portals.clear() # 旧场景的出口不属于新场景；新场景的由 _apply_scene 重新下发
	_clear_portal_markers()
	# 旧场景的其他小朋友不在新场景里：清掉副本，等新场景的 actors_snapshot 重新立
	_clear_remote_actors()

## 初载角色过滤：只留当前场景的角色（点点恒随，与 enter_scene 同款约定）。get_world 回的是
## 全库角色，不过滤会把别场景的角色全生在村里，positions_report 随后把它们拖成 village
## （scene-drag-guard 实锤过：刚 seed 的森林村民被初载客户端整批拖空）。缺 sceneId 的存量按 village。
func _filter_boot_characters(all: Array) -> Array:
	var chars: Array = []
	for c in all:
		var cd := c as Dictionary
		if bool(cd.get("isFairy", false)) or String(cd.get("sceneId", "village")) == _scene_id:
			chars.append(cd)
	return chars

## 在线引导 = 拉取半段 + 应用半段顺序执行（现状路径，行为与拆分前一致）。
## intro 模式（P3+）把两段拆开：fetch 在建造演出期后台跑，apply 在转正点演出化执行。
func _bootstrap() -> void:
	var fetched := await _bootstrap_fetch()
	await _bootstrap_apply(fetched)

## 拉取半段：get_world + 实体定义就位 + 角色素材并发预取。**只落缓存/内存与数据，不动场景任何节点**
## （ItemCatalog.set_defs 是纯数据、_prefetch_characters 只写 asset 缓存）——故 intro 可后台跑这段而
## 世界仍是离线占位形态。返回 { world, chars, prefetched }；离线（get_world 空）返回 {}。
## 真正的场景变更（重铺地形/清占位/降生村民/搬玩家/接 WS）在 _bootstrap_apply。
func _bootstrap_fetch() -> Dictionary:
	_bootstrapping = true
	_player_restore_pending = true
	_boot_status = "连接精灵世界…"
	_apply_player_sprite() # 玩家自己的档案形象替换占位（并行拉取，不阻塞）——是占位的自我替换，非服务端状态
	# 每人一世界（世界模板架构 v2 §5）：默认按玩家 id 拿 w_<playerId>（服务端不存在则建+从 template 复制）；
	# MALIANG_WORLD 环境变量可覆盖成指定世界（harness 指沙箱/特定世界的测试钩子，见 P4）。不再写死 default；
	# 玩家 id 是设备端稳定 UUID（与下方 backend.player_id 同源）。
	var world: Dictionary = await api.get_bootstrap_world(PlayerProfile.ensure_player_id())
	_boot_stage = 1 # 网络已定音（成功或离线），loading 进度推进到中段
	if world.is_empty():
		return {}
	ItemCatalog.set_defs(world.get("items", [])) # 实体定义先就位（矩阵 palette 的解引用依据，纯数据）
	_prewarm_sticker_assets(world.get("items", [])) # 造贴纸:预热网络贴图（进世界即预热已摆的）
	var chars: Array = _filter_boot_characters(world.get("characters", []))
	# 先并发预取所有角色素材（anim 优先，跳静态大图）：冷启动从「逐个立绘串行下载」的长尾
	# 降到「最慢一个并发」，杜绝首次进世界接近 25s 揭幕硬超时、村民后补的观感。素材只落缓存。
	_boot_status = "唤醒村民 0/%d" % chars.size()
	var prefetched := await _prefetch_characters(chars)
	return { "world": world, "chars": chars, "prefetched": prefetched }

## 应用半段（转正点执行）：把 fetch 好的服务端世界落地——重铺地形、清离线占位、降生村民、搬玩家、接 WS。
## **场景变更全在这里**。fetched 为空 = 离线，保留占位世界。
func _bootstrap_apply(fetched: Dictionary) -> void:
	if fetched.is_empty():
		_boot_status = "离线模式"
		_finish_bootstrap()
		return
	var world: Dictionary = fetched.get("world", {})
	online = true
	world_id = String(world.get("id", "w_" + PlayerProfile.ensure_player_id())) # 缺省=自己的世界，不再回落 default
	await _load_server_terrain(world.get("scenes", []))
	backend.url = (api.base as String).replace("http", "ws") + "/ws"
	backend.player_id = PlayerProfile.ensure_player_id() # 设备端稳定 UUID，_send 统一注入
	backend.connect_to_server()
	for n in npcs:
		OccupancyMap.char_unregister(String(n.get("id", "")))
		(n["node"] as Node).queue_free() # 清掉离线占位
	npcs.clear()
	var chars: Array = fetched.get("chars", [])
	var prefetched: Dictionary = fetched.get("prefetched", {})
	# 素材已就位，顺序降生（命中内存缓存瞬时）；逐个推进 _boot_sub，loading 仙子据此持续前行。
	var total := chars.size()
	for i in range(total):
		_boot_status = "唤醒村民 %d/%d" % [i + 1, total]
		await _spawn_server_character(chars[i] as Dictionary, Vector2.INF, prefetched)
		_boot_sub = float(i + 1) / float(total) if total > 0 else 1.0
	_boot_status = "布置世界…"
	# 摆着的造物在场景矩阵物品层里（随地形一并就位），背包由 world_state 下发
	# 玩家搬到点点旁边降生，相机跟着玩家过去
	var fairy := _find_fairy()
	if not fairy.is_empty():
		focus_logical = fairy["logical"]
		if not player.is_empty():
			var spot := _find_free_spot(WorldGrid.wrap_pos(fairy["logical"] + Vector2(5.0, 3.0)), PLAYER_SPAN)
			player["logical"] = spot
			OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)
	_finish_bootstrap()

## intro 编排器（intro 模式下驱动 fetch/apply 与建造演出；现状路径为 null）。
var _intro: IntroDirector = null
var _intro_active := false

## 当前是否处于「建造小世界」intro 前置阶段（loading/其它模块可据此调整揭幕节奏）。
func intro_active() -> bool:
	return _intro_active

## benchmark 全程（Benchmark _ready/finish 开关）：锁玩家移动输入（相机/主角不动，防小朋友测试时
## 拖动世界干扰负载）+ 仙子注魔定格（含闭嘴，语音让位注魔旁白）。村民【不】冻结——见 _step_executors：
## 采样期村民照常 wander，A* 寻路 + 走动 CPU 计入 p95，才测得准（设计 docs/benchmark-story-ramp-design.md）。
func set_bench_freeze(on: bool) -> void:
	_bench_freeze = on

## benchmark 压测负载：环绕焦点生一个会 wander 的村民（压渲染 + 寻路 CPU）。与 _setup_npcs 同款
## （真村民图集 + 注册占用 + ambient wander），只是 id 前缀 bench_ 便于成批退场。idx/total 决定它在
## 环上的角位与动画相位，分批生（P2 分幕）也位置稳定、互不遮挡。
func bench_spawn_one(idx: int, total: int) -> void:
	var seed: Array = VillagerAssets.SEED
	var ang := TAU * float(idx) / float(maxi(total, 1))
	var radius := 4.0 + 2.0 * float(idx % 3)  # 三圈同心，拉开深度，别互相完全遮挡
	var lg := WorldGrid.wrap_pos(focus_logical + Vector2(cos(ang), sin(ang)) * radius)
	var v: Dictionary = seed[idx % seed.size()]
	var npc := PaperCharacter.new()
	add_child(npc)
	var did := "bench_%d" % idx
	npc.setup(critter_tex, Color.WHITE, did)  # 先 critter 跑通 setup（归一尺寸+暗斑），再切图集动画
	var atlas := load(String(v["atlas"])) as Texture2D
	if atlas != null:
		var phase := float(idx) / float(maxi(total, 1)) * 3.9  # 错开相位，避免整齐同帧的机械感
		npc.play_anim(atlas, v["meta"], VillagerAssets.WORLD_HEIGHT, phase)
	npcs.append({ "node": npc, "logical": lg, "id": did, "bench_home": lg })
	OccupancyMap.char_register(did, lg, 2)
	# 确定性巡逻（非随机 wander）：保住 A* 寻路 CPU 计入 p95，但每次跑的负载序列可复现——
	# 随机 wander 的目标点每 trial 都不同、路径成本天差地别，是 ±60ms trial 噪声的大头（见 PoC 实测）。
	_start_bench_patrol(npcs[npcs.size() - 1], idx)

## 一次生齐 count 个压测负载（独立 benchmark 场景走这条；intro 分幕用 bench_spawn_one 逐个生）。
func bench_spawn_load(count: int) -> void:
	for i in count:
		bench_spawn_one(i, count)

## benchmark 确定性负载：为一个 bench 村民算好一圈固定巡逻路点（绕 home 的几个方位），存进字典。
## 路点在生成期一次算定——那时占用是确定的，所以路点集也确定；跳过水面/被占的候选，保证可达、
## 不烧一次注定失败的全预算 A*。角度按 idx 错开，各村民走各自固定的一圈，整体负载稳定可复现。
func _start_bench_patrol(npc_dict: Dictionary, idx: int) -> void:
	var home: Vector2 = npc_dict["bench_home"]
	var did := String(npc_dict.get("id", ""))
	var base := TAU * float(idx) / float(maxi(Benchmark.EXTRA_CHARS, 1))  # 每村民一套错开但固定的方位
	var wps: Array[Vector2] = []
	for k in 4:
		var a := base + TAU * float(k) / 4.0
		var cand := WorldGrid.wrap_pos(home + Vector2(cos(a), sin(a)) * 6.0)  # 半径 6m，与旧 wander 同量级
		if TerrainMap.tile_type(WorldGrid.to_tile(cand)) != TerrainMap.T_WATER \
				and Pathfinder.cell_free(OccupancyMap.to_cell(cand), 2, did):
			wps.append(cand)
	npc_dict["bench_patrol"] = wps
	_start_bench_patrol_exec(npc_dict)

## 用村民字典里存好的巡逻路点起一个执行器：循环「等一拍 → 走到下一路点」。等待时长固定（非随机），
## 保证每 trial 的动态负载序列一致。无可达路点时原地等（极少见，仍确定性）。
func _start_bench_patrol_exec(npc_dict: Dictionary) -> void:
	if npc_dict.get("replicated", false):
		return
	var wps: Array = npc_dict.get("bench_patrol", [])
	var cmds: Array = []
	if wps.is_empty():
		cmds = [{ "type": "wait", "params": { "duration": 1.5 } }]
	else:
		for wp: Vector2 in wps:
			cmds.append({ "type": "wait", "params": { "duration": 1.2 } })
			cmds.append({ "type": "move_to", "params": { "target": [wp.x, wp.y] } })
	var ex := BehaviorExecutor.new()
	ex.setup(npc_dict, { "commands": cmds, "loop": true })
	ex.ambient = true
	_executors.append(ex)

## benchmark 每 trial 前调用：把所有 bench 村民复位到各自 home + 重启巡逻，让每个 trial 的采样窗
## 都从【同一世界状态】开始跑【同一段】动态负载——这是「确定化地动」的核心，杀掉「上一 trial 走到哪
## 了」这个随画质档变化的隐藏变量（否则重档→低帧→村民走得慢→位置不同→负载不同，测量被自己污染）。
func bench_reset_load() -> void:
	for n in npcs:
		if not String(n.get("id", "")).begins_with("bench_"):
			continue
		for j in range(_executors.size() - 1, -1, -1):  # 取消旧执行器（按引用同一性），避免撞上复位
			if (_executors[j] as BehaviorExecutor).drives(n):
				(_executors[j] as BehaviorExecutor).cancel()
				_executors.remove_at(j)
		var home: Vector2 = n.get("bench_home", n.get("logical"))
		n["logical"] = home
		n["paper_prev"] = home  # 防瞬移被 _update_paper_motion 当成一帧巨速→误触走路/翻面
		OccupancyMap.char_register(String(n["id"]), home, 2)  # 占用重置回 home（char_register 先注销再注册）
		_start_bench_patrol_exec(n)

## intro 建造·起手极简：藏起散布植被 + 地面斜阳影，让「大地长出来、小树冒出来」有从无到有的过程。
## chunk_manager 会记住 _props_shown/_ground_shadows，后续新铺的区块也继承隐藏。
func intro_hide_scenery() -> void:
	if chunk_manager != null:
		chunk_manager.set_props_shown(false)
		chunk_manager.set_ground_shadows(false)

## intro 建造·揭示：树木灌木 + 地面影冒出来（回到当前画质档该有的样子）。benchmark 之后各旋钮会按定档
## 结果再 _apply_graphics_key 覆盖，这里只负责让「建造」这一刻可见。
func intro_show_scenery() -> void:
	if chunk_manager != null:
		chunk_manager.set_props_shown(int(_gfx_levels.get("prop_anim", 1)) > 0)
		chunk_manager.set_ground_shadows(int(_gfx_levels.get("ground_shadows", 1)) > 0)

## ── intro 教学视觉指引（Bug②）──────────────────────────────────────────
## 幼儿只听旁白容易发懵、盯着空地不知道要干嘛——每个教学步配一个看得见的目标：走路/靠近亮地面脉动光环，
## 说话亮底部话筒+声波 HUD。纯客户端视觉、无声、不改 fsm，由 IntroDirector 各教学步开关。
func intro_hint_at(logical: Vector2, color: Color) -> void:
	if _intro_hint == null:
		_intro_hint = MeshInstance3D.new()
		var m := CylinderMesh.new()  # 扁圆片贴地（复用 _tap_marker 同款，_place_on_bent_ground 已验稳）
		m.top_radius = 0.85
		m.bottom_radius = 0.85
		m.height = 0.06
		_intro_hint.mesh = m
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_intro_hint.material_override = mat
		add_child(_intro_hint)
	(_intro_hint.material_override as StandardMaterial3D).albedo_color = color
	_intro_hint_logical = logical
	_intro_hint_active = true
	_intro_hint_t = 0.0
	_intro_hint.visible = true

## 说话步：亮话筒+声波 HUD（地面环收掉，二者不同框）。
func intro_hint_mic() -> void:
	_hide_intro_ground_hint()
	_intro_mic_hint = true

## 收掉全部 intro 教学指引（步间切换 / skip / 教学结束都调）。
func intro_hint_clear() -> void:
	_hide_intro_ground_hint()
	_intro_mic_hint = false

func _hide_intro_ground_hint() -> void:
	_intro_hint_active = false
	if _intro_hint != null:
		_intro_hint.visible = false

## 每帧脉动 + 随世界滚动贴地（环面最短位移，与 _tap_marker 同套）。
func _update_intro_hint(delta: float) -> void:
	if not _intro_hint_active or _intro_hint == null:
		return
	_intro_hint_t += delta
	var d := WorldGrid.shortest_delta(focus_logical, _intro_hint_logical)
	var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(_intro_hint_logical))) * TerrainMap.STEP_HEIGHT
	_place_on_bent_ground(_intro_hint, Vector3(d.x, ty + 0.05, d.y))
	var pulse := 0.5 + 0.5 * sin(_intro_hint_t * 3.5)  # 呼吸 0..1
	_intro_hint.scale = Vector3(0.8 + pulse * 0.4, 1.0, 0.8 + pulse * 0.4)
	(_intro_hint.material_override as StandardMaterial3D).albedo_color.a = 0.4 + pulse * 0.45

## 压测负载退场：取消驱动它的 ambient 执行器（按引用同一性，别让 step 撞上已释放节点）、注销占用、
## 释放节点、出 npcs 数组。bench_ 前缀成批识别。
func bench_despawn_load() -> void:
	for i in range(npcs.size() - 1, -1, -1):
		var n: Dictionary = npcs[i]
		if not String(n.get("id", "")).begins_with("bench_"):
			continue
		for j in range(_executors.size() - 1, -1, -1):
			if (_executors[j] as BehaviorExecutor).drives(n):
				(_executors[j] as BehaviorExecutor).cancel()
				_executors.remove_at(j)
		OccupancyMap.char_unregister(String(n.get("id", "")))
		var node: Variant = n.get("node")
		if node is Node and is_instance_valid(node):
			(node as Node).queue_free()
		npcs.remove_at(i)

# ── intro 教学「开口说话」步（P4）───────────────────────────────────────────
# 只用本地 VAD 检测「孩子开口」这个手势——不建 ASR 会话、不上传任何 PCM、不理解内容
# （见设计 D4）。与近身对话的 VoiceCapture(_vc) 完全独立：intro 期 selected 为 null、_vc 未
# open()，_vc.step 早返回，不会双开麦。用自己的 _intro_mic（时段互斥，不与 _vc 抢麦）。
var _intro_listening := false
var _intro_heard := false
var _intro_listen_vad: VoiceVad = null
var _intro_listen_grace := 0.0
var _intro_mic: MicRecorder = null  ## 教学手势检测专用采集（独立于 _vc 内部麦）

## 教学「开口说话」步是否被 ASR 门禁挡下（端侧应有却未就绪 → 跳过本步，绝不上传 PCM）。
## 桌面/headless（非导出）恒 false，可正常走本地 VAD 检测开口。
func intro_asr_blocked() -> bool:
	return _vc.must_wait_for_ready()

## 开始教学监听。调用前须先 intro_asr_blocked() 判门禁。检测到开口即置 _intro_heard。
func intro_listen_begin() -> void:
	if _intro_listening:
		return
	# iOS 麦权限被拒 → 盖引导层 + 暂停树，**不**置监听标志：解除后重新调用即自愈。
	if MicPermission.enforce(get_tree()):
		return
	_intro_heard = false
	_intro_listening = true
	_intro_listen_vad = VoiceVad.new()
	_intro_listen_grace = VoiceCapture.UNMUTE_GRACE # 刚播完的旁白余响不算开口
	if _intro_mic == null:
		_intro_mic = MicRecorder.new()
		_intro_mic.name = "IntroMic"
		add_child(_intro_mic)
	_intro_mic.start()

func intro_listen_end() -> void:
	if not _intro_listening:
		return
	_intro_listening = false
	_intro_listen_vad = null
	if _intro_mic != null:
		_intro_mic.stop()

func intro_heard_speech() -> bool:
	return _intro_heard

## 每帧推进教学监听：排空麦 PCM 喂本地 VAD，检测到「开口(start)」即算完成。
func _step_intro_listen(delta: float) -> void:
	if not _intro_listening or _intro_listen_vad == null:
		return
	var pcm := _intro_mic.drain_pcm16k() if _intro_mic != null else PackedByteArray()
	if _intro_listen_grace > 0.0:
		_intro_listen_grace -= delta
		return
	intro_feed_pcm(pcm)

## VAD 喂入（headless 测试注入合成 PCM 走同一判定，见 test_intro_tutorial）。
func intro_feed_pcm(pcm: PackedByteArray) -> void:
	if _intro_listen_vad == null:
		return
	for ev in _intro_listen_vad.feed(pcm):
		if String(ev["type"]) == "start":
			_intro_heard = true

## 引导收尾：里程碑置终、清 _bootstrapping（world_ready 守望据此揭幕）。fetch/apply 两条出口共用。
func _finish_bootstrap() -> void:
	_boot_stage = 2 # 角色/props 就位、玩家已落到最终位——引导侧全部完成
	_boot_sub = 1.0
	_boot_status = "就绪"
	_bootstrapping = false

## 首屏就绪守望：等首屏 chunk 全 skin 完 && 引导结束，最短 READY_MIN_SEC、最长 READY_TIMEOUT_SEC，
## 然后发 world_ready。每帧让出（await process_frame）确保 _process→chunk_manager.update 推进铺设。
## 计时累加帧 delta（仿真时间）而非墙钟：headless 下帧比真机快得多，墙钟会让最短门永不满足。
var _bootstrapping := false
## 玩家位置待从 world_state.playerPos 还原（引导窗口内有效）。world_ready 后置否，
## 断线重连收到的 world_state 不再搬人。
var _player_restore_pending := false
var _boot_stage := 0 ## 引导里程碑：0=网络进行中，1=get_world 已定音，2=角色/props/玩家全就位（见 _bootstrap）
var _boot_sub := 0.0  ## stage 1 内的细粒度子进度 [0,1]：逐个村民就位时推进（消除长尾期仙子停顿）
var _boot_status := "" ## 当前引导阶段的人读文案；loading debug 浮层轮询 ready_status() 显示（release 不显示）
var _world_ready_sent := false

## 世界就绪进度 [0,1)：loading 过场用它驱动仙子横向飞行。两条并行推进——
## 首屏 chunk 铺设 与 在线引导里程碑——各占一半；封顶 0.95，真正的 1.0（落地揭幕）
## 由 world_ready 信号触达，保证「飞到头」= 真就绪，而非到点硬放行。
## boot 段细粒度：stage0=0；stage1 期间 0.4→1.0 随村民逐个就位（_boot_sub）平滑推进；stage2=1.0——
## 把最耗时的「逐村民下载立绘」长尾摊成连续进度，仙子据此持续前行而非卡在门前。
func ready_progress() -> float:
	var chunk_f := chunk_manager.skinned_fraction() if chunk_manager != null else 0.0
	var boot_f := 0.0
	if _boot_stage >= 2:
		boot_f = 1.0
	elif _boot_stage == 1:
		boot_f = 0.4 + 0.6 * clampf(_boot_sub, 0.0, 1.0)
	return clampf(0.08 + 0.46 * chunk_f + 0.46 * boot_f, 0.0, 0.95)

## 当前就绪阶段的人读文案（loading debug 浮层轮询显示；release 构建不显示，见 loading.gd）。
## 引导文案就绪前（极早期）回落到首屏铺设百分比，让 debug 浮层从头到尾都有信息。
func ready_status() -> String:
	if not _boot_status.is_empty():
		return _boot_status
	var chunk_f := chunk_manager.skinned_fraction() if chunk_manager != null else 0.0
	return "铺草地 %d%%" % int(chunk_f * 100.0)

func _watch_world_ready() -> void:
	var elapsed := 0.0
	while true:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if elapsed >= READY_TIMEOUT_SEC:
			break # 硬超时兜底：网络慢也放行
		if elapsed < READY_MIN_SEC:
			continue # 最短等待，避免抢在首屏铺设前发出
		if chunk_manager.all_skinned() and not _bootstrapping:
			break
	if not _world_ready_sent:
		_world_ready_sent = true
		_player_restore_pending = false # 揭幕后再收到 world_state（重连）不再搬人
		world_ready.emit()

func _find_fairy() -> Dictionary:
	for n in npcs:
		if n.get("is_fairy", false):
			return n
	return {}

## 角色主键：后端 id，无则名字兜底（与 _spawn_server_character 的登记键一致）。
func _char_id(c: Dictionary) -> String:
	var cid := String(c.get("id", ""))
	if cid.is_empty():
		cid = String(c.get("name", ""))
	return cid

## 从角色 appearance 取体型倍率（size→scale，服务端明显档 0.7/1.0/1.4）。
## 缺失/非法/存量角色一律 1.0（不跳变）；防御性 clamp 挡住坏数据。纯函数，供单测。
func _body_scale(appearance: Dictionary) -> float:
	return clampf(float(appearance.get("scale", 1.0)), BODY_SCALE_MIN, BODY_SCALE_MAX)

## 决定角色降生用哪个素材：idle 动画就绪则用动画图集（~200KB，跳过 ~1.2MB 静态立绘——老板要求
## 「有动画就不要立绘」），否则用静态立绘。anim_rec 为 fetch_sprite_anim 返回。纯函数，供单测。
## 返回 { "hash": 目标资产 hash, "is_anim": bool, "meta": Dictionary }。
func _pick_char_asset(anim_rec: Dictionary, sprite_hash: String) -> Dictionary:
	if String(anim_rec.get("status", "")) == "ready":
		var anim_hash := String(anim_rec.get("animAsset", ""))
		if not anim_hash.is_empty():
			return { "hash": anim_hash, "is_anim": true, "meta": anim_rec.get("meta", {}) }
	return { "hash": sprite_hash, "is_anim": false, "meta": {} }

## 并发预取所有角色的降生素材：先并发查 idle 动画状态，anim-ready 只拉动画图集（跳静态大图），
## 否则拉静态立绘。返回 cid -> { tex, is_anim, meta, sprite_hash }。冷启动从「N 个立绘串行下载」
## 降到「最慢一个并发」；命中磁盘/内存缓存则零下载。逐个 fire-and-forget，计数归零即全部就绪。
func _prefetch_characters(chars: Array) -> Dictionary:
	var results := {}
	if chars.is_empty():
		return results
	var pending := [chars.size()] # 数组包一层做可变计数（引用语义，供 _prefetch_one 递减）
	for c in chars:
		_prefetch_one(c as Dictionary, results, pending)
	while pending[0] > 0:
		await get_tree().process_frame
	return results

## 预取单个角色（fire-and-forget，跑到首个 await 即返回，后续在网络回调续跑）：查动画状态→按
## _pick_char_asset 选素材→拉纹理；动画图集拉取失败回落静态立绘。完成后 results[cid] 落位、计数减一。
func _prefetch_one(c: Dictionary, results: Dictionary, pending: Array) -> void:
	var cid := _char_id(c)
	var appearance: Dictionary = c.get("appearance", {})
	var sprite := String(appearance.get("spriteAsset", ""))
	var entry := { "tex": null, "is_anim": false, "meta": {}, "sprite_hash": sprite }
	if not sprite.is_empty():
		var rec := await api.fetch_sprite_anim(sprite)
		var pick := _pick_char_asset(rec, sprite)
		# 动画图集走显存块压缩（三段图集是显存大头）；回落的静态立绘不压（放大给孩子看，色块瑕疵明显）
		var tex := await api.fetch_texture(String(pick["hash"]), bool(pick["is_anim"]))
		if tex != null:
			entry["tex"] = tex
			entry["is_anim"] = bool(pick["is_anim"])
			entry["meta"] = pick["meta"]
		elif bool(pick["is_anim"]): # 动画图集拉取失败 → 回落静态立绘
			var st := await api.fetch_texture(sprite)
			if st != null:
				entry["tex"] = st
	results[cid] = entry
	pending[0] -= 1

## 从后端 Character 字典生成一个 PaperCharacter。at_logical 非 INF 时覆盖其逻辑坐标。
## 从服务端 position 还原降生坐标。服务端只存 tile 精度（positions_report 上报），
## 读回时取该格中心，再就近找空位（水面/物件/已降生角色都会挡）。
## 无坐标 / 越界（存量角色仍是旧世界的 tile 500）→ 回退黄金角散环，与改动前行为一致。
func _restore_logical(c: Dictionary, is_fairy: bool) -> Vector2:
	var center := Vector2(WorldGrid.WORLD_SPAN, WorldGrid.WORLD_SPAN) * 0.5
	var pos: Dictionary = c.get("position", {})
	if not pos.is_empty():
		var tile := Vector2i(int(pos.get("tileX", -1)), int(pos.get("tileY", -1)))
		if WorldGrid.is_valid_tile(tile):
			# 仙子悬浮不占格、不挡路，落点无需避让
			var at := WorldGrid.from_tile_center(tile)
			return at if is_fairy else _find_free_spot(at, 2)
	if is_fairy:
		return center
	# 村民按黄金角散开成环，避免初始堆叠
	var k := _villager_count
	_villager_count += 1
	var ang := float(k) * 2.399963
	return WorldGrid.wrap_pos(center + Vector2(cos(ang), sin(ang)) * (10.0 + float(k) * 3.0))

## prefetched 非空时从中取纹理/动画（_prefetch_characters 已并发拉好，命中内存缓存瞬时）；
## 缺省 {} 时（如新造角色单发）走自拉旧路径。
func _spawn_server_character(c: Dictionary, at_logical: Vector2, prefetched := {}) -> void:
	var npc := PaperCharacter.new()
	add_child(npc)
	var appearance: Dictionary = c.get("appearance", {})
	var asset := String(appearance.get("spriteAsset", ""))
	# 体型：服务端 size→scale（明显档 小0.7/中1.0/大1.4，见 docs/character-size-design.md）。
	# 缺失/存量角色恒 1.0=不变。只作用于村民/角色，仙子与占位另有固定高度。
	var body_scale := _body_scale(appearance)
	var body_h := VILLAGER_BASE_HEIGHT * body_scale  # 村民世界高度基准 × 体型
	var cid := _char_id(c)
	var tex: Texture2D = critter_tex
	var color := Color.WHITE
	var real := false
	var use_anim := false          # 该角色是否直接以 idle 动画图集降生（跳过静态立绘下载）
	var anim_meta: Dictionary = {}
	if prefetched.has(cid):
		var e: Dictionary = prefetched[cid] # 预取已并发拉好（anim 优先）；命中内存缓存瞬时
		if e.get("tex") != null:
			tex = e["tex"]
			real = true
			use_anim = bool(e.get("is_anim", false))
			anim_meta = e.get("meta", {})
	elif not asset.is_empty():
		var t := await api.fetch_texture(asset) # 无预取（如新造角色单发）：自拉静态立绘
		if t != null:
			tex = t
			real = true
	if not real:
		color = Color(0.85, 0.8, 1.0) if c.get("isFairy", false) else Color(0.92, 0.92, 0.92)
	npc.setup(tex, color, String(c.get("name", "")))
	if real: # 立绘锚点（贴纸附着位，character-anchors）：只有真立绘的坐标系有意义
		npc.set_anchors(appearance.get("anchors", {}))
		_apply_attachments(npc, c) # 身上已贴的贴纸随角色下发，降生即穿戴
	var is_fairy := bool(c.get("isFairy", false))
	if is_fairy:
		BlobShadow.detach(npc) # 悬浮飞行不落地，脚下暗斑穿帮
		npc.wants_ground_shadow = false  # 切「角色实时阴影」刷新时别给悬浮角色挂脚下 blob
		if use_anim: # 已是动画图集：直接以动画降生（play_anim 覆盖 setup 的静态尺寸，同帧无闪）
			npc.play_anim(tex, anim_meta, FAIRY_HEIGHT, 0.0)
		else:
			# 小仙子随从：头部大小（时之笛式），无论真图/占位都按 FAIRY_HEIGHT 归一
			npc.pixel_size = FAIRY_HEIGHT / float(tex.get_height())
			if real: # 静态就位后后台轮询 idle 动画，就绪则切动画
				_poll_idle_anim(npc, asset, FAIRY_HEIGHT, 0.0)
	elif real:
		# 相位按 id 错开，避免整村同帧起跳的机械感（31帧/8fps 循环约 3.9s）。
		var anim_phase := float(cid.hash() % 256) / 256.0 * 3.9
		if use_anim: # 已是动画图集：直接以动画降生
			npc.play_anim(tex, anim_meta, body_h, anim_phase)
		else:
			# 生成图分辨率高，按高度归一化到 body_h（=6.0×体型），脚底对齐原点
			var h := float(tex.get_height())
			npc.pixel_size = body_h / h
			npc.offset = Vector2(0.0, h / 2.0)
			BlobShadow.attach(npc, clampf(float(tex.get_width()) * npc.pixel_size * 0.38, 0.4, 1.4))
			# 村民真图就绪后，后台轮询 idle 动画，就绪则静态切动画（与玩家/仙子同一条链路）。
			_poll_idle_anim(npc, asset, body_h, anim_phase)
	var logical := at_logical
	if logical == Vector2.INF:
		logical = _restore_logical(c, is_fairy)
	var dict := { "node": npc, "logical": logical, "id": cid, "is_fairy": is_fairy, "scale": body_scale }
	# 主动社交：性格类型 + 该玩家视角的熟识度（服务端 projectCharacterFor 下发；见 npc_greeter.gd）。
	# familiarity 只在角色被下发时刷新（进/换场景重发）；同一场景内不随聊天即时变（刻意的一期取舍）。
	if not is_fairy:
		dict["social_type"] = String(c.get("socialType", ""))
		dict["familiarity"] = String(c.get("familiarity", ""))
	if is_fairy:
		dict["hover"] = FAIRY_HOVER # 悬浮随从：不登记占用（飞行不挡路），由 _update_fairy 驱动
	else:
		OccupancyMap.char_register(cid, logical, 2)
	npcs.append(dict)
	if not is_fairy:
		_start_ambient_wander(npcs[npcs.size() - 1])

# ── 异步施法占位符 ───────────────────────────────────────────────────────
# 造角色/造物要等服务端跑完 LLM 设计 + 生图（几秒到十几秒）。此前孩子被钉在近身对话里干等，
# 只看得到一行「施法中…」。现在一开工就退出对话、就地立起占位符：传送门=新伙伴要来了，
# 魔法熔炉=新物件要造出来了。孩子可以绕着它跑，成品从占位符所在的位置出现。
const PLACEHOLDER_PORTAL_ID := "__casting_portal"
const PLACEHOLDER_FORGE_ID := "__casting_forge"
const PLACEHOLDER_EASEL_ID := "__casting_easel" # 造贴纸占位符（魔法画板，sticker-ux）
var _placeholders := {} ## 占位符 id → 落位 tile（Vector2i）

## 立起占位符。anchor 缺省玩家身旁（施法态）；引导期锚仙子（见 _raise_creation_placeholder）。
## gen_progress 会来好几次（逐阶段），只认第一次；引导期已立起的这里直接返回，不重复立。
func _spawn_placeholder(id: String, spec: Dictionary, anchor := Vector2.INF, offset := Vector2(3.0, 2.0)) -> void:
	if _placeholders.has(id):
		return
	var base: Vector2 = anchor
	if base == Vector2.INF:
		base = player["logical"] if not player.is_empty() else focus_logical
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos(base + offset))
	var placed := chunk_manager.add_dynamic_prop(spec, want, 0.0, 0.0, id)
	if placed.x < 0:
		return # 放不下就不立：成品照旧在玩家身旁落位（下面的兜底分支）
	_placeholders[id] = placed

## 收起占位符，返回它占的 tile（没立成返回 (-1,-1)）——成品就从这里出来。
## 必须先收起再放成品：占位符占着格子，不腾出来成品会落位失败。
func _clear_placeholder(id: String) -> Vector2i:
	if not _placeholders.has(id):
		return Vector2i(-1, -1)
	var tile: Vector2i = _placeholders[id]
	_placeholders.erase(id)
	var picked := chunk_manager.pickup_dynamic_prop(id)
	if not picked.is_empty():
		var node: Node3D = picked.get("node")
		if is_instance_valid(node):
			node.queue_free()
	return tile

## 引导一开始（首个 creation_prompt）就在仙子身旁立起占位符：造角色=降生蛋，造物=魔法熔炉，造贴纸=魔法画板。
## 孩子的每个回答会被「扔」进它（见 _throw_answer_into_placeholder），一眼看懂答案有用。
## 幂等：每轮 prompt 都会调，已立起的直接返回。放不下就不立——后续路径都容忍占位符缺席。
func _raise_creation_placeholder() -> void:
	var id := _creation_placeholder_id()
	var spec: Dictionary = _creation_placeholder_spec()
	# 锚在仙子身旁（不是玩家）：创造视图是仙子特写，蛋/炉要与她同框，答案才「看得见飞进去」
	var anchor := Vector2.INF
	if _locked != null and is_instance_valid(_locked):
		anchor = _find_npc_dict(_locked).get("logical", Vector2.INF)
	_spawn_placeholder(id, spec, anchor, CREATION_PLACEHOLDER_OFFSET)
	# 引导期放大：远景里原尺寸的蛋/炉只有几十像素，孩子看不清答案飞进了哪儿
	var node := chunk_manager.dynamic_prop_node(id)
	if node != null:
		node.scale = Vector3.ONE * CREATION_PLACEHOLDER_SCALE

## 收起引导期立的占位符（取消/走开/花不够）。造没开工，蛋/炉不能留在地上。
## 两个 id 都收：引导期只会立其中一个，另一个是 no-op。
func _clear_creation_placeholder() -> void:
	_clear_placeholder(PLACEHOLDER_PORTAL_ID)
	_clear_placeholder(PLACEHOLDER_FORGE_ID)
	_clear_placeholder(PLACEHOLDER_EASEL_ID)

## 点点造物三段的预制台词（见 docs/fairy-persona-design.md 锚点①：爱显摆手艺）：
##   create_start 开工碎碎念、create_done 做完求夸、create_fail 画歪了笑自己手笨。
## 台词在 assets/voice/fairy/lines.json，缺 fairy_voice / 缺对应触发词都静默跳过（try_play 内部兜底）。
func _fairy_say(trigger: String) -> void:
	if fairy_voice != null:
		fairy_voice.try_play(trigger)

## 手机「点点睡觉」app 调用：点点打个哈欠说句困话，然后进入安静态——ambient/POI 全静音，
## 孩子一互动就自然醒（见 _fairy_ambient 的 player_engaged 分支）。能被叫停的陪伴才不骚扰。
func fairy_nap() -> void:
	_fairy_napping = true
	_fairy_say("quiet")

## 造角色开工：引导会话已结束，服务端开造。退出对话，立起传送门。
func _on_gen_progress(_stage: String) -> void:
	_in_creation = false # 先清，免得 _exit_interaction 误发 creation_cancel
	_hide_creation_cards()
	if selected != null:
		_exit_interaction() # 不把孩子钉在对话里干等
	thinking_label.visible = false
	_spawn_placeholder(PLACEHOLDER_PORTAL_ID, PlaceholderSpecs.PORTAL)
	banner.text = "传送门打开啦，新朋友就要来了！"
	banner.visible = true
	_fairy_say("create_start") # 点点边画边碎碎念，把这几秒空窗变成「她在为我干活」

func _on_gen_complete(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet")) # 造角色扣了 1 朵花，同步最新钱包
	var character: Dictionary = data.get("character", {})
	_in_creation = false
	_hide_creation_cards()
	thinking_label.visible = false
	# 新伙伴从传送门里走出来；传送门没立成（放不下/离线）就退回点点旁降生
	var tile := _clear_placeholder(PLACEHOLDER_PORTAL_ID)
	var spawn_at: Vector2
	if tile.x >= 0:
		spawn_at = Vector2(tile) * float(WorldGrid.TILE_SIZE)
	else:
		var fairy := _find_fairy()
		var anchor: Vector2 = fairy["logical"] if not fairy.is_empty() else focus_logical
		spawn_at = anchor + Vector2(6.0, 4.0)
	await _spawn_server_character(character, spawn_at)
	game_audio.play_sfx("fanfare")
	banner.text = "%s 来啦！" % String(character.get("name", "新朋友"))
	banner.visible = true
	_fairy_say("create_done") # 求夸：「好看吗好看吗？点点画的哦！」

## 造物开工（服务端已扣花）：退出对话，立起魔法熔炉。
func _on_prop_pending(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet")) # 花在开造那一刻就扣掉
	_in_creation = false
	_hide_creation_cards()
	if selected != null:
		_exit_interaction()
	thinking_label.visible = false
	# 积木拼装落成：拼装台已是成品预览，不立熔炉——收起拼装台，成品随 item_created 落地。
	if _creation_goal == "build":
		_clear_build_preview()
		banner.text = "拼好啦！"
		banner.visible = true
		return
	_spawn_placeholder(PLACEHOLDER_FORGE_ID, PlaceholderSpecs.FORGE)
	banner.text = "魔法熔炉烧起来啦！"
	banner.visible = true
	_fairy_say("create_start")

## 造贴纸开工（已扣花）：退出对话、就地立起魔法画板占位符，孩子看得见「正在做贴纸」。
func _on_sticker_pending(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet")) # 花在开造那一刻就扣掉
	_in_creation = false
	_hide_creation_cards()
	if selected != null:
		_exit_interaction()
	thinking_label.visible = false
	_spawn_placeholder(PLACEHOLDER_EASEL_ID, PlaceholderSpecs.EASEL)
	banner.text = "魔法画板刷刷刷！"
	banner.visible = true
	_fairy_say("create_start")

## 语音造物完成（万物皆物品）：实体定义入目录 + 背包一份到手；在熔炉/玩家旁本地找位
## 发 item_place，渲染统一等 terrain_patch 广播回来落地。找不到位/离线就留在背包
## （物品页可再摆），成品绝不凭空消失。
## 造贴纸(renderRef 'sticker:@<hash>')的网络贴图预热：ItemCatalog 收到新实体定义后，把资产哈希
## 拉成 Texture2D 灌进 ChunkManager 缓存，边缘竖片渲染据此上真图（打包贴纸不需此步）。
## 异步 fire-and-forget：拉完若确有新图，触发一次 chunk rebuild——此前竖片是透明占位，重建换真图。
func _prewarm_sticker_assets(defs: Array) -> void:
	if api == null:
		return
	var fetched := false
	for d in defs:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var rref := String((d as Dictionary).get("renderRef", ""))
		if not rref.begins_with("sticker:@"):
			continue
		var hash := rref.substr("sticker:@".length())
		if hash.is_empty() or ChunkManager.has_sticker_asset(hash):
			continue
		var tex: Texture2D = await api.fetch_texture(hash)
		if tex != null:
			ChunkManager.cache_sticker_asset(hash, tex)
			fetched = true
	if fetched and chunk_manager != null:
		chunk_manager.rebuild() # 占位→真图，重建受影响的边缘竖片

func _on_item_created(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet")) # 造物扣了 1 朵花，同步最新钱包
	_apply_bag(data.get("bag"))
	var item: Dictionary = data.get("item", {})
	var item_id := String(item.get("id", ""))
	ItemCatalog.set_defs([item]) # 新实体先入目录（patch 回来才认得 renderRef/spec）
	_prewarm_sticker_assets([item]) # 造贴纸:预热网络贴图(打包贴纸/造物无 @ 前缀,跳过)
	if phone_ui != null:
		phone_ui.prewarm_item(item_id, item) # thumb-polish P2:造物落地即端侧预渲缩略图入缓存,翻物品页不见礼盒一闪
	thinking_label.visible = false
	# 点点这一拍统一走 _offer_naming：能起名就问名字（name_ask），起不了名才退回求夸（create_done）——
	# 二选一，别在这里先 create_done 又叠 name_ask（GLOBAL_GAP 会把后一句吞掉）。见 §2.2。
	# 先收占位符腾出格子，成品就落在那儿；占位符没立成就退回玩家身旁。
	# 造物立熔炉、造贴纸立画板——哪个在就收哪个（另一个 no-op 返回负值）。
	var tile := _clear_placeholder(PLACEHOLDER_FORGE_ID)
	if tile.x < 0:
		tile = _clear_placeholder(PLACEHOLDER_EASEL_ID)
	# 造贴纸(mount edge)：不自动落地——贴纸靠孩子用放置模式贴到 tile 边缘/角色身上。
	# 只收进背包 + 放个大大的 wow 庆祝，再引导「去手机里贴上」。
	var is_sticker := String(item.get("renderRef", "")).begins_with("sticker:@") \
		or String(item.get("mount", "")) == "edge"
	if is_sticker:
		_celebrate_sticker()
		banner.text = "新贴纸做好啦！去手机里贴上吧"
		banner.visible = true
		_offer_naming(item_id)
		return
	var want := tile
	if want.x < 0:
		var anchor: Vector2 = player["logical"] if not player.is_empty() else focus_logical
		want = WorldGrid.to_tile(WorldGrid.wrap_pos(anchor + Vector2(3.0, 2.0)))
	var spot := _find_item_spot(want)
	if spot.x < 0 or not online:
		banner.text = "变出来啦！收在册子里咯"
		banner.visible = true
		_pulse_album_button()
		_offer_naming(item_id)
		return
	_bag_action = "" # 摆放回包静默：这里已有「变出来啦」横幅
	backend.send_item_place(world_id, item_id, spot, randf() * 360.0)
	game_audio.play_sfx("fanfare")
	banner.text = "变出来啦！"
	banner.visible = true
	_offer_naming(item_id)

## 摆放/拾起的 bag_update 回包：背包同步 + 按动作出反馈（服务端已确认动账）。
func _on_bag_update(data: Dictionary) -> void:
	_apply_bag(data.get("bag"))
	match _bag_action:
		"pickup":
			banner.text = "收进册子啦！"
			banner.visible = true
			_pulse_album_button()
			if game_audio != null:
				game_audio.play_sfx("fanfare")
		"place":
			if game_audio != null:
				game_audio.play_sfx("pop")
			banner.text = "摆出来啦！"
			banner.visible = true
	_bag_action = ""

## 贴纸小铺购入回包：背包+钱包一起落地（服务端已扣花动账），出反馈。
func _on_sticker_bought(data: Dictionary) -> void:
	_apply_bag(data.get("bag"))
	_apply_wallet(data.get("wallet"))
	banner.text = "贴纸买到啦！"
	banner.visible = true
	if game_audio != null:
		game_audio.play_sfx("fanfare")

## 小红花不足未买成：同步钱包 + 温和提示（与 gen/prop_denied 同心智，不出错误音）。
func _on_sticker_denied(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet"))
	banner.text = "小红花不够啦，完成小任务再来吧"
	banner.visible = true

## 应用服务端下发的背包（world_state/item_created/bag_update 复用）：更新状态 + 刷物品页。
func _apply_bag(b: Variant) -> void:
	if typeof(b) == TYPE_DICTIONARY:
		bag = b
	if phone_ui != null:
		phone_ui.refresh_items()
	if _sticker_view != null and _sticker_view.visible:
		_refresh_sticker_view() # 贴上/买入后格子数变了，贴纸盘跟着刷

func _on_prop_failed(_reason: String) -> void:
	thinking_label.visible = false
	_clear_placeholder(PLACEHOLDER_FORGE_ID) # 造砸了：熔炉收起来，别让它烧到天荒地老
	banner.text = "没变出来，再说一次试试"
	banner.visible = true
	_fairy_say("create_fail") # 翻车归因自己：「哎呀，点点今天手笨笨的……」——把技术负债改写成笑点

## 造贴纸失败（审核/异常，服务端已退花）：收起画板 + oops 提示。
func _on_sticker_failed(_reason: String) -> void:
	thinking_label.visible = false
	_clear_placeholder(PLACEHOLDER_EASEL_ID) # 做砸了：画板收起来
	game_audio.play_sfx("oops")
	banner.text = "没做出来，再说一次试试"
	banner.visible = true
	_fairy_say("create_fail")

## 小红花不足被拦（造物/造角色）：同步钱包 + 横幅引导 + 播服务端带来的仙子引导语。
func _on_reward_denied(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet"))
	_in_creation = false
	_hide_creation_cards()
	_clear_creation_placeholder() # 没花可扣、造不成：引导期立的蛋/炉收起来，别让孩子空等
	thinking_label.visible = false
	banner.text = String(data.get("message", "小红花用完啦，去帮小伙伴攒盖章换小红花吧！"))
	banner.visible = true
	var asset := String(data.get("ttsAsset", ""))
	if not asset.is_empty() and not _tts_player.playing:
		_play_tts(asset)

## 会动的物件给一点游走半径，安静物品钉在原地。
func _prop_wander(spec: Dictionary) -> float:
	var loco: Dictionary = spec.get("locomotion", {})
	return 1.2 if String(loco.get("type", "none")) != "none" else 0.0

# ── 物品拾起/摆放（万物皆物品）：长按拾进背包、物品页点选摆出，均走服务端 tile 编辑 ──────
# 实例身份已消解为（tile + 实体引用）：拾起 = 清 tile 引用 + 背包加一份；
# 摆放 = 背包扣一份 + tile 挂引用。渲染统一等 terrain_patch 广播（发起者也靠广播落地）。

## 按下时记录指下的可拾物品 tile（长按候选）。按在 NPC/玩家上的交互优先。
## tile 上没有可拾物品时退而查边缘贴纸：取指下地面点最近的挂着贴纸的边。
func _begin_prop_press(screen_pos: Vector2) -> void:
	_prop_press_tile = NO_PRESS_TILE
	_prop_press_edge = -1
	_prop_press_t = 0.0
	if _pick_npc(screen_pos) != null or _pick_player(screen_pos) \
			or not _pick_remote_actor(screen_pos).is_empty():
		return
	var ground := _pick_ground(screen_pos)
	if ground == Vector2.INF:
		return
	var tile := WorldGrid.to_tile(ground)
	if _is_pickable_item(tile):
		_prop_press_tile = tile
		return
	var side := _pick_sticker_edge(tile, ground)
	if side >= 0:
		_prop_press_tile = tile
		_prop_press_edge = side

## 指下地面点最近的挂着贴纸的边（按点到四条边中点的距离排序）；无贴纸返回 -1。
func _pick_sticker_edge(tile: Vector2i, ground: Vector2) -> int:
	var center := TerrainMap.tile_center(tile)
	var best := -1
	var best_d := INF
	for side in range(4):
		if TerrainMap.edge_item_id(tile, side).is_empty():
			continue
		var mid := center + ChunkManager.EDGE_OFFSETS[side] * WorldGrid.TILE_SIZE
		var d := ground.distance_squared_to(mid)
		if d < best_d:
			best_d = d
			best = side
	return best

## tile 上的物品能不能拾：一期只有语音造物可拾起（实体 worldId 非空）——
## 内置树/石/建筑不可拾（服务端同样拒绝，这里提前拦省一次 error 往返）。
func _is_pickable_item(tile: Vector2i) -> bool:
	var id := TerrainMap.tile_item_id(tile)
	if id.is_empty():
		return false
	var def := ItemCatalog.get_def(id)
	return def.get("worldId") != null

## 长按累计：手指滑走（变成拖屏/跟随）即取消；到阈值发拾起请求（收进背包）。
func _step_prop_press(delta: float) -> void:
	if _prop_press_tile == NO_PRESS_TILE:
		return
	if _dragging:
		_prop_press_tile = NO_PRESS_TILE
		return
	_prop_press_t += delta
	if _prop_press_t >= PROP_LONG_PRESS:
		var tile := _prop_press_tile
		var edge := _prop_press_edge
		_prop_press_tile = NO_PRESS_TILE
		_prop_press_edge = -1
		_hold_follow = false # 拾起接管本次按压，不再按住跟随
		_cancel_player_move()
		if online:
			_bag_action = "pickup"
			backend.send_item_pickup(world_id, tile, edge)
			if game_audio != null:
				game_audio.play_sfx("enter")

## 物品页点一下：进入放置模式（placement-p1 §3.1/§3.2）——收手机、亮 HUD，幽灵停在玩家
## 身旁一个合法初始位（沿用旧的就近找位当默认落点），再由玩家点地挪位、转朝向、确认落地。
## 贴纸（mount edge）默认吸到玩家所站 tile 的空边（南边优先=面向相机）。
func _begin_placement(item_id: String) -> void:
	if int(bag.get(item_id, 0)) < 1 or not online:
		return
	_placing = true
	_place_item_id = item_id
	_place_is_edge = String(ItemCatalog.get_def(item_id).get("mount", "tile")) == "edge"
	_place_yaw = 0.0
	_place_edge = TerrainMap.EDGE_S
	var anchor: Vector2 = player["logical"] if not player.is_empty() else focus_logical
	if _place_is_edge:
		var espot := _find_sticker_spot(WorldGrid.to_tile(WorldGrid.wrap_pos(anchor)))
		if espot.z >= 0:
			_place_tile = Vector2i(espot.x, espot.y)
			_place_edge = espot.z
		else:
			_place_tile = WorldGrid.to_tile(WorldGrid.wrap_pos(anchor))
	else:
		var spot := _find_item_spot(WorldGrid.to_tile(WorldGrid.wrap_pos(anchor + Vector2(3.0, 2.0))))
		_place_tile = spot if spot.x >= 0 else WorldGrid.to_tile(WorldGrid.wrap_pos(anchor))
	if selected != null:
		_exit_interaction()
	_close_phone() # 收起手机看落位（幂等，同时退近身相机）
	if _place_view != null:
		_place_view.visible = true
	_refresh_place_ghost()

## 确认落地：发 item_place 带玩家选的 tile+yaw（贴纸带 edge）。合法才发；服务端权威复检后广播落地。
func _confirm_placement() -> void:
	if not _placing or not _place_legal:
		return
	_bag_action = "place"
	if _place_is_edge:
		backend.send_item_place(world_id, _place_item_id, _place_tile, 0.0, _place_edge)
	else:
		backend.send_item_place(world_id, _place_item_id, _place_tile, _place_yaw)
	if game_audio != null:
		game_audio.play_sfx("pluck") # 从册子拈出来
	_end_placement()

## 退出放置模式（确认后/取消/切场景）：藏幽灵与 HUD，清状态。
func _end_placement() -> void:
	_placing = false
	_place_item_id = ""
	if _place_ghost != null:
		_place_ghost.visible = false
	if _place_view != null:
		_place_view.visible = false

## 扔掉（背包重做设计 §5）：把背包里一份物品扔到玩家身边就近一格，落地成可再捡回的物品。
## 与「摆到地块」不同：无幽灵预览、即时抛出。复用 item_place——占用图只在客户端，故就近找空位
## 在客户端算好，服务端只做权威落地（bag 扣减 + tile 编辑广播）。找不到合法位就落自己脚下兜底，
## 贴纸附近无可贴边则保守不扔（物品留背包）。
func _throw_item(item_id: String) -> void:
	if int(bag.get(item_id, 0)) < 1 or not online:
		return
	var anchor: Vector2 = player["logical"] if not player.is_empty() else focus_logical
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos(anchor + Vector2(2.0, 1.0)))
	var is_edge := String(ItemCatalog.get_def(item_id).get("mount", "tile")) == "edge"
	if is_edge:
		var espot := _find_sticker_spot(want)
		if espot.z < 0:
			return # 附近没边可贴 → 扔不出去（保守：不落，物品留背包）
		backend.send_item_place(world_id, item_id, Vector2i(espot.x, espot.y), 0.0, espot.z)
	else:
		var spot := _find_item_spot(want)
		if spot.x < 0:
			spot = WorldGrid.to_tile(WorldGrid.wrap_pos(anchor)) # 兜底：落自己脚下
		backend.send_item_place(world_id, item_id, spot, 0.0)
	if game_audio != null:
		game_audio.play_sfx("pluck") # 从册子里拈出来扔掉
	_close_phone() # 收手机看落地（幂等，同时退近身相机）

## 放置 HUD：底部一排大按钮（转一转/收起来/放这里）+ 顶部提示条。全屏透明容器不吃点击，
## 只有按钮吃——空地点击照样穿透到 _unhandled_input 去挪幽灵（placement-p1 §3.1）。
func _build_placement_view(host: CanvasLayer) -> void:
	_place_view = Control.new()
	_place_view.name = "PlacementView"
	_place_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_place_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place_view.visible = false
	host.add_child(_place_view)
	_place_hint = Label.new()
	_place_hint.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_place_hint.offset_top = 40.0
	_place_hint.offset_bottom = 110.0
	_place_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_label(_place_hint, 30)
	_place_view.add_child(_place_hint)
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	row.offset_top = -150.0
	row.offset_bottom = -34.0
	row.add_theme_constant_override("separation", 28)
	_place_view.add_child(row)
	var turn := Button.new()
	turn.custom_minimum_size = Vector2(150.0, 116.0)
	UiAssets.style_card_button(turn, 22.0)
	turn.text = "转一转"
	turn.pressed.connect(_rotate_placement)
	row.add_child(turn)
	var cancel := Button.new()
	cancel.custom_minimum_size = Vector2(150.0, 116.0)
	UiAssets.style_card_button(cancel, 22.0)
	cancel.text = "收起来"
	cancel.pressed.connect(func() -> void:
		if game_audio != null:
			game_audio.play_sfx("enter")
		_end_placement())
	row.add_child(cancel)
	_place_confirm_btn = Button.new()
	_place_confirm_btn.custom_minimum_size = Vector2(190.0, 116.0)
	UiAssets.style_card_button(_place_confirm_btn, 24.0)
	_place_confirm_btn.text = "放这里"
	_place_confirm_btn.pressed.connect(_confirm_placement)
	row.add_child(_place_confirm_btn)

## 朝向：点「转一转」加 90°（4 向）。贴纸无朝向（朝向由所在边法线定），转按钮对它无效。
func _rotate_placement() -> void:
	if _place_is_edge:
		return
	_place_yaw = fmod(_place_yaw + 90.0, 360.0)
	if game_audio != null:
		game_audio.play_sfx("bell")
	_refresh_place_ghost()

## yaw(度) → footprint arg（256 档，与服务端 yawToArg 同口径）：仅用于 90/270 时 W/H 互换判定。
func _yaw_to_arg(yaw: float) -> int:
	return int(round(fposmod(yaw, 360.0) / 360.0 * 256.0)) % 256

## 点地落在 _place_tile 内的相对位置 → 最近的边（贴纸吸附）。+x=东 +y=南。
func _nearest_edge(ground: Vector2) -> int:
	var w := WorldGrid.wrap_pos(ground)
	var fx := w.x / WorldGrid.TILE_SIZE - float(_place_tile.x) - 0.5
	var fy := w.y / WorldGrid.TILE_SIZE - float(_place_tile.y) - 0.5
	if absf(fx) >= absf(fy):
		return TerrainMap.EDGE_E if fx > 0.0 else TerrainMap.EDGE_W
	return TerrainMap.EDGE_S if fy > 0.0 else TerrainMap.EDGE_N

## 当前目标是否合法（客户端预判，绿/红上色 + 门确认；服务端 validateTerrainItems 是真权威）。
func _placement_legal() -> bool:
	if _place_is_edge:
		return TerrainMap.tile_type(_place_tile) != TerrainMap.T_WATER \
			and TerrainMap.edge_item_id(_place_tile, _place_edge).is_empty()
	if not TerrainMap.tile_item_id(_place_tile).is_empty():
		return false
	var span := ItemCatalog.footprint(_place_item_id, _yaw_to_arg(_place_yaw))
	var origin := Vector2i(_place_tile.x - (span.x - 1) / 2, _place_tile.y - (span.y - 1) / 2)
	var path_ok := bool(ItemCatalog.get_def(_place_item_id).get("pathOk", false))
	return OccupancyMap.prop_area_ok(origin, span.x, span.y, path_ok)

## 重算幽灵：合法性→颜色，footprint/边→mesh 尺寸与朝向指示，存中心逻辑坐标供每帧重摆。
func _refresh_place_ghost() -> void:
	if _place_ghost == null:
		_place_ghost = MeshInstance3D.new()
		_place_ghost.mesh = BoxMesh.new()
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_place_ghost.material_override = mat
		_place_nub = MeshInstance3D.new()
		_place_nub.mesh = BoxMesh.new()
		(_place_nub.mesh as BoxMesh).size = Vector3(0.5, 0.14, 0.5)
		_place_nub.material_override = mat
		_place_ghost.add_child(_place_nub)
		add_child(_place_ghost)
	_place_ghost.visible = true
	_place_legal = _placement_legal()
	var mat := _place_ghost.material_override as StandardMaterial3D
	mat.albedo_color = Color(0.35, 1.0, 0.5, 0.55) if _place_legal else Color(1.0, 0.4, 0.4, 0.55)
	var ts := WorldGrid.TILE_SIZE
	var center_tile := Vector2(float(_place_tile.x) + 0.5, float(_place_tile.y) + 0.5)
	if _place_is_edge:
		# 贴纸：1×1 tile 上一条贴边的薄条（长边沿该边，往边法线外挪半格）。
		var along_x := _place_edge == TerrainMap.EDGE_N or _place_edge == TerrainMap.EDGE_S
		(_place_ghost.mesh as BoxMesh).size = Vector3(ts * 0.9, 0.14, 0.4) if along_x else Vector3(0.4, 0.14, ts * 0.9)
		var off := Vector2.ZERO
		match _place_edge:
			TerrainMap.EDGE_N: off = Vector2(0.0, -0.5)
			TerrainMap.EDGE_S: off = Vector2(0.0, 0.5)
			TerrainMap.EDGE_E: off = Vector2(0.5, 0.0)
			TerrainMap.EDGE_W: off = Vector2(-0.5, 0.0)
		center_tile += off
		_place_nub.visible = false
	else:
		var span := ItemCatalog.footprint(_place_item_id, _yaw_to_arg(_place_yaw))
		var origin := Vector2(float(_place_tile.x) - float(span.x - 1) / 2.0, float(_place_tile.y) - float(span.y - 1) / 2.0)
		center_tile = origin + Vector2(float(span.x), float(span.y)) * 0.5
		(_place_ghost.mesh as BoxMesh).size = Vector3(float(span.x) * ts * 0.92, 0.12, float(span.y) * ts * 0.92)
		# 朝向指示小块：贴在 footprint「正面」半格外，随 yaw 转（0=南朝相机）。
		_place_nub.visible = true
		var dir := Vector2.ZERO
		match _yaw_to_arg(_place_yaw) * 360 / 256:
			0: dir = Vector2(0.0, 1.0)
			90: dir = Vector2(-1.0, 0.0)
			180: dir = Vector2(0.0, -1.0)
			270: dir = Vector2(1.0, 0.0)
		_place_nub.position = Vector3(dir.x * (float(span.x) * ts * 0.5 + 0.2), 0.02, dir.y * (float(span.y) * ts * 0.5 + 0.2))
	_place_ghost_logical = WorldGrid.wrap_pos(center_tile * ts)
	_update_place_ghost()
	_update_placement_hint()

## 每帧把幽灵重摆到弯曲地表（世界随玩家滚动，逻辑坐标固定，渲染位置要重算）。
func _update_place_ghost() -> void:
	if not _placing or _place_ghost == null or not _place_ghost.visible:
		return
	var d := WorldGrid.shortest_delta(focus_logical, _place_ghost_logical)
	var ty := float(TerrainMap.tile_height(_place_tile)) * TerrainMap.STEP_HEIGHT
	_place_on_bent_ground(_place_ghost, Vector3(d.x, ty + 0.08, d.y))

## HUD 提示 + 「放这里」按钮按合法性启用/灰显。
func _update_placement_hint() -> void:
	if _place_hint == null:
		return
	var noun := "贴纸" if _place_is_edge else "东西"
	if _place_legal:
		_place_hint.text = "点空地挪一挪，好了就按「放这里」"
	else:
		_place_hint.text = "这里放不下这个%s，换个地方点点看" % noun
	if _place_confirm_btn != null:
		_place_confirm_btn.disabled = not _place_legal
		_place_confirm_btn.modulate = Color.WHITE if _place_legal else Color(1, 1, 1, 0.4)

# ── 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md §4.2）──────────────────
# 造物类心愿造成功后不当场盖章：村民抱怨「差一点」→ wish_trial 亮起变大/变小箭头，小朋友点箭头
# 调体型（3 岁点选、不拖拽）→ send_wish_refine → 服务端应用体型+广播重渲染 + 判定满意/再问。

## 试用 HUD：底部「变小/变大/好啦」三大按钮 + 顶部提示。透明容器不吃点击，只按钮吃。
func _build_refine_view(host: CanvasLayer) -> void:
	_refine_view = Control.new()
	_refine_view.name = "RefineView"
	_refine_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_refine_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_refine_view.visible = false
	host.add_child(_refine_view)
	_refine_hint = Label.new()
	_refine_hint.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_refine_hint.offset_top = 40.0
	_refine_hint.offset_bottom = 110.0
	_refine_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_refine_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_label(_refine_hint, 30)
	_refine_view.add_child(_refine_hint)
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	row.offset_top = -150.0
	row.offset_bottom = -34.0
	row.add_theme_constant_override("separation", 28)
	_refine_view.add_child(row)
	var smaller := Button.new()
	smaller.custom_minimum_size = Vector2(170.0, 116.0)
	UiAssets.style_card_button(smaller, 24.0)
	smaller.text = "变小一点"
	smaller.pressed.connect(_refine_press.bind(-1))
	row.add_child(smaller)
	var bigger := Button.new()
	bigger.custom_minimum_size = Vector2(170.0, 116.0)
	UiAssets.style_card_button(bigger, 24.0)
	bigger.text = "变大一点"
	bigger.pressed.connect(_refine_press.bind(1))
	row.add_child(bigger)
	var done := Button.new()
	done.custom_minimum_size = Vector2(150.0, 116.0)
	UiAssets.style_card_button(done, 22.0)
	done.text = "好啦"
	done.pressed.connect(func() -> void:
		if game_audio != null:
			game_audio.play_sfx("enter")
		_end_refine())
	row.add_child(done)

## 造物类心愿开「试用」：村民抱怨已由服务端 praise_tts 推来（_on_praise_tts 用村民音色播），
## 这里亮起变大/变小箭头 + 指向那件东西 + 播仙子问句（预制 WAV，独立通道不碰 _tts_player）。
func _on_wish_trial(data: Dictionary) -> void:
	_refine_active = true
	_refine_item_ref = String(data.get("itemRef", ""))
	_refine_dir = String(data.get("refineDir", ""))
	_refine_size = String(data.get("fromSize", "medium"))
	_refine_prop_tile = _scan_item_tile(_refine_item_ref) # 角色返回 (-1,-1)，改用 npc 节点定位
	if fairy_voice != null:
		fairy_voice.try_play(String(data.get("fairyHint", "refine_hint"))) # 只问不给答案
	_raise_refine_indicator()
	if _refine_view != null:
		_refine_view.visible = true
	_update_refine_hint()
	banner.text = "他好像还差一点点…帮他变一变吧！"
	banner.visible = true

## 调反了、还没到上限：仙子升一级再问一句（仍是问句），箭头保留（可继续调）。
func _on_wish_retry(data: Dictionary) -> void:
	if not _refine_active:
		return
	if fairy_voice != null:
		fairy_voice.try_play(String(data.get("fairyHint", "refine_hint_2")))
	_update_refine_hint()

## 点箭头：按方向在三档阶梯里步进一档（夹取），发 wish_refine 上报。体型重渲染由服务端广播回来落地。
## 到边界（已最小/最大）也照发——服务端按方向判定：够得到就盖章，反了就再问（≤2 次必收尾）。
func _refine_press(dir: int) -> void:
	if not _refine_active or _refine_item_ref.is_empty() or not online:
		return
	var idx := REFINE_SIZES.find(_refine_size)
	if idx < 0:
		idx = 1 # 未知档按中号起步
	var next := clampi(idx + dir, 0, REFINE_SIZES.size() - 1)
	_refine_size = String(REFINE_SIZES[next])
	if game_audio != null:
		game_audio.play_sfx("bell")
	backend.send_wish_refine(world_id, _refine_item_ref, _refine_size)

## 结束试用（满意盖章/收起/换场景）：藏箭头 HUD + 指示器，清状态。
func _end_refine() -> void:
	_refine_active = false
	_refine_item_ref = ""
	_refine_prop_tile = Vector2i(-1, -1)
	if _refine_view != null:
		_refine_view.visible = false
	if _refine_indicator != null:
		_refine_indicator.visible = false

func _update_refine_hint() -> void:
	if _refine_hint != null:
		_refine_hint.text = "点「变大一点」或「变小一点」帮帮他"

## 立起指向 refineItemRef 的悬浮提示（think 气泡），随实体位置每帧重摆（_update_refine_indicator）。
func _raise_refine_indicator() -> void:
	if _refine_indicator == null:
		_refine_indicator = UiAssets.bubble_sprite("em_think", 1.6)
		add_child(_refine_indicator)
	_refine_indicator.visible = true

## 每帧把指示器摆到那件东西头顶（角色跟 npc 节点，造物按落地 tile；渲染原点 = focus_logical）。
## 造物落地要等 item_place 回程的 terrain_patch，故 tile 没找到时每帧补扫一次直到落地。
func _update_refine_indicator(delta: float) -> void:
	if not _refine_active or _refine_indicator == null:
		return
	_refine_bob += delta
	var bob := sin(_refine_bob * 3.0) * 0.15
	var npc := _find_npc_by_id(_refine_item_ref)
	if npc != null and is_instance_valid(npc):
		_refine_indicator.visible = true
		_refine_indicator.global_position = npc.global_position + Vector3(0.0, _char_top(npc) + 1.4 + bob, 0.0)
		return
	if _refine_prop_tile.x < 0:
		_refine_prop_tile = _scan_item_tile(_refine_item_ref) # 还没落地（item_place 回程未到）：补扫
	if _refine_prop_tile.x >= 0:
		_refine_indicator.visible = true
		var logical := (Vector2(_refine_prop_tile) + Vector2(0.5, 0.5)) * float(WorldGrid.TILE_SIZE)
		var d := WorldGrid.shortest_delta(focus_logical, logical)
		var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(logical))) * TerrainMap.STEP_HEIGHT
		_place_on_bent_ground(_refine_indicator, Vector3(d.x, ty + 2.2 + bob, d.y))
	else:
		_refine_indicator.visible = false # 暂时定不了位（角色异步降生/造物未落地）：先藏，下一帧再试

## 扫当前场景矩阵找挂着某实体的 tile（造物指示器定位用）。找不到回 (-1,-1)。
func _scan_item_tile(item_ref: String) -> Vector2i:
	if item_ref.is_empty():
		return Vector2i(-1, -1)
	var n := WorldGrid.GRID_TILES
	for y in range(n):
		for x in range(n):
			if TerrainMap.tile_item_id(Vector2i(x, y)) == item_ref:
				return Vector2i(x, y)
	return Vector2i(-1, -1)

## 造角色体型改了（服务端 wish_refine 重渲染广播）：找到那个 npc，按新 scale 比例重缩放。
## 按 visible_height 比例改 pixel_size——静态整图/动画图集通用（visible_height 已按 cellH 归一），
## 不用管当前是立绘还是动画段，脚底对齐由 offset（texel 口径）自动保持。
func _on_character_resized(data: Dictionary) -> void:
	var cid := String(data.get("characterId", ""))
	var npc := _find_npc_by_id(cid)
	if npc == null or not is_instance_valid(npc):
		return
	var scale := float(data.get("scale", 1.0))
	var new_h := VILLAGER_BASE_HEIGHT * scale
	var cur_h := npc.visible_height()
	if cur_h > 0.0:
		npc.pixel_size = npc.pixel_size * (new_h / cur_h)
		BlobShadow.attach(npc, clampf(new_h * 0.38, 0.4, 1.4))
	# npcs 字典里的 scale 同步（游走/构图/交互半径按它算高度）
	for nd in npcs:
		if String(nd.get("id", "")) == cid:
			nd["scale"] = scale
			break

## 贴纸边缘找位：want tile 起螺旋外扩，每 tile 按 S→E→W→N 试空边（S 面向相机优先）。
## 返回 Vector3i(x, y, side)；找不到 side=-1。边缘不占地，只查该边为空。
const STICKER_SIDE_ORDER: Array[int] = [TerrainMap.EDGE_S, TerrainMap.EDGE_E, TerrainMap.EDGE_W, TerrainMap.EDGE_N]
func _find_sticker_spot(want: Vector2i) -> Vector3i:
	for r in range(0, 4):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var t := Vector2i(posmod(want.x + dx, WorldGrid.GRID_TILES), posmod(want.y + dz, WorldGrid.GRID_TILES))
				if TerrainMap.tile_type(t) == TerrainMap.T_WATER:
					continue # 水面边缘不贴（视觉浮空）
				for side in STICKER_SIDE_ORDER:
					if TerrainMap.edge_item_id(t, side).is_empty():
						return Vector3i(t.x, t.y, side)
	return Vector3i(-1, -1, -1)

## 造物落位的本地找位：want 起螺旋外扩，找可放 1×1 物品的 tile（允许路面，与实体
## pathOk=true 对齐；查静态/动态占用与角色站位）。找不到返回 (-1,-1)。
func _find_item_spot(want: Vector2i) -> Vector2i:
	for r in range(0, 4):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue # 只走环上，避免重复
				var t := Vector2i(posmod(want.x + dx, WorldGrid.GRID_TILES), posmod(want.y + dz, WorldGrid.GRID_TILES))
				if TerrainMap.tile_item_id(t).is_empty() and OccupancyMap.prop_area_ok(t, 1, 1, true):
					return t
	return Vector2i(-1, -1)

## 点点造角色（在线）。
func _request_create(intent: String) -> void:
	if online:
		thinking_label.text = "施法中…"
		thinking_label.visible = true
		backend.send_create_character(world_id, intent)

## 挂起一次「说完再走」：记下要执行的脚本，等回应说完（见 _step_pending_leave）。
func _arm_pending_leave(npc: PaperCharacter, script: Dictionary) -> void:
	_pending_leave = {
		"npc": npc, "script": script, "seen": false,
		"arm": InteractionFsm.LEAVE_ARM_SEC,
		"deadline": InteractionFsm.LEAVE_DEADLINE_SEC,
	}

## 每帧推进：说完了（或宽限/兜底到点）就让角色动身，随后关对话。
func _step_pending_leave(delta: float) -> void:
	if _pending_leave.is_empty():
		return
	var speaking := _fsm_inputs().speaking()
	if speaking:
		_pending_leave["seen"] = true
	_pending_leave["arm"] = float(_pending_leave["arm"]) - delta
	_pending_leave["deadline"] = float(_pending_leave["deadline"]) - delta
	if not InteractionFsm.leave_ready(bool(_pending_leave["seen"]), speaking,
			float(_pending_leave["arm"]), float(_pending_leave["deadline"])):
		return
	_flush_pending_leave() # 先派发脚本、清空挂起
	_exit_interaction()    # 再关对话（此时挂起已空，不会二次派发）

## 派发挂起的脚本并清空。玩家中途自己走开时也会走这里——指令是孩子下的，不能丢。
func _flush_pending_leave() -> void:
	if _pending_leave.is_empty():
		return
	var npc: PaperCharacter = _pending_leave.get("npc")
	var script: Dictionary = _pending_leave.get("script", {})
	_pending_leave = {}
	if is_instance_valid(npc):
		_run_behavior(npc, script)

## 一次空识别：多半是 VAD 误触发。闭麦退避一段再听，连续空则指数退避——
## 否则刚放开麦就被同一串噪声再次触发，连环录（缺陷 ①）。
func _begin_empty_cooldown() -> void:
	_empty_streak += 1
	_cooldown_t = InteractionFsm.empty_cooldown(_empty_streak)
	# VAD 复位交给 VoiceCapture：cooldown>0 → FSM COOLDOWN 态 → 下一帧 should_capture 假即 reset。
	if OS.is_debug_build():
		print("[vad] EMPTY streak=%d cooldown=%.1fs" % [_empty_streak, _cooldown_t])

## 拿到有效转写：退避清零，恢复正常聆听节奏。
func _reset_empty_streak() -> void:
	_empty_streak = 0
	_cooldown_t = 0.0

# ── VoiceCapture 信号回调（world 侧业务：耗时打点/退避/喊话中继/造物/服务端 sink）──────

## 端侧模型就绪：debug 日志由模块打，本处无需额外动作（就绪门禁在 should_capture）。
func _on_capture_ready() -> void:
	pass

## 确认模式：识别好了但先别发——VoiceCapture 正在回放那句话，亮确认条等孩子点。
## 收条在 _on_capture_committed（accept 会补发 committed）与退对话时。
func _on_capture_confirm_ready(text: String) -> void:
	thinking_label.visible = false # 说完不等于采纳：这会儿还没人在思考
	if confirm_bar != null:
		confirm_bar.show_for(text)

## 开口：清零本轮耗时戳。识别在端侧，开口这一刻不需要通知服务端。
func _on_capture_begin() -> void:
	_vt_speak_start = Time.get_ticks_msec()
	_vt_speak_end = 0
	_vt_asr_done = 0
	_vt_send = 0
	_vt_response = 0
	_vt_tts_out = 0

## 说完：亮思考态、造物投掷，等端侧识别出文本（local_final）。不关麦（继续聆听）。
func _on_capture_committed() -> void:
	# B3 起名子模式：采纳后 committed 先到、local_final 随后带来名字文本——这里什么都不做，
	# 不亮思考态、不投蛋、不开解卡定时器，等 _on_capture_local_final 里 _finish_naming。
	if not _naming_item.is_empty():
		if confirm_bar != null:
			confirm_bar.hide_bar()
		return
	if confirm_bar != null:
		confirm_bar.hide_bar() # 采纳了（或本就没开确认模式）：收条
	# 喊话没有服务端回复要等：不亮「思考中」、不开解卡定时器（端侧 ASR final 秒回）
	if _talk_pid.is_empty():
		thinking_label.visible = true
	banner.visible = false
	if _in_creation:
		_throw_voice_answer() # 说完就把「这句话」扔进蛋/炉：孩子看得见自己的回答被用上了
	_vt_speak_end = Time.get_ticks_msec()
	if _talk_pid.is_empty():
		_think_timer.start(THINK_TIMEOUT)  # 兜底：响应没回来也会自动解卡

## 太短的误触/中途丢弃：端侧丢弃即可，服务端没有半开会话要收。
func _on_capture_cancelled() -> void:
	pass

## 端侧识别出最终文本：空→退避；喊话→文本中继；否则送对话。
func _on_capture_local_final(text: String) -> void:
	# B3 起名子模式：这句话就是造物的名字——打包录音 + 文本发服务端落库，不走对话。
	if not _naming_item.is_empty():
		_finish_naming(text)
		return
	_vt_asr_done = Time.get_ticks_msec() # 端侧识别出文本
	var t := text.strip_edges()
	if t.is_empty():
		# 端侧就知道没听清，不必打扰服务端
		_think_timer.stop()
		thinking_label.visible = false
		heard_label.text = "没听清，再说一次试试"
		heard_label.visible = true
		_begin_empty_cooldown()
		return
	_reset_empty_streak()
	if not _talk_pid.is_empty() and selected == null:
		_handle_talk_transcript(t) # 玩家喊话：文本中继给对方，不走 NPC 对话
		return
	_vt_send = Time.get_ticks_msec() # 发转写 → 到 character_response 即纯 LLM 耗时
	backend.send_voice_transcript(world_id, _selected_id(), t)

# ── B3 语音起名（reuse-name §2.2/§3.2/§3.3）─────────────────────────────────────
# 造物成功 → 点点问「叫它什么呀？」→ VoiceCapture 确认模式（说→回放自己声音→确认）→ 上传录音当名字。
# 起名是【邀请不是关卡】：离线/无端侧 ASR/不吭声/害羞一律静默跳过，item 保留 LLM 文本名。

## 造物成功后的点点这一拍：能起名就问名字（name_ask），起不了名（离线/无端侧 ASR）就退回求夸（create_done）。
func _offer_naming(item_id: String) -> void:
	if not _begin_naming(item_id):
		_fairy_say("create_done")

## 发起起名：点点问一句 + 开确认模式麦。返回是否真的进了起名子模式（决定要不要退回求夸）。
func _begin_naming(item_id: String) -> bool:
	if item_id.is_empty() or not online or _vc == null or not _vc.is_ready():
		return false
	if not _naming_item.is_empty():
		return false # 已在给别的东西起名：别打断（理论上造物是串行的，兜底）
	_naming_item = item_id
	_naming_prev_confirm = _vc.confirm_mode
	_vc.confirm_mode = true # 起名必须走确认模式：小龄孩子说完先听自己的声音再确认（§3.2）
	_fairy_say("name_ask") # 点点问「你想叫它什么呀？」（预制 WAV，Yunxia 音色）
	_vc.open() # 开麦；实际开录由 _voice_should_capture 起名分支放行（点点问句播完才放）
	_naming_timer.start(NAMING_TIMEOUT)
	return true

## 收尾起名：恢复 confirm_mode 原设置、停超时、不在对话态就关麦、收确认条。幂等。
func _end_naming() -> void:
	if _naming_item.is_empty():
		return
	_naming_item = ""
	if _vc != null:
		_vc.confirm_mode = _naming_prev_confirm
		# 起名的麦是独立开的：不在近身/喊话态就关掉，别把裸麦留着（在对话里则让对话逻辑继续持麦）
		if selected == null and _talk_pid.is_empty():
			_vc.close()
	if _naming_timer != null:
		_naming_timer.stop()
	if confirm_bar != null:
		confirm_bar.hide_bar()

## 孩子采纳了名字（confirm→local_final）：打包整段录音（原始 PCM）+ ASR 文本发服务端落库。
## 没说清 / 没录到 → 静默跳过（item 保留 LLM 名，起名可选）。
func _finish_naming(text: String) -> void:
	var item_id := _naming_item
	var t := text.strip_edges()
	var pcm := _vc.last_pcm() if _vc != null else PackedByteArray()
	_end_naming()
	if item_id.is_empty() or t.is_empty() or pcm.is_empty():
		return
	backend.send_name_creation(world_id, item_id, Marshalls.raw_to_base64(pcm), t)
	# 不展示 ASR 文本（孩子不识字，§3.2）：只给一句通用祝贺 + 收进册子的动效。
	banner.text = "起好名字啦！"
	banner.visible = true
	if game_audio != null:
		game_audio.play_sfx("confirm")

## 起名静默超时：正在说/正在确认就再续一轮（别打断孩子），否则放弃（害羞/没吭声，§3.3）。
func _on_naming_timeout() -> void:
	if _vc != null and (_vc.is_recording() or _vc.is_confirming()):
		_naming_timer.start(NAMING_TIMEOUT)
		return
	_end_naming()

## B3 起名回填广播：就地更新背包里那件的 nameVoiceAsset/nameText（下次开背包就画小喇叭角标）。
func _on_item_updated(data: Dictionary) -> void:
	var item: Dictionary = data.get("item", {})
	if item.is_empty():
		return
	ItemCatalog.set_defs([item]) # 目录里那行整份换新（带上 nameVoiceAsset）
	if phone_ui != null:
		phone_ui.refresh_items() # 背包页重画：那格出小喇叭角标

## 手机设置「说完先听一遍」：存档案 + 即时生效（下一句话就走确认流程，不必重进世界）。
func _on_confirm_voice_toggled(on: bool) -> void:
	PlayerProfile.set_confirm_voice(on)
	if _vc != null:
		_vc.confirm_mode = on
	if phone_ui != null:
		phone_ui.refresh_confirm_voice_button()

## 每帧驱动：角色思考/说话时闭麦（半双工防自听），其余时间把麦克风增量喂 VAD。
## 当前帧的交互标志位快照 → 喂给显式状态机（见 interaction_fsm.gd）。
## 字段与旧 _step_voice 的闭麦表达式逐字对应，行为等价由 test_interaction_fsm 的 64 组合护栏保证。
func _fsm_inputs() -> InteractionFsm.Inputs:
	return InteractionFsm.Inputs.new({
		"in_interaction": selected != null or not _talk_pid.is_empty(), # 玩家喊话态同样开麦（ASR 门禁见 _voice_should_capture）
		"approaching": not _approach.is_empty(),
		"thinking": thinking_label != null and thinking_label.visible,
		"tts_busy": (_tts_player != null and _tts_player.playing) or _tts_pending,
		"fairy_speaking": fairy_voice != null and fairy_voice.is_playing(),
		"recording": _vc.is_recording() if _vc != null else false,
		"in_creation": _in_creation,
		"cooldown": _cooldown_t > 0.0,
	})

## 本帧的显式交互状态。
func _fsm_state() -> InteractionFsm.State:
	return InteractionFsm.derive(_fsm_inputs())

func _on_character_response(data: Dictionary) -> void:
	if _think_timer != null:
		_think_timer.stop()
	thinking_label.visible = false
	# 主动招呼（对方先开口）：不是玩家发起的一轮，跳过「听到/没听清」提示，只放招呼台词+TTS
	var is_greeting := bool(data.get("greeting", false))
	if is_greeting:
		_last_greeting = String(data.get("replyText", "")) # harness 观测：招呼链的对方开场白
	# 语音耗时：玩家发起的一轮记回应到达并刷新浮层（招呼非玩家轮，跳过）
	if not is_greeting:
		_vt_response = Time.get_ticks_msec()
		_vt_tts_out = 0
		_update_voice_prof()
	if not is_greeting:
		var transcript := String(data.get("transcript", ""))
		if transcript.is_empty():
			heard_label.text = "没听清，再说一次试试"
			game_audio.play_sfx("oops")
			_begin_empty_cooldown() # 服务端 ASR 路径的空结果，同样退避（缺陷 ①）
		else:
			heard_label.text = "听到：%s" % transcript
			game_audio.play_sfx("bell")
			_reset_empty_streak()
		heard_label.visible = true
	banner.text = String(data.get("replyText", ""))
	banner.visible = true
	_show_emotion(String(data.get("emotion", "happy")))
	if typeof(data.get("task")) == TYPE_DICTIONARY:
		_set_active_task(data["task"]) # 新发起的委托（或进行中的重申）→ 提示 chip
	if bool(data.get("taskCleared", false)):
		_set_active_task(null) # 小朋友说「不想做了」→ 服务端已清委托，撤掉提示 chip
	# 引路（仅小仙子）：guide=开始领路（新计划覆盖旧的）；guideStop=小朋友说「不去了」。
	# 服务端算不出计划时不会下发 guide，只留口头回应——她绝不会应下「跟我来」却不动。
	if typeof(data.get("guide")) == TYPE_DICTIONARY:
		start_guide(data["guide"])
	if bool(data.get("guideStop", false)):
		end_guide("") # 取消的话 LLM 的 replyText 已经说了，不再叠一句预制词
	var script: Variant = data.get("behaviorScript", null)
	if typeof(script) == TYPE_DICTIONARY:
		# 点名指派（performerId）：不隔空遥控——正在对话的角色跑腿到执行者旁把指令带到，
		# 对方点头应答才开始做（见 _relay_command）；没有说话者在场才直接下发。
		var performer := _find_npc_by_id(String(data.get("performerId", "")))
		var speaker_is_fairy := selected != null and bool(_find_npc_dict(selected).get("is_fairy", false))
		if performer != null and selected != null and performer != selected and not speaker_is_fairy:
			_dispatch_from_speaker(selected, { "commands": [{ "type": "relay_command",
				"params": { "to": String(data.get("performerId", "")), "script": script } }], "loop": false }, true)
		elif performer != null:
			# 说话者不在场，或说话的是小仙子（她隔空施法、从不跑腿——让她跑腿等于把指令扔了）：直接下发。
			_run_behavior(performer, script)
		elif selected != null:
			_dispatch_from_speaker(selected, script, false)
	if bool(data.get("ttsStreaming", false)):
		_start_tts_stream(_parse_rate(String(data.get("ttsMime", "")), 24000))
	else:
		var asset := String(data.get("ttsAsset", ""))
		if not asset.is_empty():
			_play_tts(asset)
		else:
			# clientTts：服务端只给文本+voiceId，本地 edge 合成（失败内部降级 tts_request）
			_speak_line(String(data.get("replyText", "")), String(data.get("voiceId", "")))

## 构建专门的创造视图（方案 A）：全屏暗底吃掉卡外点击 + 顶部问题字幕/进度点 + 屏幕中央 2×2 大卡。
## 造角色/造物共用；节点常驻隐藏，进创造时 _enter_creation_view 点亮。
func _build_creation_view(host: CanvasLayer) -> void:
	_creation_view = Control.new()
	_creation_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_creation_view.mouse_filter = Control.MOUSE_FILTER_STOP # 吃掉卡外乱点，别穿到世界
	_creation_view.visible = false
	host.add_child(_creation_view)

	# 暖色径向暗角：中间几乎透明（仙子+大卡看清），四周压暗——把注意力聚到中央，世界边缘退后。
	var vig := TextureRect.new()
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	var grad := Gradient.new()
	grad.set_color(0, Color(0.05, 0.04, 0.02, 0.12)) # 中心：极轻压暗
	grad.set_color(1, Color(0.05, 0.04, 0.02, 0.82)) # 边缘：明显压暗
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 1.0)
	gt.width = 256
	gt.height = 256
	vig.texture = gt
	_creation_view.add_child(vig)

	# 顶部问题字幕（语音为主，字给家长）：深色药丸底 + 大白字。
	_creation_q = Label.new()
	_creation_q.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_creation_q.offset_top = 40.0
	_creation_q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_creation_q.add_theme_font_size_override("font_size", 40)
	_creation_q.add_theme_color_override("font_color", Color.WHITE)
	_creation_q.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	_creation_q.add_theme_constant_override("outline_size", 10)
	_creation_q.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_creation_view.add_child(_creation_q)

	# 进度圆点：每答一轮点亮一个（服务端不下发总步数，客户端本地累加）。
	_creation_dots = HBoxContainer.new()
	_creation_dots.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_creation_dots.offset_top = 104.0
	_creation_dots.add_theme_constant_override("separation", 12)
	_creation_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_creation_view.add_child(_creation_dots)

	# 2×2 大卡网格：居中于屏幕右侧 ~62%，把左侧让给仙子特写（方案 A：仙子左、卡在右）。
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.anchor_left = 0.38
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_creation_view.add_child(center)
	_creation_cards = GridContainer.new()
	_creation_cards.columns = 2
	_creation_cards.add_theme_constant_override("h_separation", 22)
	_creation_cards.add_theme_constant_override("v_separation", 22)
	center.add_child(_creation_cards)

	# 右上角圆叉：随时退出创造（蛋/炉一起收）。放在角上不与选项卡同列——幼儿不会把它当成第五个答案。
	_creation_cancel_btn = Button.new()
	_creation_cancel_btn.name = "CreationCancel"
	_creation_cancel_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_creation_cancel_btn.offset_left = -128.0
	_creation_cancel_btn.offset_top = 32.0
	_creation_cancel_btn.custom_minimum_size = Vector2(96.0, 96.0)
	_creation_cancel_btn.size = Vector2(96.0, 96.0)
	_creation_cancel_btn.text = "✕"
	UiAssets.style_card_button(_creation_cancel_btn, 48.0) # 圆角拉满=圆形，与选项卡同一贴纸质感
	_creation_cancel_btn.add_theme_font_size_override("font_size", 46)
	_creation_cancel_btn.pressed.connect(_on_creation_cancel_pressed)
	_creation_view.add_child(_creation_cancel_btn)

## 进创造视图：退出普通对话构图（关横幅/情绪气泡/听到字幕，麦保留——孩子仍可语音答复），
## 相机推近仙子特写、背景压暗，点亮创造视图。幂等（每轮 creation_prompt 都可安全调）。
func _enter_creation_view(is_remix := false) -> void:
	_in_creation = not is_remix # 改装无 LLM 会话：不进 _in_creation，否则 _exit_interaction 会误发 creation_cancel
	_creation_cam = true
	banner.visible = false          # 普通对话的横幅/提示不在创造视图里出现
	heard_label.visible = false
	if emotion_bubble != null:
		emotion_bubble.visible = false # 收起头顶情绪气泡（创造视图是干净特写）
	_emotion_life = 0.0
	_layout_voice_wave(true) # 收听 HUD 让位给 2×2 大卡：缩小左移
	if _creation_view != null:
		_creation_view.visible = true

## 引导式创造追问一轮（造角色或造物共用此路径）：仙子念问句 + 屏幕中央弹 2×2 大卡；点卡或直接说都行。
## 消息 goal-agnostic：客户端只管渲染服务端给的 options、回传 optionId，造角色还是物件由服务端 goal 决定。
func _on_creation_prompt(data: Dictionary) -> void:
	if _think_timer != null:
		_think_timer.stop()
	thinking_label.visible = false
	_creation_goal = String(data.get("goal", "character")) # 造角色→降生蛋，造物→魔法熔炉，造贴纸→魔法画板
	_enter_creation_view() # 首轮：退出普通对话构图、相机推近仙子特写、点亮创造视图
	_raise_creation_placeholder() # 引导一开始就立起蛋/炉：孩子的回答一会儿要扔进去
	# 问题只给家长看的字幕（幼儿不识字，靠 TTS 念）
	_creation_q.text = String(data.get("question", data.get("replyText", "")))
	_creation_q.visible = true
	_advance_creation_dots()
	_creation_category = String(data.get("category", ""))
	_creation_options = data.get("options", []) # 存原始选项供 e2e harness 点卡应答（快照读）
	_build_creation_cards(data.get("options", []))
	# A2「给谁做的」（docs/kids-thinking-made-for-whom.md）：recipient 是可跳过的软步骤——多加一张「随便啦」卡。
	# 它走现成 send_creation_reply（optionId='recipient_skip'），服务端回落「给大家」，绝不进 creation_cancelled
	# （那是「不造了」，语义不同）。选项本身（自己/在场村民立绘/大家）已由 _build_creation_cards 通用渲染。
	if _creation_category == "recipient":
		_append_recipient_skip_card()
	var asset := String(data.get("ttsAsset", ""))
	if not asset.is_empty():
		_play_tts(asset) # 仙子把问题和选项念出来（幼儿不识字）
	else:
		# clientTts：仙子问句本地 edge 合成（幼儿不识字，念不出来就降级服务端）
		_speak_line(String(data.get("replyText", data.get("question", ""))), String(data.get("voiceId", "")))

## 积木式造物追问一轮（build）：与 creation_prompt 平行，多一个「拼装台」——骨架浮在仙子身旁，
## 当前要填的槽（slotId）发光，零件盘复用 2×2 大卡（占位阶段无图→文字标签）。点零件→填槽→飞入。
## 点点不会走路（硬约束）：拼装台只是浮在她身旁的预览，全程不碰 BehaviorExecutor、不夺玩家操控。
func _on_build_prompt(data: Dictionary) -> void:
	if _think_timer != null:
		_think_timer.stop()
	thinking_label.visible = false
	_creation_goal = "build"
	_build_blueprint_id = String(data.get("blueprintId", ""))
	_build_slot = String(data.get("slotId", "")) # 当前要填的槽：拼装台点亮它发光
	_enter_creation_view() # 首轮：退出普通对话构图、相机推近仙子特写、点亮创造视图
	_raise_build_preview() # 骨架浮在仙子身旁（幂等：已立起则复用）
	_update_build_preview() # 画已填零件 + 当前槽发光
	_creation_q.text = String(data.get("question", data.get("replyText", ""))) # 功能问句字幕（幼儿不识字，靠 TTS）
	_creation_q.visible = true
	_advance_creation_dots()
	# 零件盘：记 partId→renderRef（点选后更新预览用），复用创造大卡渲染（options 同 {id,label} 形状）
	_build_option_refs.clear()
	for opt in data.get("options", []):
		if typeof(opt) == TYPE_DICTIONARY:
			_build_option_refs[String((opt as Dictionary).get("id", ""))] = String((opt as Dictionary).get("renderRef", ""))
	_creation_category = "build_slot" # 拼装填槽轮：harness 据此知道是零件盘
	_creation_options = data.get("options", []) # 存原始零件选项供 e2e harness 点卡（快照读）
	_build_creation_cards(data.get("options", []))
	var asset := String(data.get("ttsAsset", ""))
	if not asset.is_empty():
		_play_tts(asset) # 点点把功能问句念出来（幼儿不识字）
	else:
		_speak_line(String(data.get("replyText", data.get("question", ""))), String(data.get("voiceId", "")))

## 拼装台预览：ComposedProp 浮在仙子身旁（放不下也不崩，后续路径容忍缺席）。幂等。
func _raise_build_preview() -> void:
	if _build_preview != null and is_instance_valid(_build_preview):
		return
	var cp := ComposedProp.new()
	# 落地尺寸放大一档（HEIGHT 5m）后，预览缩回原 3m 观感——全尺寸预览会怼脸挡问题卡
	cp.scale = Vector3.ONE * (ComposedProp.PREVIEW_HEIGHT / ComposedProp.HEIGHT)
	# 引导拼装挂仙子身旁（特写同框）；改装无仙子会话 → 挂玩家身旁（关手机后玩家一定在屏上）。
	var anchor: Node3D = null
	if _remixing and not player.is_empty() and is_instance_valid(player["node"]):
		anchor = player["node"] as Node3D
	else:
		var fairy := _find_fairy()
		anchor = fairy.get("node") if not fairy.is_empty() else null
	if anchor != null and is_instance_valid(anchor) and anchor.get_parent() != null:
		anchor.get_parent().add_child(cp)
		cp.position = anchor.position + BUILD_PREVIEW_OFFSET # 侧旁略上，与主角同框
	else:
		add_child(cp) # 兜底：锚点节点缺席也别崩
	_build_preview = cp

## 刷新拼装台：按已填槽重画骨架 + 零件，当前要填的槽发光（幂等重建，每轮 build_prompt 调）。
func _update_build_preview() -> void:
	if _build_preview == null or not is_instance_valid(_build_preview):
		return
	_build_preview.set_filled(_build_blueprint_id, _build_filled)
	_build_preview.set_glow_slot(_build_slot)

## 收起拼装台（取消/走开/拼好开工）：清预览 + 重置拼装状态。
func _clear_build_preview() -> void:
	if _build_preview != null and is_instance_valid(_build_preview):
		_build_preview.queue_free()
	_build_preview = null
	_build_blueprint_id = ""
	_build_slot = ""
	_build_filled = {}
	_build_option_refs.clear()

# ── 复用改装（B1，§3.1「拆开重组」）：物品页点组合物 → 二选一 → 拼装台改一槽 → 做好了落成新 ItemDef ──
# 老板拍板入口形态：点组合物弹「摆到世界 / 拆开改改」二选一（点点会话式改装被否，§3.1「无需新机制」直接编辑）。
# 全程客户端本地权威编辑零件树、无 LLM 会话；做好了 send_create_build，旧组合物保留、新造一行（通往 B3）。

## 物品页点了组合物：弹「摆到世界 / 拆开改改」二选一小卡（普通物件不走这条，直接放置）。
func _on_composed_item_tapped(item_id: String) -> void:
	if int(bag.get(item_id, 0)) < 1:
		return
	_show_remix_choice(item_id)

## 二选一小卡：暗底 + 中央两张大按钮。点外面=收起（不动手机），选一个=收起后各走各路。
func _show_remix_choice(item_id: String) -> void:
	_close_remix_choice()
	if _hud_layer == null:
		return
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close_remix_choice())
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 26)
	var title := Label.new()
	title.text = String(ItemCatalog.get_def(item_id).get("name", "这个小玩意"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 46)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	title.add_theme_constant_override("outline_size", 8)
	box.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 30)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var place := Button.new()
	place.name = "RemixChoicePlace"
	place.custom_minimum_size = Vector2(240.0, 150.0)
	place.text = "摆到世界"
	UiAssets.style_card_button(place, 24.0)
	place.add_theme_font_size_override("font_size", 40)
	place.pressed.connect(func() -> void:
		_close_remix_choice()
		_begin_placement(item_id))
	var remix := Button.new()
	remix.name = "RemixChoiceRemix"
	remix.custom_minimum_size = Vector2(240.0, 150.0)
	remix.text = "拆开改改"
	UiAssets.style_card_button(remix, 24.0)
	remix.add_theme_font_size_override("font_size", 40)
	remix.pressed.connect(func() -> void:
		_close_remix_choice()
		_begin_remix(item_id))
	row.add_child(place)
	row.add_child(remix)
	box.add_child(row)
	center.add_child(box)
	root.add_child(center)
	_hud_layer.add_child(root)
	_remix_choice = root
	if game_audio != null:
		game_audio.play_sfx("page")

func _close_remix_choice() -> void:
	if _remix_choice != null and is_instance_valid(_remix_choice):
		_remix_choice.queue_free()
	_remix_choice = null

## 进改装：读组合物 spec 预填拼装台、取每槽兼容零件、进拼装视图、列出可改的槽。
func _begin_remix(item_id: String) -> void:
	if not online:
		return
	var spec: Dictionary = ItemCatalog.get_def(item_id).get("spec", {})
	var bp_id := String(spec.get("blueprintId", ""))
	if bp_id.is_empty() or BuildBlueprints.get_blueprint(bp_id).is_empty():
		return # 蓝图对不上（不该发生）：不进改装，别把孩子丢进空视图
	_remixing = true
	_remix_item_id = item_id
	_remix_options = {}
	_remix_stage = "slots"
	_remix_slot = ""
	_creation_goal = "build" # 复用拼装台预览的渲染分派
	_build_blueprint_id = bp_id
	_build_slot = ""
	_build_filled = {}
	for p in spec.get("parts", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var sid := String((p as Dictionary).get("slotId", ""))
		if sid.is_empty():
			continue
		_build_filled[sid] = {
			"partId": String((p as Dictionary).get("partId", "")),
			"partRenderRef": String((p as Dictionary).get("partRenderRef", "")),
		}
	_close_phone()
	backend.send_build_options(world_id, bp_id) # 取每槽兼容零件，回执走 _on_build_options
	_enter_creation_view(true) # is_remix：不进 _in_creation
	_raise_build_preview()
	_update_build_preview() # 预填当前零件（暂不发光）
	if _remix_confirm_btn == null:
		_build_remix_confirm_btn()
	_remix_confirm_btn.visible = true
	_remix_show_slots()

## 「做好了」落成按钮（改装视图专属，挂 _creation_view 底部中央；复用一次建好切显隐）。
func _build_remix_confirm_btn() -> void:
	var btn := Button.new()
	btn.name = "RemixConfirm" # headless 凭这个名字确认改装视图已就绪
	btn.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	btn.offset_left = -140.0
	btn.offset_top = -150.0
	btn.custom_minimum_size = Vector2(280.0, 96.0)
	btn.text = "做好了 ✓"
	UiAssets.style_card_button(btn, 24.0)
	btn.add_theme_font_size_override("font_size", 40)
	btn.pressed.connect(_remix_confirm)
	_creation_view.add_child(btn)
	_remix_confirm_btn = btn

## 兼容零件表到货：缓存 + 若正对着某槽挑零件就刷新零件盘（槽列表的零件名也可能要用它的 label）。
func _on_build_options(data: Dictionary) -> void:
	if not _remixing:
		return
	if String(data.get("blueprintId", "")) != _build_blueprint_id:
		return
	_remix_options = data.get("options", {})
	if _remix_stage == "parts" and not _remix_slot.is_empty():
		_remix_show_parts(_remix_slot)
	else:
		_remix_show_slots()

## 取某槽当前零件的中文名（查兼容零件表 label；查不到回退 partId / 空）。
func _remix_part_label(slot_id: String, part_id: String) -> String:
	if part_id.is_empty():
		return "空"
	for o in _remix_options.get(slot_id, []):
		if typeof(o) == TYPE_DICTIONARY and String((o as Dictionary).get("id", "")) == part_id:
			return String((o as Dictionary).get("label", part_id))
	return part_id

## 槽列表：每个槽一张大卡（显当前零件名），点它进「为这槽挑零件」。当前不发光。
func _remix_show_slots() -> void:
	_remix_stage = "slots"
	_remix_slot = ""
	if _build_preview != null and is_instance_valid(_build_preview):
		_build_preview.set_glow_slot("")
	_creation_q.text = "想改哪一块呀？"
	_creation_q.visible = true
	for c in _creation_cards.get_children():
		c.queue_free()
	for s in BuildBlueprints.slots(_build_blueprint_id):
		var sid := String((s as Dictionary).get("slotId", ""))
		var pid := String((_build_filled.get(sid, {}) as Dictionary).get("partId", ""))
		var card := Button.new()
		card.custom_minimum_size = Vector2(220.0, 168.0)
		card.text = _remix_part_label(sid, pid)
		UiAssets.style_card_button(card, 24.0)
		card.add_theme_font_size_override("font_size", 36)
		card.pressed.connect(_remix_pick_slot.bind(sid))
		_creation_cards.add_child(card)
	if game_audio != null:
		game_audio.play_sfx("page")

## 点了某个槽：点亮它 + 弹出该槽的兼容零件盘（第一张是「返回」不改这槽）。
func _remix_pick_slot(slot_id: String) -> void:
	if not _remixing:
		return
	_remix_stage = "parts"
	_remix_slot = slot_id
	if _build_preview != null and is_instance_valid(_build_preview):
		_build_preview.set_glow_slot(slot_id)
	if game_audio != null:
		game_audio.play_sfx("bell")
	_remix_show_parts(slot_id)

## 某槽的零件盘：返回卡 + 每个兼容零件一张卡，点零件即换（回槽列表）。零件表未到货只显返回卡。
func _remix_show_parts(slot_id: String) -> void:
	_creation_q.text = "换成哪一个呢？"
	for c in _creation_cards.get_children():
		c.queue_free()
	var back := Button.new()
	back.custom_minimum_size = Vector2(220.0, 168.0)
	back.text = "← 返回"
	UiAssets.style_card_button(back, 24.0)
	back.add_theme_font_size_override("font_size", 36)
	back.pressed.connect(_remix_show_slots)
	_creation_cards.add_child(back)
	for o in _remix_options.get(slot_id, []):
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var pid := String((o as Dictionary).get("id", ""))
		if pid.is_empty():
			continue
		var rref := String((o as Dictionary).get("renderRef", "part:" + pid))
		var card := Button.new()
		card.custom_minimum_size = Vector2(220.0, 168.0)
		card.text = String((o as Dictionary).get("label", pid))
		UiAssets.style_card_button(card, 24.0)
		card.add_theme_font_size_override("font_size", 36)
		card.pressed.connect(_remix_swap.bind(slot_id, pid, rref))
		_creation_cards.add_child(card)
	if game_audio != null:
		game_audio.play_sfx("page")

## 换一个零件：更新零件树 + 预览即时坐进新零件，回槽列表可继续改别的。
func _remix_swap(slot_id: String, part_id: String, render_ref: String) -> void:
	if not _remixing:
		return
	_build_filled[slot_id] = { "partId": part_id, "partRenderRef": render_ref }
	_update_build_preview()
	if game_audio != null:
		game_audio.play_sfx("bell")
	_remix_show_slots()

## 做好了：把编辑后的零件树（slotId→partId）直接送去落成新 ItemDef（旧的保留）。收摊改装视图；
## 落成回执走现成 prop_pending(build 分支收拢拼装台) + item_created(进背包/自动摆放)。
func _remix_confirm() -> void:
	if not _remixing or not online:
		return
	var filled := _remix_filled_map()
	if filled.is_empty():
		return
	backend.send_create_build(world_id, _build_blueprint_id, filled)
	_end_remix_locally()
	banner.text = "拼好啦！"
	banner.visible = true

## 改装落成要送的零件树（slotId→partId），从当前编辑态收拢（跳过空槽）。_remix_confirm 与测试共用。
func _remix_filled_map() -> Dictionary:
	var filled := {}
	for sid in _build_filled:
		var pid := String((_build_filled[sid] as Dictionary).get("partId", ""))
		if not pid.is_empty():
			filled[sid] = pid
	return filled

## 收摊改装（做好了/取消/落成回执）：清状态 + 收「做好了」按钮 + 收创造视图 + 收拼装台预览。
func _end_remix_locally() -> void:
	_remixing = false
	_remix_item_id = ""
	_remix_options = {}
	_remix_stage = "slots"
	_remix_slot = ""
	if _remix_confirm_btn != null and is_instance_valid(_remix_confirm_btn):
		_remix_confirm_btn.visible = false
	_hide_creation_cards() # 收创造视图 + 相机复位
	_clear_build_preview() # 收拼装台预览（幂等，prop_pending 也会收一次）

## 服务端判定小朋友说了「算了/不要了」：收创造视图 + 收蛋/炉，并退出对话回到自由跑动
## （老板拍板：取消 = 退出这个状态，别把孩子留在仙子面前干站着）。
func _on_creation_cancelled(data: Dictionary) -> void:
	if _think_timer != null:
		_think_timer.stop()
	_end_creation_locally() # 先清 _in_creation，_exit_interaction 才不会再发一次 creation_cancel
	if selected != null:
		_exit_interaction()
	banner.text = "好呀，那我们不造啦" # 摆在 _exit_interaction 之后：它会先把横幅收掉
	banner.visible = true
	# 仙子把安抚语念出来（幼儿不识字）
	var asset := String(data.get("ttsAsset", ""))
	if not asset.is_empty():
		_play_tts(asset)
	else:
		_speak_line(String(data.get("replyText", "")), String(data.get("voiceId", "")))

## 本地收摊创造态：收视图（相机复位）+ 收占位符 + 关「施法中…」。
## 服务端判的取消（creation_cancelled）与孩子点右上角叉（_on_creation_cancel_pressed）共用。
func _end_creation_locally() -> void:
	_in_creation = false
	_hide_creation_cards()
	_clear_creation_placeholder()
	_clear_build_preview() # 拼装台一并收（服务端判的取消/点右上角叉共用此路径）
	thinking_label.visible = false

## 填充居中 2×2 大卡：图标就绪(iconAsset 非空)显示图标，否则先显示中文 label。点一下即答复小仙子。
func _build_creation_cards(options: Array) -> void:
	for c in _creation_cards.get_children():
		c.queue_free()
	for opt in options:
		if typeof(opt) != TYPE_DICTIONARY:
			continue
		var oid := String((opt as Dictionary).get("id", ""))
		if oid.is_empty():
			continue
		var card := Button.new()
		card.custom_minimum_size = Vector2(220.0, 168.0) # 3 岁友好大点击区
		card.text = String((opt as Dictionary).get("label", oid))
		UiAssets.style_card_button(card, 24.0) # 奶油圆角卡片（die-cut 贴纸风，与图标同调）
		card.add_theme_font_size_override("font_size", 40)
		var icon_asset := String((opt as Dictionary).get("iconAsset", ""))
		if not icon_asset.is_empty():
			_apply_card_icon(card, icon_asset) # 图标就绪：异步贴图（不阻塞卡片弹出）
		else:
			# 打包资源图（build 零件卡带 renderRef 'part:<id>'）：同步取 PackRegistry 贴零件真图。
			# 幼儿不识字——「三角屋顶/平平屋顶」纯文字卡等于让孩子瞎选（实拍抓到的缺口）。
			var rref := String((opt as Dictionary).get("renderRef", ""))
			if rref.begins_with("part:"):
				var part_tex := PackRegistry.load_resource(rref.get_slice(":", 1)) as Texture2D
				if part_tex != null:
					card.icon = part_tex
					card.expand_icon = true
					card.text = "" # 有图就不显字（与造角色卡同策）
		card.pressed.connect(_on_creation_card.bind(oid, card)) # 带上卡片自己：点了要把它扔进蛋/炉
		_creation_cards.add_child(card)
	# 选项卡摆上桌：一记轻「翻纸」声（发牌感），配合仙子随后念问题。空选项（快捷路径）不响。
	if _creation_cards.get_child_count() > 0 and game_audio != null:
		game_audio.play_sfx("page")

## A2 recipient 步的「随便啦」软退出卡：等价于「不答」——走现成 send_creation_reply(optionId='recipient_skip')，
## 服务端回落「给大家」+medium 继续会话，不触发 creation_cancelled（那是「不造了」）。灰底次要样式与选项卡区分。
func _append_recipient_skip_card() -> void:
	var card := Button.new()
	card.custom_minimum_size = Vector2(220.0, 168.0)
	card.text = "随便啦"
	UiAssets.style_card_button(card, 24.0)
	card.add_theme_font_size_override("font_size", 40)
	card.modulate = Color(1, 1, 1, 0.7) # 次要卡：比在场角色/自己/大家淡一点
	card.pressed.connect(_on_creation_card.bind("recipient_skip", card))
	_creation_cards.add_child(card)

## 选项卡图标（生成后 iconAsset 才非空）：异步拉图贴到按钮，失败保留文字兜底。
func _apply_card_icon(card: Button, asset: String) -> void:
	var tex := await api.fetch_texture(asset)
	if tex != null and is_instance_valid(card):
		card.icon = tex
		card.expand_icon = true
		card.text = "" # 有图就不显字

## 点了某张大卡：把这张卡「扔」进蛋/炉，答复小仙子，转「施法中…」等下一轮/成品
## （视图仍留着，等下一个 prompt 或退出）。
func _on_creation_card(option_id: String, card: Button = null) -> void:
	if not _in_creation or selected == null:
		return
	game_audio.play_sfx("bell")
	# 积木拼装：点选权威填当前槽——记 filled + 即时在拼装台把零件坐进槽（THUNK 一下），再等下一轮问句。
	# 服务端同样把 optionId(partId) 坐进 askedSlots.at(-1)（即本轮 _build_slot），两边一致。
	if _creation_goal == "build":
		if not _build_slot.is_empty():
			_build_filled[_build_slot] = {
				"partId": option_id,
				"partRenderRef": String(_build_option_refs.get(option_id, "part:" + option_id)),
			}
		_build_slot = "" # 填完这槽：施法中期间不发光，等下一轮 build_prompt 点亮新槽
		_update_build_preview() # 零件即时显现（THUNK 感由 bell 音效兜住）
		backend.send_creation_reply(world_id, _selected_id(), option_id)
		for c in _creation_cards.get_children():
			c.queue_free()
		_creation_q.text = "拼上啦…"
		return
	if card != null and is_instance_valid(card):
		_throw_into_placeholder(card.global_position, card.size, card.icon, card.text)
	backend.send_creation_reply(world_id, _selected_id(), option_id)
	for c in _creation_cards.get_children():
		c.queue_free()
	_creation_q.text = "施法中…"

# ── 把答案「扔」进占位符 ────────────────────────────────────────────────────
# 3 岁孩子不识字、也不懂「服务端在攒属性」。她只需要看见：我选的那张卡（或我说的那句话）
# 飞进了那颗蛋/那座炉——我的回答被用上了。点选与语音两条路都走这里，视觉一致。

## 本次引导立的占位符 id（造物=魔法熔炉，造贴纸=魔法画板，造角色=降生蛋）。
func _creation_placeholder_id() -> String:
	match _creation_goal:
		"prop": return PLACEHOLDER_FORGE_ID
		"sticker": return PLACEHOLDER_EASEL_ID
		_: return PLACEHOLDER_PORTAL_ID

## 本次引导立的占位符 spec（与 _creation_placeholder_id 同分派）。
func _creation_placeholder_spec() -> Dictionary:
	match _creation_goal:
		"prop": return PlaceholderSpecs.FORGE
		"sticker": return PlaceholderSpecs.EASEL
		_: return PlaceholderSpecs.PORTAL

## 占位符在屏幕上的落点（略高于底座，落在蛋身/炉口上）。没立成/不在视野内返回 INF。
func _placeholder_screen_pos() -> Vector2:
	if camera == null:
		return Vector2.INF
	var node := chunk_manager.dynamic_prop_node(_creation_placeholder_id())
	if node == null:
		return Vector2.INF
	if camera.is_position_behind(node.global_position):
		return Vector2.INF # 转到镜头背后：不做飞行动画，答复照常走
	return camera.unproject_position(node.global_position + Vector3(0.0, 0.7, 0.0))

## 一张「答案卡」从起点飞进占位符：缩小 + 淡出 + 末尾一记白闪；落地时占位符弹一下 + pop 一声。
## 占位符没立成（放不下/离线）就静默跳过——答复照常提交，只是少了这段动画。
func _throw_into_placeholder(from: Vector2, size: Vector2, icon: Texture2D, text: String) -> void:
	var target := _placeholder_screen_pos()
	if target == Vector2.INF or _hud_layer == null:
		return
	var fx := Button.new()
	fx.name = "ThrowFx" # headless 测试凭这个名字确认动画确实起飞了
	# 不用 disabled：那会套上灰掉的 disabled 样式，飞起来像张作废的卡（人眼 QA 抓到过）。
	# 不可点即可：吃不到鼠标、也不抢焦点。
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fx.focus_mode = Control.FOCUS_NONE
	fx.size = size
	fx.pivot_offset = size * 0.5
	fx.global_position = from
	UiAssets.style_card_button(fx, 24.0)
	fx.add_theme_font_size_override("font_size", 40)
	if icon != null:
		fx.icon = icon
		fx.expand_icon = true
	else:
		fx.text = text
	_hud_layer.add_child(fx) # 挂 HUD 层（后加=盖在创造视图之上，且视图收起也不打断飞行）
	var tw := fx.create_tween()
	tw.set_parallel(true)
	# BACK/EASE_IN：先微微后坐再甩出去——「扔」的手感；CUBIC/EASE_IN 前段太慢，看着像卡住不动。
	tw.tween_property(fx, "global_position", target - size * 0.5 * THROW_END_SCALE, THROW_TIME) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_property(fx, "scale", Vector2.ONE * THROW_END_SCALE, THROW_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# 只在末段白闪着消失（被吸进去），前段保持实心可见
	tw.tween_property(fx, "modulate", Color(1.6, 1.6, 1.6, 0.0), THROW_TIME * 0.35).set_delay(THROW_TIME * 0.65)
	tw.chain().tween_callback(func() -> void:
		fx.queue_free()
		_bump_placeholder()
		if _creation_goal == "sticker":
			_paint_splat_at(target) # 造贴纸：答案落到画板上溅一团颜料，「泼颜料」的动感
		if game_audio != null:
			game_audio.play_sfx("pop"))

## 造贴纸落成的 wow 庆祝：屏幕中央撒一把彩纸 + 奖励音效 + 集邮册（手机）按钮脉冲，
## 告诉孩子「做出来啦，收在手机里了」。贴纸不自动落地，庆祝完孩子自己去放置模式贴。
func _celebrate_sticker() -> void:
	if game_audio != null:
		game_audio.play_sfx("fanfare")
		game_audio.play_sfx("bell")
	_pulse_album_button() # 手机按钮脉冲：新贴纸在这儿
	var vp := get_viewport().get_visible_rect().size
	_confetti_burst(Vector2(vp.x * 0.5, vp.y * 0.42))

## 从一点撒出一把彩纸：一圈小色块朝四周飞散 + 边下落边旋转边淡出。纯 HUD 视觉，自清理。
func _confetti_burst(center: Vector2) -> void:
	if _hud_layer == null:
		return
	var colors := [Color("#ff5b7f"), Color("#48c0e8"), Color("#ffc63a"), Color("#7ad06a"), Color("#b49bff"), Color("#ff9a3d")]
	var n := 16
	for i in range(n):
		var piece := ColorRect.new()
		piece.name = "Confetti" # headless 凭这个名字确认撒了彩纸
		piece.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sz := Vector2(14.0, 10.0)
		piece.size = sz
		piece.pivot_offset = sz * 0.5
		piece.color = colors[i % colors.size()]
		piece.global_position = center - sz * 0.5
		piece.rotation = randf() * TAU
		_hud_layer.add_child(piece)
		var ang := TAU * float(i) / float(n) + randf() * 0.4
		var dist := 140.0 + randf() * 120.0
		var dest := center + Vector2(cos(ang), sin(ang)) * dist + Vector2(0.0, 160.0) # 飞散后再落一截
		var tw := piece.create_tween()
		tw.set_parallel(true)
		tw.tween_property(piece, "global_position", dest - sz * 0.5, 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(piece, "rotation", piece.rotation + (randf() - 0.5) * 8.0, 0.9)
		tw.tween_property(piece, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.5).set_delay(0.4)
		tw.chain().tween_callback(piece.queue_free)

## 造贴纸答案落到魔法画板：在落点溅一团亮色颜料（缩放弹出 + 淡出），给「泼颜料」的动感。
## 颜色按答题步数轮换，每轮换一种，画板越答越花。占位符没立成（target 为 INF）时静默跳过。
func _paint_splat_at(screen_pos: Vector2) -> void:
	if _hud_layer == null or screen_pos == Vector2.INF:
		return
	var colors := [Color("#ff5b7f"), Color("#48c0e8"), Color("#ffc63a"), Color("#7ad06a"), Color("#b49bff")]
	var c: Color = colors[_creation_step % colors.size()]
	var sz := Vector2(90.0, 90.0)
	var splat := Panel.new()
	splat.name = "PaintSplat" # headless 凭这个名字确认颜料确实溅了
	splat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	splat.size = sz
	splat.pivot_offset = sz * 0.5
	splat.global_position = screen_pos - sz * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(45) # 圆到底=颜料团
	splat.add_theme_stylebox_override("panel", sb)
	splat.scale = Vector2.ONE * 0.2
	_hud_layer.add_child(splat)
	var tw := splat.create_tween()
	tw.set_parallel(true)
	tw.tween_property(splat, "scale", Vector2.ONE * 1.1, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(splat, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.35).set_delay(0.12)
	tw.chain().tween_callback(splat.queue_free)

## 答案落进去时占位符弹一下（吸收的手感）。区块重刷会换节点，故现取现用。
func _bump_placeholder() -> void:
	var node := chunk_manager.dynamic_prop_node(_creation_placeholder_id())
	if node == null:
		return
	var base := node.scale
	var tw := node.create_tween()
	tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "scale", base * 1.18, 0.12)
	tw.tween_property(node, "scale", base, 0.18)

## 语音答复（说了一句话，不管点没点卡）：从屏幕底部麦克风那儿飞一个小圆卡进去。
## 幼儿不识字，卡上不写字——飞行动作本身就是「你说的话被收下了」。
func _throw_voice_answer() -> void:
	var vp := get_viewport().get_visible_rect().size
	var size := Vector2(120.0, 120.0)
	var from := Vector2(vp.x * 0.5 - size.x * 0.5, vp.y - 190.0) # 麦克风指示器上方
	_throw_into_placeholder(from, size, null, "···")

## 点了右上角的叉：本地立刻收摊（视图/蛋/炉全收）+ 告诉服务端别再等答复 + 退出对话。
## 与服务端语义取消（creation_cancelled）落到同一个状态。
func _on_creation_cancel_pressed() -> void:
	if _remixing:
		_end_remix_locally() # 改装取消：没发 create_build，不扣花、不留半拼预览
		banner.text = "好，先不改啦"
		banner.visible = true
		return
	if not _in_creation:
		return
	if online:
		backend.send_creation_cancel() # 主动上报：清 _in_creation 后 _exit_interaction 不会再发
	_end_creation_locally()
	if selected != null:
		_exit_interaction() # 退出音效由它播
	banner.text = "好呀，那我们不造啦"
	banner.visible = true

## 进度圆点推进：新点亮一个（每答一轮一个）。
func _advance_creation_dots() -> void:
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(14.0, 14.0)
	dot.color = Color(1.0, 0.82, 0.29) # 暖黄=已走到的一步
	_creation_dots.add_child(dot)
	_creation_step += 1

## 收起整个创造视图（答复完成/造好/退出）+ 复位相机特写态。所有退出路径（gen_progress/
## prop_pending/gen_complete/reward_denied/_exit_interaction）都调它，故相机一定会拉回。
func _hide_creation_cards() -> void:
	for c in _creation_cards.get_children():
		c.queue_free()
	for d in _creation_dots.get_children():
		d.queue_free()
	_creation_step = 0
	_creation_options = [] # 引导卡收起：清空选项快照（本轮已答完/退出）
	_creation_cam = false # 松开特写：后续按 _locked（对话两景）或 GOD（已 _exit_interaction）复位
	_layout_voice_wave(false) # 收听 HUD 回到居中底部原尺寸（普通对话没有大卡挡着）
	if _creation_view != null:
		_creation_view.visible = false

## 流式 TTS：character_response 先到，PCM 分片随 tts_chunk 推来，边收边播（首包即出声）。
func _start_tts_stream(rate: int) -> void:
	_tts_stream_pcm = PackedByteArray()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(rate)
	gen.buffer_length = 2.0
	_tts_player.stop()
	_tts_player.stream = gen
	# 先不 play()：进预缓冲态，攒够阈值（或 tts_end 早到）后由 _drain_tts_stream 真正起播，防欠载。
	_tts_gen_playback = null
	_tts_ending = false
	_tts_prebuffering = true
	_tts_prebuffer_bytes = int(float(rate) * 2.0 * TTS_PREBUFFER_SEC) # PCM16 单声道：rate*2 字节/秒

## 攒够预缓冲阈值、或短句 tts_end 已到（总量不足阈值也得播）才起播。
static func _stream_ready_to_play(pcm_bytes: int, prebuffer_bytes: int, ending: bool) -> bool:
	return pcm_bytes >= prebuffer_bytes or ending

func _on_tts_chunk(pcm: PackedByteArray) -> void:
	if _tts_gen_playback != null or _tts_prebuffering:
		_tts_stream_pcm.append_array(pcm)
		_drain_tts_stream()

## 把积压 PCM16 按 generator 剩余空位转成帧推入（每帧 Vector2 双声道同值）。
func _drain_tts_stream() -> void:
	if _tts_prebuffering:
		if not _stream_ready_to_play(_tts_stream_pcm.size(), _tts_prebuffer_bytes, _tts_ending):
			return
		_tts_player.play() # 攒够了才起播：get_stream_playback 必须在 play 之后
		_tts_gen_playback = _tts_player.get_stream_playback()
		_tts_gen_capacity = _tts_gen_playback.get_frames_available() # 刚开播缓冲全空 = 实际容量
		_tts_prebuffering = false
		_mark_tts_out()
	if _tts_gen_playback == null:
		return
	if _tts_stream_pcm.size() < 2:
		# tts_end 已到且积压排空：等 generator 缓冲基本播完（剩余 <0.05s）就主动停，
		# playing 才会变 false——开放麦闭麦判定与小仙子闭嘴判定都依赖它。
		if _tts_ending and _tts_gen_playback.get_frames_available() \
				>= _tts_gen_capacity - int((_tts_player.stream as AudioStreamGenerator).mix_rate * 0.05):
			_tts_player.stop()
			_tts_gen_playback = null
			_tts_ending = false
		return
	var n: int = mini(_tts_gen_playback.get_frames_available(), _tts_stream_pcm.size() / 2)
	if n <= 0:
		return
	var buf := PackedVector2Array()
	buf.resize(n)
	for i in range(n):
		var v: int = (_tts_stream_pcm[i * 2 + 1] << 8) | _tts_stream_pcm[i * 2]
		if v >= 32768:
			v -= 65536
		var sample := float(v) / 32768.0
		buf[i] = Vector2(sample, sample)
	_tts_gen_playback.push_buffer(buf)
	_tts_stream_pcm = _tts_stream_pcm.slice(n * 2)

## 从 audio/L16;rate=N 解析采样率。
func _parse_rate(mime: String, fallback: int) -> int:
	var idx := mime.find("rate=")
	if idx >= 0:
		var parsed := int(mime.substr(idx + 5))
		if parsed > 0:
			return parsed
	return fallback

## 下载 TTS（L16 PCM，采样率随 provider：local Kokoro 24k / 讯飞 16k）→ AudioStreamWAV 播放。
func _play_tts(asset: String) -> void:
	_tts_gen_playback = null # 切回整段路径时停掉流式排空
	_tts_prebuffering = false # 若上一句流还卡在预缓冲态，切整段路径时一并弃掉（每帧 drain 别再起播它）
	_tts_ending = false
	var audio := await api.fetch_audio(asset)
	var bytes := audio["bytes"] as PackedByteArray
	if bytes.is_empty():
		return
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(audio["rate"])
	wav.stereo = false
	wav.data = bytes
	_tts_player.stream = wav
	_tts_player.play()
	_mark_tts_out()

## clientTts 主路径：edge-tts 本地合成优先（≈300ms 整句），失败逐句降级服务端 tts_request。
## pending 期间视同出声（闭麦/压 BGM），防合成空窗漏进角色自己的声音。
func _speak_line(text: String, voice_id: String) -> void:
	if text.strip_edges().is_empty() or voice_id.is_empty():
		return
	_tts_pending = true
	_tts_pending_deadline = Time.get_ticks_msec() / 1000.0 + 8.0
	if edge_tts != null and edge_tts.available:
		var mp3: PackedByteArray = await edge_tts.synthesize(text, EdgeTts.map_voice(voice_id))
		if not mp3.is_empty():
			_play_tts_mp3(mp3)
			_tts_pending = false
			return
		_edge_reprobe_t = EDGE_REPROBE_SEC # 失败进退避，别每句都撞一次 4s 超时
	# 降级：服务端流式合成；tts_start 到达开流并解 pending（见 _on_tts_start），彻底没回音走 deadline 兜底
	backend.send_tts_request(text, voice_id)

func _play_tts_mp3(bytes: PackedByteArray) -> void:
	_tts_gen_playback = null # 切整段路径时停掉流式排空（与 _play_tts 同款复位）
	_tts_prebuffering = false # 同上：edge 整段 mp3 抢占时弃掉未起播的预缓冲流
	_tts_ending = false
	var mp3 := AudioStreamMP3.new()
	mp3.data = bytes
	_tts_player.stream = mp3
	_tts_player.play()
	_mark_tts_out()

func _on_tts_start(mime: String) -> void:
	_tts_pending = false
	_start_tts_stream(_parse_rate(mime, 24000))

## 记本轮首个 TTS 音频起播时刻（三条起播路径共用）。只记玩家发起且尚未记过的一轮，
## 招呼/纯音效等无 character_response 的出声不计入耗时统计。
func _mark_tts_out() -> void:
	if voice_prof_label == null or _vt_response == 0 or _vt_tts_out != 0:
		return
	_vt_tts_out = Time.get_ticks_msec()
	_update_voice_prof()

## 刷新右上角语音耗时浮层。TTS 未出声时该段显“…”。
func _update_voice_prof() -> void:
	if voice_prof_label == null or _vt_speak_start == 0:
		return
	var vad := maxi(0, _vt_speak_end - _vt_speak_start)
	var llm := maxi(0, _vt_response - _vt_send)
	var lines: Array[String] = ["语音耗时(ms)", "VAD %d" % vad]
	lines.append("ASR %d 端侧" % maxi(0, _vt_asr_done - _vt_speak_end)) # 识别只有端侧一条路
	lines.append("LLM %d" % llm)
	if _vt_tts_out != 0:
		lines.append("TTS %d" % maxi(0, _vt_tts_out - _vt_response))
	else:
		lines.append("TTS …")
	voice_prof_label.text = "\n".join(lines)

## edge 探活/退避重探 + pending 兜底超时。available 初始 false，首帧即触发第一次探活。
func _step_edge_tts(delta: float) -> void:
	if _tts_pending and Time.get_ticks_msec() / 1000.0 > _tts_pending_deadline:
		_tts_pending = false # 降级也石沉大海（离线）：放开麦，别把孩子闷住
	if _edge_env_off:
		return # 回测隔离：headless 套件离线约定，不打真网探活
	if edge_tts == null or edge_tts.available:
		return
	_edge_reprobe_t -= delta
	if _edge_reprobe_t <= 0.0:
		_edge_reprobe_t = EDGE_REPROBE_SEC
		edge_tts.probe()

## 情绪气泡：AIGC 表情贴纸（3 岁不识字友好）+ 弹出过冲动画，数秒后淡出。
func _show_emotion(emotion: String) -> void:
	game_audio.play_sfx("pop")
	emotion_bubble.texture = UiAssets.emotion_tex(emotion)
	emotion_bubble.visible = true
	emotion_bubble.modulate = Color.WHITE
	emotion_bubble.scale = Vector3.ONE * 0.4
	_emotion_pop_t = 0.0
	_emotion_life = 4.0

func _update_emotion_bubble(delta: float) -> void:
	if not emotion_bubble.visible:
		return
	if selected == null or not is_instance_valid(selected):
		emotion_bubble.visible = false
		return
	emotion_bubble.global_position = selected.global_position + Vector3(0.0, _char_top(selected) + 1.4, 0.0)
	# 弹出：0.2s 冲到 1.2 过冲，再 0.15s 回落到 1.0
	if _emotion_pop_t >= 0.0:
		_emotion_pop_t += delta
		if _emotion_pop_t < 0.2:
			emotion_bubble.scale = Vector3.ONE * lerpf(0.4, 1.2, _emotion_pop_t / 0.2)
		elif _emotion_pop_t < 0.35:
			emotion_bubble.scale = Vector3.ONE * lerpf(1.2, 1.0, (_emotion_pop_t - 0.2) / 0.15)
		else:
			emotion_bubble.scale = Vector3.ONE
			_emotion_pop_t = -1.0
	# 展示计时：最后 0.5s 淡出后隐藏
	_emotion_life -= delta
	if _emotion_life <= 0.0:
		emotion_bubble.visible = false
	elif _emotion_life < 0.5:
		emotion_bubble.modulate.a = _emotion_life / 0.5

## 思考动画气泡：thinking_label（状态源）可见且有选中角色时，头顶 ·/··/··· 循环冒泡。
func _update_think_bubble(delta: float) -> void:
	var show := thinking_label.visible and selected != null and is_instance_valid(selected)
	_think_bubble.visible = show
	if not show:
		return
	_think_anim_t += delta
	_think_bubble.text = "···".substr(0, 1 + int(_think_anim_t / 0.4) % 3)
	# 轻微上浮呼吸，比静态文本更「活」
	_think_bubble.global_position = selected.global_position \
		+ Vector3(0.0, _char_top(selected) + 1.4 + sin(_think_anim_t * 2.0) * 0.12, 0.0)

## 说话演出：正在出声的角色呼吸弹跳（脚底锚点的纸片挤压拉伸），停止后回正。
## 选中角色吃正式 TTS（_tts_player），小仙子吃预制台词（fairy_voice），其余角色回正。
func _update_speak_anim(delta: float) -> void:
	_speak_anim_t += delta
	var tts_on := selected != null and is_instance_valid(selected) and _tts_player.playing
	var fairy_on := fairy_voice != null and fairy_voice.is_playing()
	# 无人出声且缩放已全部回正：整段跳过（旧版每帧扫仙子+遍历 npcs+分配数组，白跑）
	if not tts_on and not fairy_on and _speak_scales_settled:
		return
	var s := 1.0 + sin(_speak_anim_t * 9.0) * 0.05
	var speaking: Array = []
	if tts_on:
		speaking.append(selected)
	if fairy_on:
		var fairy := _find_fairy()
		if not fairy.is_empty() and not speaking.has(fairy["node"]):
			speaking.append(fairy["node"])
	var settled := speaking.is_empty()
	for n in npcs:
		var node := n["node"] as PaperCharacter
		if not String(n.get("paper_action", "")).is_empty():
			settled = false # 动作层（squish/bounce 等）正在管 scale：说话呼吸让位，别拔河
			continue
		_apply_speak_scale(node, speaking.has(node), s, delta)
		if node.scale != Vector3.ONE:
			settled = false
	_speak_scales_settled = settled

func _apply_speak_scale(node: PaperCharacter, is_speaking: bool, s: float, delta: float) -> void:
	if is_speaking:
		node.scale = Vector3(1.0 / s, s, 1.0) # 变高略变窄：保「体积感」的纸片呼吸
	elif node.scale != Vector3.ONE:
		node.scale = node.scale.lerp(Vector3.ONE, minf(1.0, 12.0 * delta))
		if node.scale.is_equal_approx(Vector3.ONE):
			node.scale = Vector3.ONE

const CHAT_ICONS := ["ic_note", "em_happy", "ic_sparkle", "ic_note", "em_laugh"]  ## NPC 聊天轮流冒的贴纸（去文字化）
const CHAT_ROUND := 1.5  ## 一人一轮的秒数

## NPC 间聊天演出：executor 到达聊天对象旁写 chat_with/chat_t 契约键后，这里接管——
## 叫停对方、双方相互面对、轮流头顶冒符号气泡；CHAT_DUR 走完清键、对方恢复闲逛。
func _update_npc_chats(delta: float) -> void:
	var showing := false
	for n in npcs:
		if not n.has("chat_with"):
			continue
		var partner := _find_chat_partner(String(n["chat_with"]), n)
		if partner.is_empty() or not is_instance_valid(n.get("node")):
			_end_npc_chat(n, partner)
			continue
		partner["in_chat"] = true # 拦住 _step_executors 的「跑完恢复闲逛」，聊完才放
		var t := float(n.get("chat_t", 0.0))
		if t == 0.0:
			# 聊天开局：叫停对方，别聊一半人走了
			for ex in _executors:
				if (ex as BehaviorExecutor).drives(partner):
					(ex as BehaviorExecutor).cancel()
		t += delta
		n["chat_t"] = t
		if t >= BehaviorExecutor.CHAT_DUR:
			_end_npc_chat(n, partner)
			continue
		# 相互面对（paper_face 由动作层每帧收敛到位）
		var dx := WorldGrid.shortest_delta(n["logical"], partner["logical"]).x
		n["paper_face"] = 0.0 if dx > 0.0 else PI
		partner["paper_face"] = 0.0 if dx <= 0.0 else PI
		if showing:
			continue # 气泡只演最先找到的一场（多场并发罕见，其余只做面对）
		showing = true
		var round_i := int(t / CHAT_ROUND)
		var speaker: Dictionary = n if round_i % 2 == 0 else partner
		var node := speaker["node"] as PaperCharacter
		_npc_chat_bubble.texture = UiAssets.tex(CHAT_ICONS[round_i % CHAT_ICONS.size()])
		_npc_chat_bubble.visible = true
		_npc_chat_bubble.global_position = node.global_position \
			+ Vector3(0.0, _char_top(node) + 1.4 + sin(t * 3.0) * 0.1, 0.0)
	if not showing:
		_npc_chat_bubble.visible = false

func _find_chat_partner(id: String, exclude: Dictionary) -> Dictionary:
	for n in npcs:
		if n == exclude:
			continue
		if String(n.get("id", "")) == id or (n["node"] as PaperCharacter).char_name == id:
			return n
	return {}

## 聊天收尾：清契约键；被叫停的对方若闲着（无执行器、不在交互中）恢复闲逛。
func _end_npc_chat(n: Dictionary, partner: Dictionary) -> void:
	n.erase("chat_with")
	n.erase("chat_t")
	if partner.is_empty():
		return
	partner.erase("in_chat")
	if not partner.get("is_fairy", false) \
			and not _has_executor_for(partner) and partner != _stopped \
			and (selected == null or partner.get("node") != selected):
		_start_ambient_wander(partner)

## 从「正在跟孩子说话的角色」身上派发脚本。会让他走开的（去某地/跟随/找人聊/带话，或要跑腿传话），
## 先把这句回应说完再动身、随后关对话（缺陷 ④：此前立刻退出，横幅/相机在他开口前就没了）；
## 留在原地的（do_action/stop_follow）照旧立即执行，对话继续。判定见 InteractionFsm.speaker_leaves。
func _dispatch_from_speaker(npc: PaperCharacter, script: Dictionary, relaying: bool) -> void:
	var dict := _find_npc_dict(npc)
	if InteractionFsm.speaker_leaves(_command_types(script), relaying, dict.get("is_fairy", false)):
		_arm_pending_leave(npc, script)
	else:
		_run_behavior(npc, script)

func _command_types(script: Dictionary) -> Array:
	var types: Array = []
	for c in script.get("commands", []):
		if typeof(c) == TYPE_DICTIONARY:
			types.append(String((c as Dictionary).get("type", "")))
	return types

## 在角色上执行行为脚本（移动等）。新脚本替换该角色进行中的行为（防双执行器同驱）。
func _run_behavior(npc: PaperCharacter, script: Dictionary) -> void:
	var dict := _find_npc_dict(npc)
	if dict.is_empty():
		return
	if dict.get("is_fairy", false):
		return # 小仙子是随从：永远跟着玩家（_update_fairy），不吃移动类行为脚本
	for old in _executors:
		if (old as BehaviorExecutor).drives(dict):
			(old as BehaviorExecutor).cancel()
	var ex := BehaviorExecutor.new()
	ex.setup(dict, script, Callable(self, "_resolve_char_pos"), Callable(self, "_deliver_message"),
		Callable(self, "_resolve_location"), Callable(self, "_relay_command"))
	_executors.append(ex)

## relay_command 到达回调：跑腿的把指令带到了——执行者先点头应答（收到！），再执行脚本。
func _relay_command(target_id: String, script: Dictionary) -> void:
	var node := _find_npc_by_id(target_id)
	if node == null:
		for n in npcs:
			if (n["node"] as PaperCharacter).char_name == target_id:
				node = n["node"]
				break
	if node == null:
		return
	var cmds: Array = [{ "type": "do_action", "params": { "action": "nod" } }]
	cmds.append_array(script.get("commands", []))
	_run_behavior(node, { "commands": cmds, "loop": bool(script.get("loop", false)) })

## 按 id 或名字找角色逻辑坐标（deliver_message/move_to 角色名/follow 用）；
## 「玩家」/player 解析到玩家角色；找不到返回 Vector2.INF。
func _resolve_char_pos(id: String) -> Vector2:
	if not player.is_empty() \
			and (id == PLAYER_ID or id == "玩家" or id == (player["node"] as PaperCharacter).char_name):
		return player["logical"]
	for n in npcs:
		if String(n.get("id", "")) == id or (n["node"] as PaperCharacter).char_name == id:
			return n["logical"]
	return Vector2.INF

## 地点名 → 世界坐标：先精确匹配 POI 名/别名，再互相包含（「大池塘」↔「池塘」）。找不到 INF。
func _resolve_location(loc: String) -> Vector2:
	var q := loc.strip_edges()
	if q.is_empty():
		return Vector2.INF
	for poi in pois:
		for n in _poi_names(poi):
			if n == q:
				return Vector2(poi["tile"]) * float(WorldGrid.TILE_SIZE)
	for poi in pois:
		for n in _poi_names(poi):
			if q.contains(n) or n.contains(q):
				return Vector2(poi["tile"]) * float(WorldGrid.TILE_SIZE)
	return Vector2.INF

func _poi_names(poi: Dictionary) -> Array:
	var names: Array = [String(poi.get("name", ""))]
	names.append_array(poi.get("aliases", []))
	return names.filter(func(n: Variant) -> bool: return not String(n).is_empty())

# ── 舞台协议宿主：StageAgent 的能力执行器（剧本系统，见 stage_agent.gd）────────────
# 完成型命令（走位/动作/念白）在 _step_stage 轮询完成后回调 done→StageAgent 回 ack。

const STAGE_NARRATE_VOICE := "zh-CN-YunxiaNeural" ## 旁白固定用点点音色（奶声小男孩，与预制台词/运行期一致；edge 原生名直通 map_voice）
var _stage_player_actor_id := ""                  ## 本场演出里玩家占的角色 id（stage_begin 从 isPlayer 认定）
var _stage_actor_ids: Array = []                  ## 本场演员 id 表（overview 取全体中心用）

## 舞台运镜态：{} = 不接管（镜头照常跟玩家）；否则 { mode, a, b }，见 stage_camera / _stage_cam_shot。
var _stage_cam: Dictionary = {}
const STAGE_CAM_FOCUS_DIST := 20.0     ## 单人特写：比 god 态 ZOOM_MIN(16) 略远，人在画面中段
const STAGE_CAM_FILL := 0.8            ## 全景构图：演员包围圆的直径占屏中间 80%（留一圈边，别贴着画框演）
const STAGE_RING_NAME := "StageRing"   ## 参演高亮：演员脚下光环的节点名（挂在角色节点下）
const STAGE_RING_COLOR := Color(1.0, 0.84, 0.32, 0.85)
## 光环的世界基：不跟角色转，且把圆环压扁成贴地的一圈（而不是一个甜甜圈）
const STAGE_RING_SQUASH := Vector3(1.0, 0.2, 1.0)
static var STAGE_RING_BASIS := Basis().scaled(STAGE_RING_SQUASH)

## 环面上的中点（纯函数）：不能直接取算术平均——两点跨接缝时会算到地图对面去。
static func torus_midpoint(a: Vector2, b: Vector2) -> Vector2:
	return WorldGrid.wrap_pos(a + WorldGrid.shortest_delta(a, b) * 0.5)

## 环面上一组点的中心（纯函数）：以首点为锚，各点取最短位移后平均，再 wrap 回环面。
static func torus_centroid(points: Array) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	var anchor: Vector2 = points[0]
	var sum := Vector2.ZERO
	for p in points:
		sum += WorldGrid.shortest_delta(anchor, p as Vector2)
	return WorldGrid.wrap_pos(anchor + sum / float(points.size()))

## 全景构图（纯函数）：把这场戏的所有演员框进画面所需的焦点与轨道距离。
## 反算与 compute_dialog_cam 同源——可见世界高 = 2*d*tan(fov/2)，令内容跨度占比 = STAGE_CAM_FILL。
## 内容跨度取「包围圆直径」而非逐人投影：包围圆与相机 yaw 无关，孩子转视角也不会有人被甩出画面
## （代价是演员排成一横排时镜头略宽——全景本就该宽）。地面散布投到屏幕竖直方向被 sin(pitch) 压缩、
## 立绘高度乘 cos(pitch)：漏掉这两个系数会一路顶到 ZOOM_MAX，全景永远拉满。
## 距离夹在 [STAGE_CAM_FOCUS_DIST, ZOOM_MAX]——超出 ZOOM_MAX 的散布本就框不下（更远会露出 chunk 边缘）。
static func compute_overview_cam(points: Array, top_h: float, fov_deg: float, pitch_deg: float) -> Dictionary:
	var center := torus_centroid(points)
	var radius := 0.0
	for p in points:
		# 包围半径必须走环面最短位移：直接相减会把跨接缝的两个邻居算成隔了整张地图
		radius = maxf(radius, WorldGrid.shortest_delta(center, p as Vector2).length())
	var pitch := deg_to_rad(pitch_deg)
	var tanhalf := tan(deg_to_rad(fov_deg * 0.5))
	var span := 2.0 * radius * sin(pitch) + top_h * cos(pitch)
	var dist := span / (2.0 * STAGE_CAM_FILL * tanhalf)
	return { "want": center, "dist": clampf(dist, STAGE_CAM_FOCUS_DIST, ZOOM_MAX), "lift": top_h * 0.5 }

## 舞台运镜：脚本的 camera 命令落到这里。mode=reset 交还镜头给玩家。
func stage_camera(mode: String, a_id: String, b_id: String) -> void:
	if mode == "reset" or mode.is_empty():
		_stage_cam = {}
		return
	_stage_cam = { "mode": mode, "a": a_id, "b": b_id }

## 当前运镜的构图（焦点/距离/抬升）。演员找不到（还没降生/已离场）时返回 {}，镜头维持原样不抽搐。
func _stage_cam_shot() -> Dictionary:
	var mode := String(_stage_cam.get("mode", ""))
	if mode == "overview":
		var pts := _stage_actors_logical()
		if pts.is_empty():
			return {}
		return compute_overview_cam(pts, _stage_actors_top(), camera.fov, _cam_pitch_deg())
	if mode == "focus":
		var d := _stage_actor_dict(String(_stage_cam.get("a", "")))
		if d.is_empty():
			return {}
		return { "want": d["logical"] as Vector2, "dist": STAGE_CAM_FOCUS_DIST, "lift": 0.0 }
	if mode == "dialog":
		var da := _stage_actor_dict(String(_stage_cam.get("a", "")))
		var db := _stage_actor_dict(String(_stage_cam.get("b", "")))
		if da.is_empty() or db.is_empty():
			return {}
		var mid := torus_midpoint(da["logical"] as Vector2, db["logical"] as Vector2)
		# 复用对话构图：两人都在画面里（is_idle 归中，不朝谁偏）
		var h := maxf(_char_top(da["node"] as PaperCharacter), _char_top(db["node"] as PaperCharacter))
		var dc := compute_dialog_cam(mid, mid, h, h, camera.fov, true)
		return { "want": dc["want"], "dist": dc["dist"], "lift": dc["lift"] }
	return {}

## 本场演员的逻辑坐标（还没降生/已离场的跳过）。
func _stage_actors_logical() -> Array:
	var out: Array = []
	for id in _stage_actor_ids:
		var d := _stage_actor_dict(String(id))
		if not d.is_empty():
			out.append(d["logical"] as Vector2)
	return out

## 本场最高演员的立绘高度（全景要让最高的那位也露头）。全员未降生时退回占位高度。
func _stage_actors_top() -> float:
	var top := 0.0
	for id in _stage_actor_ids:
		var d := _stage_actor_dict(String(id))
		if not d.is_empty():
			top = maxf(top, _char_top(d["node"] as PaperCharacter))
	return top if top > 0.0 else PaperCharacter.PLACEHOLDER_HEIGHT

## 开演：进观演态（吞玩家输入），退出当前对话/取消玩家自主移动，认出玩家占哪个角色。
func stage_begin(actors: Array) -> void:
	_stage_active = true
	_stage_player_actor_id = ""
	_stage_actor_ids.clear()
	_stage_cam = {}
	for a in actors:
		_stage_actor_ids.append(String((a as Dictionary).get("id", "")))
		if bool((a as Dictionary).get("isPlayer", false)):
			_stage_player_actor_id = String((a as Dictionary).get("id", ""))
	if selected != null:
		_exit_interaction()
	_cancel_player_move()
	end_guide("") # 开演吞掉玩家输入，他没法再"自己走过去"——引路到此为止（静默，别和开场旁白抢声）
	_stage_stop_ambient()
	_stage_mark_actors(true)
	banner.visible = false

## 开演即停掉参演角色的自主闲逛。_step_executors 在 _stage_active 时已不再补挂闲逛，
## 但降生时挂的那个 loop wander 还活着——不停掉，演员就会在开场旁白和每段对白里各走各的。
func _stage_stop_ambient() -> void:
	for id in _stage_actor_ids:
		var d := _stage_actor_dict(String(id))
		if d.is_empty():
			continue
		for ex in _executors:
			if (ex as BehaviorExecutor).ambient and (ex as BehaviorExecutor).drives(d):
				(ex as BehaviorExecutor).cancel()

## 参演高亮：给演员脚下挂/摘一圈金色光环，孩子一眼看出台上是谁在演。
## 光环挂成角色节点的子节点（与 BlobShadow 同一套寄生法）——他走到哪跟到哪，
## 世界弯曲/走位/浮动原点全都不用管，也就不需要每帧重摆。
## 悬空的小仙子跳过：她脚下没有地，光环会飘在半空。
func _stage_mark_actors(on: bool) -> void:
	for id in _stage_actor_ids:
		var d := _stage_actor_dict(String(id))
		if d.is_empty() or d.get("is_fairy", false):
			continue
		var node := d["node"] as PaperCharacter
		var old := node.get_node_or_null(STAGE_RING_NAME)
		if old != null:
			old.queue_free()
		d.erase("stage_ring")
		if not on:
			continue
		var mi := MeshInstance3D.new()
		mi.name = STAGE_RING_NAME
		var ring := TorusMesh.new()
		# 半径按立绘实际宽度（quad 宽）算，不按身高：光环要比身子宽一圈才看得见——
		# 立绘是竖直纸片，圆环凡是落在身子后面的部分都会被它挡掉，只剩前面一道弧。
		var r := clampf(_char_quad_w(node) * 0.55, 0.8, 2.2)
		ring.outer_radius = r
		ring.inner_radius = r * 0.84
		ring.rings = 32        # 主圆的分段：给少了会画成菱形
		ring.ring_segments = 4 # 截面的分段：反正 _place_char 里要压扁贴地，四段够了
		mi.mesh = ring
		mi.position.y = 0.22 # 抬离 BlobShadow(0.2) 一点，别打架（压扁与保持水平见 _place_char）
		var mat := StandardMaterial3D.new()
		mat.albedo_color = STAGE_RING_COLOR
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = BendMat.CULL_MARGIN # 角色被 CPU 预下压，光环随之位移，防误剔除
		node.add_child(mi)
		d["stage_ring"] = mi # 缓存供 _place_char 每帧摆平（省掉逐帧 get_node_or_null）

## 收场（正常结束/异常终止）：解锁输入，停掉一切舞台驱动的执行器与念白，横幅圆场。
func stage_finish(result: Dictionary, aborted: bool, reason: String) -> void:
	_stage_active = false
	_stage_mark_actors(false) # 摘光环必须赶在 _stage_actor_ids 清空之前——清了就找不到人了
	_stage_player_actor_id = ""
	_stage_actor_ids.clear()
	_stage_cam = {} # 镜头交还玩家（收场后还锁在演员身上，孩子会以为卡死了）
	for m in _stage_drives:
		(m["ex"] as BehaviorExecutor).cancel()
	_stage_drives.clear()
	for ex in _stage_holds:
		(ex as BehaviorExecutor).cancel() # 停掉持续 follow/flee（否则演员收场后还在追/逃）
	_stage_holds.clear()
	# 闲逛恢复要在上面两轮 cancel 之后：演员卸了妆回去自己晃悠，
	# 顺带把演出期间跑完指令、被 _stage_active 挡住没能恢复的路人也一并放回去。
	for n in npcs:
		_resume_ambient(n)
	_stage_speaks.clear() # 未完成念白的回执随收场丢弃（服务端已终场，不再需要 ack）
	for bid in _stage_balls: # C 档球随收场移除（演出道具通道，演完即散）
		var ball: StageBall = _stage_balls[bid]
		if is_instance_valid(ball):
			ball.queue_free()
	_stage_balls.clear()
	if _hud != null:
		_hud.clear() # 移除计分板/倒计时/toast
	if _tts_player != null:
		_tts_player.stop()
	if aborted:
		banner.text = "今天先演到这里啦"
		banner.visible = true
		push_warning("stage aborted: %s" % reason)
	elif not String(result.get("praise", "")).is_empty():
		banner.text = String(result["praise"])
		banner.visible = true

## 走位：解析目标（坐标/角色名/地点名）→ 一次性执行器驱动，到达回 done。
func stage_move(actor_id: String, target: Variant, done: Callable) -> void:
	var dict := _stage_actor_dict(actor_id)
	if dict.is_empty():
		done.call(false, { "error": "找不到演员: %s" % actor_id })
		return
	if dict.get("is_fairy", false):
		done.call(true, {}) # 小仙子随从由 _update_fairy 驱动，不吃移动脚本；视作已到位
		return
	var params := _stage_move_params(target)
	if params.is_empty():
		done.call(false, { "error": "无法解析移动目标" })
		return
	_stage_drive(dict, { "commands": [{ "type": "move_to", "params": params }], "loop": false }, done)

## 动作（wave/jump/spin/nod）：一次性执行器阻塞动作时长，演完回 done。
func stage_action(actor_id: String, action: String, done: Callable) -> void:
	var dict := _stage_actor_dict(actor_id)
	if dict.is_empty():
		if done.is_valid():
			done.call(false, { "error": "找不到演员: %s" % actor_id })
		return
	_stage_drive(dict, { "commands": [{ "type": "do_action", "params": { "action": action } }], "loop": false }, done)

## 说话：用角色自己音色本地合成 TTS（clientTts），可选同时演动作；TTS 播完回 done。
func stage_say(actor_id: String, text: String, action: String, voice_id: String, done: Callable) -> void:
	if not action.is_empty():
		var dict := _stage_actor_dict(actor_id)
		if not dict.is_empty() and not dict.get("is_fairy", false):
			_stage_drive(dict, { "commands": [{ "type": "do_action", "params": { "action": action } }], "loop": false }, Callable())
	_stage_speak(text, voice_id, done)

## 旁白：小仙子音色念白，说完回 done。
func stage_narrate(text: String, done: Callable) -> void:
	_stage_speak(text, STAGE_NARRATE_VOICE, done)

## follow：让某演员持续跟随目标（设置型，即刻生效不卡脚本）。target 为舞台演员 id（玩家归 PLAYER_ID）。
func stage_follow(actor_id: String, target_id: String) -> void:
	var dict := _stage_actor_dict(actor_id)
	if dict.is_empty() or dict.get("is_fairy", false):
		return # 小仙子随从由 _update_fairy 驱动，不吃跟随脚本
	_stage_hold(dict, { "commands": [{ "type": "follow", "params": { "target_id": _stage_resolve_key(target_id) } }], "loop": false })

## flee：让某演员持续逃离目标（设置型）。
func stage_flee(actor_id: String, target_id: String) -> void:
	var dict := _stage_actor_dict(actor_id)
	if dict.is_empty() or dict.get("is_fairy", false):
		return
	_stage_hold(dict, { "commands": [{ "type": "flee", "params": { "target_id": _stage_resolve_key(target_id) } }], "loop": false })

## stop：停掉某演员的一切舞台驱动（follow/flee/走位），原地静止候下一条命令。
func stage_stop(actor_id: String) -> void:
	var dict := _stage_actor_dict(actor_id)
	if dict.is_empty():
		return
	for ex in _executors:
		if (ex as BehaviorExecutor).drives(dict):
			(ex as BehaviorExecutor).cancel()
	_stage_holds = _stage_holds.filter(func(e: BehaviorExecutor) -> bool: return not e.drives(dict))
	_stage_drives = _stage_drives.filter(func(m: Dictionary) -> bool: return not (m["ex"] as BehaviorExecutor).drives(dict))

## 顶部横幅（脚本 stage.banner）。空文本即隐藏。
func stage_banner(text: String) -> void:
	banner.text = text
	banner.visible = not text.strip_edges().is_empty()

## HUD 计分板 / 加分 / 倒计时 / 取消 / toast：委托 HudFactory 渲染（见 hud_factory.gd）。
func stage_hud_score(id: String, label: String) -> void:
	if _hud != null:
		_hud.score(id, label)

func stage_hud_score_add(id: String, n: int) -> void:
	if _hud != null:
		_hud.score_add(id, n)

## 倒计时：服务端起始时戳 + 时长 → 服务端截止，减时间偏移换本地钟（双端读数一致）。
## 无握手（offset=0，剧本必在线故理论不发生）时退化为本地 now 兜底。
func stage_hud_countdown(id: String, sec: int, server_start_ms: int, offset_ms: int) -> void:
	if _hud == null:
		return
	var deadline_ms: int
	if server_start_ms > 0 and offset_ms != 0:
		deadline_ms = server_start_ms + sec * 1000 - offset_ms
	else:
		deadline_ms = Time.get_ticks_msec() + sec * 1000
	_hud.countdown(id, deadline_ms)

func stage_hud_cancel(id: String) -> void:
	if _hud != null:
		_hud.cancel_timer(id)

func stage_hud_toast(text: String) -> void:
	if _hud != null:
		_hud.toast(text)

## 倒计时归零（HudFactory 回调）→ 转 StageAgent 上行 timer 事件。
func _on_stage_timer_done(hud_id: String) -> void:
	if _stage != null:
		_stage.on_timer_done(hud_id)

## 服务端造好 spec 的道具落位（完成型）：near 解析为世界坐标 → 就近落位 → 回 done 带 id。
## 演出道具是纯客户端临时渲染（dynamic prop 通道），演完即散——实体行在服务端 items 表
## 只作定义，不进矩阵不占 tile，无需回报落位。
func stage_prop_spawn(id: String, spec: Dictionary, near: Variant, done: Callable) -> void:
	var anchor := _stage_near_pos(near)
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos(anchor + Vector2(2.0, 1.0)))
	var placed := chunk_manager.add_dynamic_prop(spec, want, randf() * 360.0, _prop_wander(spec), id)
	if placed.x < 0:
		if done.is_valid():
			done.call(false, { "error": "道具没地方放" })
		return
	if done.is_valid():
		done.call(true, { "id": id })

## 已造道具挪位（脚本 prop.place）：先拾起（释放旧位/节点）再按 at 落位。
func stage_prop_place(id: String, at: Variant) -> void:
	var spec: Dictionary = {}
	var picked := chunk_manager.pickup_dynamic_prop(id)
	if not picked.is_empty():
		var node: Node3D = picked.get("node")
		if is_instance_valid(node):
			node.queue_free()
		spec = picked.get("spec_data", {})
	if spec.is_empty():
		return
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos(_stage_near_pos(at)))
	chunk_manager.add_dynamic_prop(spec, want, randf() * 360.0, _prop_wander(spec), id)

## 移除道具（脚本 prop.remove）。
func stage_prop_remove(id: String) -> void:
	var picked := chunk_manager.pickup_dynamic_prop(id)
	if not picked.is_empty():
		var node: Node3D = picked.get("node")
		if is_instance_valid(node):
			node.queue_free()

## C 档球落位（完成型，脚本 stage.spawnBall）：at 解析为世界坐标 → 建 StageBall 节点落位 → 回 done 带 id。
## host 默认所有者、每帧本地模拟（见 _step_stage）；全端都建可见球（球位置像角色一样进复制流，P2c 接）。
## 已存在同 id 则原地复位（幂等）。踢击输入 / 所有权转移 / 非 owner 预测和解见 P2c 与 P3。
func stage_spawn_ball(id: String, at: Variant, done: Callable) -> void:
	if id.is_empty():
		if done.is_valid():
			done.call(false, { "error": "球 id 为空" })
		return
	var pos := WorldGrid.wrap_pos(_stage_near_pos(at))
	var ball: StageBall = _stage_balls.get(id)
	if ball == null or not is_instance_valid(ball):
		ball = StageBall.new()
		add_child(ball)
		_stage_balls[id] = ball
	ball.place_at(pos)
	if done.is_valid():
		done.call(true, { "id": id })

## 球复位（完成型，脚本 ball.reset）：把已存在的球移回落点、清零速度，回 done。找不到球即报错。
func stage_ball_reset(id: String, at: Variant, done: Callable) -> void:
	var ball: StageBall = _stage_balls.get(id)
	if ball == null or not is_instance_valid(ball):
		if done.is_valid():
			done.call(false, { "error": "找不到球: %s" % id })
		return
	ball.place_at(WorldGrid.wrap_pos(_stage_near_pos(at)))
	if done.is_valid():
		done.call(true, {})

## 设置型持续驱动（follow/flee）：替换该演员现有执行器，登记 _stage_holds 供收场统一 cancel。
func _stage_hold(dict: Dictionary, script: Dictionary) -> void:
	for old in _executors:
		if (old as BehaviorExecutor).drives(dict):
			(old as BehaviorExecutor).cancel()
	_stage_holds = _stage_holds.filter(func(e: BehaviorExecutor) -> bool: return not e.drives(dict))
	var ex := BehaviorExecutor.new()
	ex.setup(dict, script, Callable(self, "_resolve_char_pos"), Callable(self, "_deliver_message"),
		Callable(self, "_resolve_location"), Callable(self, "_relay_command"))
	_executors.append(ex)
	_stage_holds.append(ex)

## 舞台演员 id → BehaviorExecutor 可解析的键（玩家占的角色 id 归一到 PLAYER_ID）。
func _stage_resolve_key(actor_id: String) -> String:
	if actor_id == _stage_player_actor_id or actor_id == PLAYER_ID:
		return PLAYER_ID
	return actor_id

## near/at 目标 → 世界坐标：坐标 [x,y] / Tile{x,y} / 演员 id / 地点名；都解析不到用玩家/焦点兜底。
func _stage_near_pos(near: Variant) -> Vector2:
	if near is Array and (near as Array).size() >= 2:
		var a: Array = near
		return WorldGrid.wrap_pos(Vector2(float(a[0]), float(a[1])))
	if near is Dictionary:
		var d: Dictionary = near
		if d.has("x") and d.has("y"):
			return TerrainMap.tile_center(Vector2i(int(d["x"]), int(d["y"])))
	if near is String and not String(near).is_empty():
		var s := String(near)
		var cp := _resolve_char_pos(_stage_resolve_key(s))
		if cp != Vector2.INF:
			return cp
		var lp := _resolve_location(s)
		if lp != Vector2.INF:
			return lp
	return player["logical"] if not player.is_empty() else focus_logical

## actorId → 玩家/村民字典（玩家可占某个角色 id；再按后端 id、名字兜底解析村民）。
func _stage_actor_dict(actor_id: String) -> Dictionary:
	if not player.is_empty() and (actor_id == PLAYER_ID or actor_id == _stage_player_actor_id):
		return player
	for n in npcs:
		if String(n.get("id", "")) == actor_id:
			return n
	for n in npcs:
		if (n["node"] as PaperCharacter).char_name == actor_id:
			return n
	return {}

## 舞台 move 目标 → BehaviorExecutor move_to 参数。target：世界坐标 [x,y] / Tile {x,y}(格) / 角色名 / 地点名。
func _stage_move_params(target: Variant) -> Dictionary:
	if target is Array and (target as Array).size() >= 2:
		var t: Array = target
		return { "target": [float(t[0]), float(t[1])] }
	if target is Dictionary:
		var d: Dictionary = target
		if d.has("x") and d.has("y"):
			return { "tile_x": int(d["x"]), "tile_y": int(d["y"]) }
		if d.has("tileX") and d.has("tileY"):
			return { "tile_x": int(d["tileX"]), "tile_y": int(d["tileY"]) }
	if target is String:
		var s := String(target)
		if _resolve_char_pos(s) != Vector2.INF:
			return { "character_name": s }
		if _resolve_location(s) != Vector2.INF:
			return { "location_name": s }
	return {}

## 一次性执行器驱动某角色（玩家/村民通用）：替换其现有执行器，跑完在 _step_stage 回 done。
func _stage_drive(dict: Dictionary, script: Dictionary, done: Callable) -> void:
	for old in _executors:
		if (old as BehaviorExecutor).drives(dict):
			(old as BehaviorExecutor).cancel()
	var ex := BehaviorExecutor.new()
	ex.setup(dict, script, Callable(self, "_resolve_char_pos"), Callable(self, "_deliver_message"),
		Callable(self, "_resolve_location"), Callable(self, "_relay_command"))
	_executors.append(ex)
	if done.is_valid():
		_stage_drives.append({ "ex": ex, "done": done })

## 舞台念白：本地合成播放。完成检测靠 _step_stage 轮询 TTS 空闲；离线/无回音时用估算时长兜底。
func _stage_speak(text: String, voice_id: String, done: Callable) -> void:
	if text.strip_edges().is_empty() or voice_id.is_empty():
		if done.is_valid():
			done.call(true, {})
		return
	# 故事音包优先（M2 §4.3）：预烧台词精确命中播 WAV（零 TTS、脱网可演、音色在烧制时已定）；
	# miss 回落 clientTts 现场合成。完成轮询同一套（_is_tts_busy 已含 story_voice）。
	if story_voice != null and story_voice.play_line(text):
		var est_pack := clampf(0.22 * float(text.strip_edges().length()), 1.5, 12.0)
		_stage_speaks.append({ "done": done, "deadline": Time.get_ticks_msec() / 1000.0 + est_pack, "started": false })
		return
	_speak_line(text, voice_id) # async：内部 await edge 合成后播放；此处不 await，完成靠轮询
	# 时长兜底（0.22s/字，1.5–12s）：真机 TTS 空闲检测可靠，但 headless dummy 音频 playing 永真，
	# 靠此兜底保证 ack 必达不卡场。
	var est := clampf(0.22 * float(text.strip_edges().length()), 1.5, 12.0)
	_stage_speaks.append({ "done": done, "deadline": Time.get_ticks_msec() / 1000.0 + est, "started": false })

func _is_tts_busy() -> bool:
	return (_tts_player != null and _tts_player.playing) or _tts_pending \
		or (story_voice != null and story_voice.is_playing())

## 舞台完成轮询：走位/动作执行器跑完、念白 TTS 播完（或超时兜底）→ 回 done（StageAgent 据此回 ack）。
func _step_stage(_delta: float) -> void:
	if _hud != null:
		_hud.step(_delta) # 倒计时读数刷新 + 归零触发 + toast 过期（非演出态时无控件，空转极廉价）
	if not _stage_drives.is_empty():
		var still: Array = []
		for m in _stage_drives:
			if (m["ex"] as BehaviorExecutor).is_done():
				var cb: Callable = m["done"]
				if cb.is_valid():
					cb.call(true, {})
			else:
				still.append(m)
		_stage_drives = still
	if not _stage_speaks.is_empty():
		var now := Time.get_ticks_msec() / 1000.0
		var busy := _is_tts_busy()
		var kept: Array = []
		for s in _stage_speaks:
			if busy:
				s["started"] = true # 观测到出声：之后转空闲即算说完
			var idle_done: bool = bool(s["started"]) and not busy
			if idle_done or now >= float(s["deadline"]):
				var cb: Callable = s["done"]
				if cb.is_valid():
					cb.call(true, {})
			else:
				kept.append(s)
		_stage_speaks = kept
	if not _stage_balls.is_empty():
		_step_balls(_delta)

## C 档球逐帧（P2c）：逐球按所有权状态机分谁模拟——
## · 模拟者（中立态 host / 被踢期间踢者本人）：本地推进滚动物理；临时所有者滚停即交回中立并广播。
## · 非模拟者：不跑物理，从复制缓冲 sample（插值/外推）+ reconcile（平滑纠偏）出渲染位置。
## 全端都把最终逻辑坐标渲染到弯曲地面（照 _tap_marker）。
func _step_balls(delta: float) -> void:
	var my_id := backend.player_id if backend != null else ""
	var host := _owns_npcs()
	var render_ms := Time.get_ticks_msec() + _stage_offset()
	for id in _stage_balls:
		var ball: StageBall = _stage_balls[id]
		if not is_instance_valid(ball):
			continue
		var lg: Vector2
		if ball.own.simulates(my_id, host):
			ball.step(delta)
			lg = ball.body.logical
			ball.render_logical = lg # 同步渲染坐标，日后交出所有权时从此处平滑衔接
			# 临时所有者（非中立）滚停 → 交回 host 中立，广播让各端达成所有权共识
			if not ball.own.is_neutral() and not ball.body.is_rolling():
				if ball.own.settle() and online and backend != null and backend.is_online():
					backend.send_ball_settle(world_id, id, lg, render_ms)
		else:
			var target := ball.buf.sample(render_ms, ball.body.logical)
			ball.render_logical = ball.buf.reconcile(ball.render_logical, target, delta)
			lg = ball.render_logical
			ball.body.logical = lg # body 逻辑坐标跟随渲染，交回本端模拟时无跳变
		var d := WorldGrid.shortest_delta(focus_logical, lg)
		var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(lg))) * TerrainMap.STEP_HEIGHT
		_place_on_bent_ground(ball, Vector3(d.x, ty + StageBall.RADIUS, d.y))

## 踢球（C 档，客户端玩家动作触发；实际手势接线＝P3）：本地立即赋速 + 把临时所有权转给自己
## （客户端预测，零延迟），再广播 ball_kick 让同场景他端同步所有权并从此刻接收我的球位置流。
## id 无效 / 无该球 / 零向量 / 非正 power 则忽略。空 player_id（离线未注册）保持中立由 host 模拟。
func stage_ball_kick(id: String, dir: Vector2, power: float) -> void:
	var ball: StageBall = _stage_balls.get(id)
	if ball == null or not is_instance_valid(ball) or dir.is_zero_approx() or power <= 0.0:
		return
	var pid := backend.player_id if backend != null else ""
	ball.own.kick(pid)         # 空 pid → kick 内部不转移，保持中立
	ball.body.kick(dir, power) # 本地预测：立即动
	if online and backend != null and backend.is_online() and not pid.is_empty():
		backend.send_ball_kick(world_id, id, pid, ball.body.logical, ball.body.velocity,
			Time.get_ticks_msec() + _stage_offset())

## 收到他端踢球：只在本端记录所有权转移 + 播种复制缓冲（外推立即起步），不本地跑物理——
## 真正模拟由踢者本人做并广播球位置。发起者自己已本地应用（服务端广播排除自己，pid 判等双保险）。
func _on_ball_kick(data: Dictionary) -> void:
	var id := String(data.get("ballId", ""))
	var pid := String(data.get("playerId", ""))
	if pid.is_empty() or (backend != null and pid == backend.player_id):
		return
	var ball: StageBall = _stage_balls.get(id)
	if ball == null or not is_instance_valid(ball):
		return
	ball.own.kick(pid)
	var pos := Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	var vel := Vector2(float(data.get("vx", 0.0)), float(data.get("vy", 0.0)))
	var t := int(data.get("t", Time.get_ticks_msec() + _stage_offset()))
	ball.buf.push(t, pos, vel, Time.get_ticks_msec())

## 收到他端球滚停：所有权交回 host 中立；最终静止位置播种缓冲让静止收敛。
func _on_ball_settle(data: Dictionary) -> void:
	var id := String(data.get("ballId", ""))
	var ball: StageBall = _stage_balls.get(id)
	if ball == null or not is_instance_valid(ball):
		return
	ball.own.settle()
	var pos := Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	var t := int(data.get("t", Time.get_ticks_msec() + _stage_offset()))
	ball.buf.push(t, pos, Vector2.ZERO, Time.get_ticks_msec())

## 连上 WS 后上报世界地点名清单（POI 规范名），让意图 LLM 把「去某地」归一到真实地名。
func _send_world_info() -> void:
	var names: Array = []
	for poi in pois:
		names.append(String(poi.get("name", "")))
	# 只有建过真角色才带 profile 上报（供服务端首见建玩家档）。没角色时（引导/造角色途中进世界）
	# 传空档 → send_world_info 不带 profile，服务端不会建「无立绘」空玩家（与服务端 world_info
	# handler 的空档拦截同款语义，双端各堵一道）。_scene_id 让服务端回读本场景 playerPos。
	var profile: Dictionary = PlayerProfile.upload_dict() if PlayerProfile.has_character() else {}
	backend.send_world_info(world_id, names, profile, _scene_id)

# ── 奖赏系统：委托状态 / 提示 chip / 完成判定 ──────────────────────────────

## world_info 的回包：同步钱包/背包与进行中委托（断线重连/重启后补状态）。
func _on_world_state(data: Dictionary) -> void:
	_my_voice_id = String(data.get("voiceId", _my_voice_id)) # 自己的稳定音色：喊话复述用
	_apply_wallet(data.get("wallet"))
	_apply_bag(data.get("bag"))
	_set_active_task(data.get("activeTask"))
	_restore_player_pos(data.get("playerPos"))
	# 自己身上的贴纸（boot/重连补回，服务端权威）：记副本 + 挂到玩家节点（真立绘就位后 _apply_player_sprite_to 会按正确尺寸重挂）。
	var atts: Variant = data.get("attachments")
	_my_attachments = atts if typeof(atts) == TYPE_ARRAY else []
	_apply_player_attachments()

## 把玩家搬回上次离开时的 tile。只在引导窗口内生效（_player_restore_pending）：
## 断线重连也会收到 world_state，那时小朋友早已走开，再搬人就是凭空瞬移。
func _restore_player_pos(p: Variant) -> void:
	if not _player_restore_pending:
		return
	_player_restore_pending = false
	if typeof(p) != TYPE_DICTIONARY or player.is_empty():
		return
	var pos: Dictionary = p
	var tile := Vector2i(int(pos.get("tileX", -1)), int(pos.get("tileY", -1)))
	if not WorldGrid.is_valid_tile(tile):
		return
	OccupancyMap.char_unregister(PLAYER_ID)
	var spot := _find_free_spot(WorldGrid.from_tile_center(tile), PLAYER_SPAN)
	player["logical"] = spot
	player["paper_prev"] = spot
	OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)
	focus_logical = spot

## 应用服务端下发的钱包（world_state/task_complete/item_created/gen_complete 各处复用）：更新状态 + 刷 UI。
func _apply_wallet(w: Variant) -> void:
	if typeof(w) == TYPE_DICTIONARY:
		wallet = w
	_reconcile_stamps()
	_refresh_album()

## ── 盖章见证游标（docs/stamp-flower-ux-design.md §3）─────────────────────────
##
## 服务端一收到完成事件就把账算完了，客户端拿到的永远是结算后的钱包。小朋友要「亲手把章
## 盖上去」，就得记住自己见证到哪儿——stamp_seen 落在 profile.json 里，钱包比它多出来的章
## 就是欠盖的，攒着等小朋友打开手机的小红花页，一锤一锤补演。

## 钱包变动后对账：能立刻认的就认（初始送花/admin 补账/别的静默调整），
## 该演的（盖章/开花/摘花）留给小红花页的仪式，这里只亮角标。
func _reconcile_stamps() -> void:
	# 仪式正在演的时候别动游标：这会儿钱包完全可能被别的报文刷新（world_state 重连、别人送
	# 爱心、造物扣费…），此刻认账会把小朋友正在盖的那几个章一把抹掉。仪式演完自己会 snap
	# 到那时最新的钱包（服务端永远权威），不需要这里插手。
	if phone_ui != null and phone_ui.ceremony_playing():
		return
	var beats := StampCeremony.plan(stamp_seen, wallet, _stamp_styles)
	if beats.is_empty():
		_commit_stamp_seen()
		return
	_update_phone_badge()

## 演完了（或无需演出）：见证游标推到服务端权威值并落盘。
func _commit_stamp_seen() -> void:
	stamp_seen = StampCeremony.snapshot(wallet)
	_stamp_styles.clear()
	StampCeremony.save_seen(stamp_seen)
	_update_phone_badge()

## 取在线期间收到的真章款式（task_complete 带来的）。只有「攒的款式数正好等于欠盖的章数」
## 时才用——否则说明中间混进了离线/别处挣的章，序号对不上，宁可整批走确定性兜底也不错位。
func take_stamp_styles() -> Array:
	var pending := StampCeremony.pending_count(stamp_seen, wallet)
	return _stamp_styles.duplicate() if _stamp_styles.size() == pending else []

## 欠章角标：熄屏锁屏上的通知条 + 小红花 app 图标红点（refresh_banner 里按 pending 数刷）。
## 停靠态屏幕是熄的、60s 才低频渲一帧——挣到章得**立刻**在锁屏上看见，所以这里踢一帧重渲，
## 不然小朋友要盯着黑屏等最多一分钟才知道自己有章没盖。
func _update_phone_badge() -> void:
	if phone_ui == null or paper_phone == null:
		return
	phone_ui.refresh_banner()
	if paper_phone.state == PaperPhone.State.DOCKED and paper_phone.visible:
		_phone_dock_t = 60.0
		paper_phone.refresh_dock_screen()

## 只在「换了一个新委托」时出声。character_response 每次带 task 都会调到这里
## （含进行中委托的重申），逐次响就成了噪音。
func _set_active_task(task: Variant) -> void:
	var next: Dictionary = task if typeof(task) == TYPE_DICTIONARY else {}
	var fresh := not next.is_empty() \
			and String(next.get("id", "")) != String(active_task.get("id", ""))
	active_task = next
	if fresh and game_audio != null:
		game_audio.play_sfx("task")
	_update_task_chip()

## chip 里的小图标（mouse_filter=IGNORE：点击穿到容器，整片 chip 一起响应）。
func _chip_icon(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(38.0, 38.0)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

## chip 里的委托人/目标小头像：从已降生的角色节点直接取立绘（动画角色裁第 0 帧）。
## 头像比图标略大、顶对齐立绘的头（KEEP_ASPECT_COVERED + 上裁）——一眼看出是谁。
## 节点不在场（目标在别场景/未降生）返回 null，调用方回落到类型图标。
func _chip_portrait(node: PaperCharacter) -> TextureRect:
	if node == null:
		return null
	var tex := node.portrait_tex()
	if tex == null:
		return null
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	r.custom_minimum_size = Vector2(46.0, 46.0)
	r.clip_contents = true  # COVERED 会溢出裁剪框，clip 掉多余
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

func _chip_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style_label(l, 26)
	return l

## 按名字找已降生的角色节点（deliver/bring 的目标是角色名）。找不到返回 null。
func _find_npc_node_by_name(name: String) -> PaperCharacter:
	if name.is_empty():
		return null
	for n in npcs:
		var node := n["node"] as PaperCharacter
		if node != null and node.char_name == name:
			return node
	return null

## 委托提示 chip（纯图标，去文字——幼儿园孩子不识字）：委托人头像 + 类型图标 + 目标线索 ⇒ 盖章图标。
## 头像直接从已降生的角色节点取立绘（_chip_portrait）；节点不在场（目标在别场景/未降生）回落到类型图标。
## _set_active_task 时重建；点一下整片 chip 让小仙子提醒该怎么做（_on_task_chip_input）。
func _update_task_chip() -> void:
	if task_chip == null:
		return
	for c in task_chip.get_children():
		c.queue_free()
	if active_task.is_empty():
		task_chip.visible = false
		return
	# 委托人头像领头（谁给你的活）——不在场回落到通用目标图标
	var owner := _chip_portrait(_find_npc_by_id(String(active_task.get("npcId", ""))))
	task_chip.add_child(owner if owner != null else _chip_icon(UiAssets.tex("ic_target")))
	match String(active_task.get("type", "")):
		"deliver":
			task_chip.add_child(_chip_icon(UiAssets.tex("ic_chat")))
			_add_chip_target_portrait(String(active_task.get("targetName", "")))
		"bring":
			task_chip.add_child(_chip_icon(UiAssets.tex("ic_handshake")))
			_add_chip_target_portrait(String(active_task.get("targetName", "")))
		"visit":
			task_chip.add_child(_chip_icon(UiAssets.tex("ic_pin"))) # 地点无头像，钉子图标即目标
		"wish":
			# 心愿委托（wishes.ts）：某个村民盼着一样东西，而他自己不会魔法——
			# 魔法棒图标就是给小朋友的线索：这事得找会变魔法的（小仙子）。
			task_chip.add_child(_chip_icon(UiAssets.tex("ic_wand")))
	task_chip.add_child(_chip_label("⇒"))
	task_chip.add_child(_chip_icon(UiAssets.tex(_stamp_icon(String(active_task.get("stampStyle", "star")))))) # 奖励=盖这款集邮章
	task_chip.visible = true

## deliver/bring 的目标是角色：优先放目标头像，节点不在场回落到通用目标图标。
func _add_chip_target_portrait(name: String) -> void:
	var p := _chip_portrait(_find_npc_node_by_name(name))
	task_chip.add_child(p if p != null else _chip_icon(UiAssets.tex("ic_target")))

## 点了委托 chip：让小仙子用自己的话提醒当前委托该怎么做（跑腿提带路/心愿提一起造）。
## 具体走对话通道的实现见 _ask_fairy_about_task（P3）。
func _on_task_chip_input(event: InputEvent) -> void:
	if active_task.is_empty():
		return
	var tapped := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
			or (event is InputEventMouseButton \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
				and (event as InputEventMouseButton).pressed)
	if tapped:
		_ask_fairy_about_task()

## 问小仙子当前委托怎么做：选中点点进对话（复用「点自己=跟点点说话」路径，进对话即开麦），
## 到位后发合成问句走对话通道——点点带 activeTask 上下文回（跑腿提带路/心愿提一起造）。
## 已经在跟点点说话就直接发（approach 对已选中的对象会早返回，不能白点）。
func _ask_fairy_about_task() -> void:
	if active_task.is_empty():
		return
	var fairy := _find_fairy()
	if fairy.is_empty():
		return
	if game_audio != null:
		game_audio.play_sfx("tap")
	if selected == fairy.get("node"):
		_send_task_hint_question() # 已在对话里：直接问
		return
	_pending_task_hint = true # 走过去，_enter_interaction 到位时发问句（而非进场招呼）
	_approach_npc(fairy["node"] as PaperCharacter)

## 发那句「这个任务怎么做呀」给点点走对话通道。麦已由 _enter_interaction 开好，孩子能接着追问，
## 或直接说「不想做了」放弃（服务端识别→taskCleared→撤 chip）。离线/无后端发不了返回 false（回落进场招呼）。
func _send_task_hint_question() -> bool:
	if not online or backend == null or active_task.is_empty():
		return false
	var fairy := _find_fairy()
	if fairy.is_empty():
		return false
	banner.visible = false
	thinking_label.visible = true
	_think_timer.start(THINK_TIMEOUT) # 响应没回来也自动解卡
	_vt_send = Time.get_ticks_msec()
	backend.send_voice_transcript(world_id, String(fairy.get("id", "")), TASK_HINT_QUESTION)
	return true

## 盖章款式 id → 图标名（stamp_<style>，未知款式回退 stamp_star）。
func _stamp_icon(style: String) -> String:
	return "stamp_%s" % style if STAMP_STYLES.has(style) else "stamp_star"

## 委托完成：得 1 个章（服务端已算完账；小红花要小朋友自己打开手机盖满三个章才种得出来）。
## 章的款式先记下来，等他开手机补演时用真款式（离线挣的走确定性兜底，见 take_stamp_styles）。
## 剧情互动委托（M2）：不经 character_response，演出收场服务端直接下发。
## _set_active_task 自带新委托音效与 chip 刷新。
func _on_task_offer(data: Dictionary) -> void:
	if typeof(data.get("task")) == TYPE_DICTIONARY:
		_set_active_task(data["task"])

func _on_task_complete(data: Dictionary) -> void:
	var style := String(data.get("stampStyle", ""))
	if not style.is_empty():
		_stamp_styles.append(style)
	_apply_wallet(data.get("wallet"))
	_apply_bag(data.get("bag")) # 剧情幕奖励带纪念贴纸时随包下发（M2）；无 bag 字段则只刷 UI 无害
	_set_active_task(null)
	if _refine_active:
		_end_refine() # 试用满意/达上限盖章了：收起变大变小箭头 + 指示器
	banner.text = "太棒啦！得到一个新盖章！打开手机盖上去～"
	banner.visible = true
	_celebrate_reward(false, data.get("task", {}))

## 得奖语音表扬（委托人音色）：正在出声就不打断——表扬是锦上添花。
## 老路径服务端合成给 ttsAsset；clientTts 给 text+voiceId 本地合成。
func _on_praise_tts(data: Dictionary) -> void:
	if InteractionFsm.tts_speaking(_fsm_inputs()):
		return
	var asset := String(data.get("ttsAsset", ""))
	if not asset.is_empty():
		_play_tts(asset)
	else:
		_speak_line(String(data.get("text", "")), String(data.get("voiceId", "")))

## 庆祝演出：委托人跳跃+头顶拉炮爆点+小仙子欢呼（预制台词），盖章/小红花飞进左下角手机按钮。
## flower_gained=true 飞小红花（集满升花），否则飞盖章（进度+1）。
func _celebrate_reward(flower_gained: bool, task: Dictionary) -> void:
	var npc := _find_npc_by_id(String(task.get("npcId", "")))
	if npc != null:
		var d := _find_npc_dict(npc)
		if not d.is_empty() and not d.get("is_fairy", false):
			d["paper_action"] = "jump"
			d["paper_action_t"] = 0.0
		_spawn_burst(npc)
	if fairy_voice != null:
		fairy_voice.try_play("reward") # 身边的小仙子先欢呼，1~2 秒后委托人的表扬语音跟上
	if game_audio != null:
		game_audio.play_sfx("enter")
	_fly_reward_to_album("reward_flower" if flower_gained else _stamp_icon(String(task.get("stampStyle", "star"))))

## 拉炮贴纸在角色头顶弹出过冲后淡出（临时 Sprite3D，不占用全局情绪气泡）。
func _spawn_burst(npc: PaperCharacter) -> void:
	var l := UiAssets.bubble_sprite("ic_party", 1.9)
	l.visible = true
	add_child(l)
	l.global_position = npc.global_position + Vector3(0.0, _char_top(npc) + 1.6, 0.0)
	l.scale = Vector3.ONE * 0.3
	var tw := create_tween()
	tw.tween_property(l, "scale", Vector3.ONE * 1.25, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.9)
	tw.tween_property(l, "modulate:a", 0.0, 0.4)
	tw.tween_callback(l.queue_free)

## 奖励图标（盖章/小红花）从屏幕中心飞进手机按钮并缩小，按钮脉冲一下提示「收进手机了」。
func _fly_reward_to_album(icon_id: String) -> void:
	var l := TextureRect.new()
	l.texture = UiAssets.tex(icon_id)
	l.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	l.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	l.size = Vector2(80.0, 80.0)
	_hud_layer.add_child(l)
	var vp := get_viewport().get_visible_rect().size
	l.position = vp * 0.5 - Vector2(40.0, 40.0)
	l.pivot_offset = Vector2(40.0, 40.0)
	var tw := create_tween()
	tw.tween_interval(0.5) # 停一拍让孩子看清得到了什么
	tw.tween_property(l, "position", album_button.global_position + Vector2(12.0, -6.0), 0.7) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(l, "scale", Vector2(0.45, 0.45), 0.7)
	tw.tween_callback(l.queue_free)
	tw.tween_callback(_pulse_album_button)

func _pulse_album_button() -> void:
	# 热区按钮透明：弹的是停靠在那里的 3D 手机本体（提示「收进手机了」）
	if paper_phone == null or paper_phone.state != PaperPhone.State.DOCKED or not paper_phone.visible:
		return
	var base := paper_phone.scale
	var tw := create_tween()
	tw.tween_property(paper_phone, "scale", base * 1.3, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(paper_phone, "scale", base, 0.2)

## 手机开合（点左下角手机按钮切换）：开→3D 手机弹出+遮罩+进近身相机；关→反之。
## 音效挂在这里而非 _open_phone/_close_phone：那两个是幂等内部函数，
## _begin_placement 会调 _close_phone 收起手机，挂进去就会在非用户操作时误响。
func _toggle_album() -> void:
	if game_audio != null:
		game_audio.play_sfx("page")
	if paper_phone.state != PaperPhone.State.DOCKED:
		_close_phone()
	else:
		_open_phone()

## 打开手机：3D 手机贴合相机弹出（正面主屏）+ 全屏遮罩，回主屏、刷新册子/banner，相机进近身。
## 顺带关角色 X 光剪影：手机挡住的角色会把剪影画到手机纸面上（实测穿帮），收起时按画质档还原。
func _open_phone() -> void:
	PaperCharacter.set_xray_enabled(false, get_tree())
	_fit_phone(false)
	phone_ui.set_screen_off(false) # 点亮
	phone_ui.close_app() # 每次打开手机都回到主屏
	phone_ui.refresh_album()
	phone_ui.refresh_banner()
	paper_phone.show_front()
	if _phone_scrim != null:
		_phone_scrim.visible = true
	_enter_phone_cam()

## 收起手机：搬回左下角停靠位 + 遮罩隐藏，相机还原到近身前视角（幂等，未开则不动）。
func _close_phone() -> void:
	if paper_phone == null or paper_phone.state == PaperPhone.State.DOCKED:
		return
	paper_phone.dock()
	phone_ui.set_screen_off(true) # 放回=熄屏；渲一帧黑底后视口彻底停更
	paper_phone.refresh_dock_screen()
	if _phone_scrim != null:
		_phone_scrim.visible = false
	_exit_phone_cam()
	# 还原角色 X 光剪影到当前画质档（开手机时为防剪影画上纸面而临时关掉）
	PaperCharacter.set_xray_enabled(int(_gfx_levels.get("xray", 0)) > 0, get_tree())

## 进近身相机：按玩家身高算 70% 构图参数 + 复位手势偏移（yaw=0，让 +X 焦点偏移把玩家推到屏左）。
func _enter_phone_cam() -> void:
	if _phone_cam:
		return
	_phone_cam = true
	_phone_cam_saved_dist = _target_dist
	_recompute_phone_cam()
	_gest_yaw_t = 0.0
	_gest_pitch_t = 0.0
	_gest_zoom_t = 1.0
	_gest_reset_t = 0.0

## 按玩家立绘高度反算近身参数：距离使玩家占屏高 PHONE_CAM_FILL(≈70%)，
## 焦点右移 _phone_cam_shift 让玩家落屏偏左，抬升 _phone_cam_lift 把玩家框在竖直中段。
func _recompute_phone_cam() -> void:
	var h := 3.2
	if not player.is_empty() and player.get("node") != null:
		h = _char_top(player["node"] as PaperCharacter)
	var tanhalf := tan(deg_to_rad(camera.fov * 0.5))
	var dist := clampf(h / (2.0 * PHONE_CAM_FILL * tanhalf), PHONE_CAM_DIST_MIN, ZOOM_MAX)
	var vp := get_viewport().get_visible_rect().size
	var aspect := (vp.x / vp.y) if vp.y > 1.0 else (1280.0 / 720.0)
	_target_dist = dist
	_phone_cam_shift = PHONE_PLAYER_NDC_X * dist * tanhalf * aspect
	_phone_cam_lift = h * 0.5

## 退近身相机：还原近身前的目标距离（焦点自动回到玩家，见 _process 相机块）。
func _exit_phone_cam() -> void:
	if not _phone_cam:
		return
	_phone_cam = false
	_target_dist = _phone_cam_saved_dist

## 刷新手机册子（钱包/背包驱动的 app 数据；薄壳，内容在 PhoneUi）。
func _refresh_album() -> void:
	if phone_ui != null:
		phone_ui.refresh_album()

## bring/visit 的完成判定（节流轮询）：deliver 在 _enter_interaction 里判（走到目标旁=话带到）。
func _step_task(delta: float) -> void:
	if active_task.is_empty() or not online:
		return
	_task_check_t -= delta
	if _task_check_t > 0.0:
		return
	_task_check_t = 0.5
	match String(active_task.get("type", "")):
		"bring":
			var tp := _resolve_char_pos(String(active_task.get("targetName", "")))
			var owner_node := _find_npc_by_id(String(active_task.get("npcId", "")))
			if tp == Vector2.INF or owner_node == null:
				return
			var od := _find_npc_dict(owner_node)
			if not od.is_empty() and WorldGrid.shortest_delta(tp, od["logical"]).length() <= BRING_DONE_DIST:
				backend.send_task_event(world_id, "bring_done", { "targetName": active_task.get("targetName", "") })
				_task_check_t = 3.0 # 等服务端确认，防连发
		"visit":
			var lp := _resolve_location(String(active_task.get("locationName", "")))
			if lp != Vector2.INF and not player.is_empty() \
					and WorldGrid.shortest_delta(player["logical"], lp).length() <= VISIT_DONE_DIST:
				backend.send_task_event(world_id, "visit_done", { "locationName": active_task.get("locationName", "") })
				_task_check_t = 3.0

## deliver 委托：小朋友亲自走到目标角色旁开始对话 = 话带到了。
func _check_deliver_task(npc: PaperCharacter) -> void:
	if active_task.is_empty() or not online or String(active_task.get("type", "")) != "deliver":
		return
	var want := String(active_task.get("targetName", ""))
	var got := npc.char_name
	if got == want or got.contains(want) or want.contains(got):
		backend.send_task_event(world_id, "deliver_done", { "targetName": got })

## deliver_message 用：角色把话带到目标处时回调，目标显示气泡 + 横幅。
func _deliver_message(target_id: String, message: String) -> void:
	for n in npcs:
		if String(n.get("id", "")) == target_id or (n["node"] as PaperCharacter).char_name == target_id:
			var name := (n["node"] as PaperCharacter).char_name
			banner.text = "%s 收到啦：%s" % [name, message]
			banner.visible = true
			return

func _find_npc_dict(npc: PaperCharacter) -> Dictionary:
	for n in npcs:
		if n["node"] == npc:
			return n
	# 玩家喊话态：_locked 可能是远端玩家副本（对话构图取 logical/身高同一套逻辑）
	for id in _remote_actors:
		if (_remote_actors[id] as Dictionary).get("node") == npc:
			return _remote_actors[id]
	return {}

func _find_npc_by_id(id: String) -> PaperCharacter:
	if id.is_empty():
		return null
	for n in npcs:
		if String(n.get("id", "")) == id:
			return n["node"]
	return null

func _selected_id() -> String:
	if selected == null:
		return ""
	var d := _find_npc_dict(selected)
	var id := String(d.get("id", ""))
	return id if not id.is_empty() else selected.char_name
