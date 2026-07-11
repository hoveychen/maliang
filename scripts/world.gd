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
const CREATION_CAM_DIST := 8.5    ## 创造视图特写：推近仙子单人（比双人对话更近，背景弱化）
const CREATION_CAM_SHIFT := 3.0   ## 焦点右移量：让仙子渲染到屏幕偏左，右侧留给 2×2 大卡
const SPEAK_SHIFT := 0.35         ## 说话人跟随：焦点朝说话方偏移的比例（0=两人中点，1=完全对准说话方）
const SPEAK_ZOOM_BLEND := 0.45    ## 说话人跟随：轨道距离朝「说话方单独占 50%」混合的比例（小体型→距离更近→zoom 更多）
const PICK_RADIUS_PX := 80.0
const THINK_TIMEOUT := 40.0       ## 「思考中」最长等待秒数；超时(响应丢失/网络/TLS)自动清除，杜绝永久卡死
const UNMUTE_GRACE := 0.3         ## 闭麦（思考/TTS）结束后的静默恢复期：残响尾音不算开口
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
const FAIRY_HEIGHT := 1.5         ## 小仙子立绘世界高度（头部大小的随从，时之笛式）
const FAIRY_HOVER := 2.4          ## 小仙子悬浮基准高度（米，脚底离地）
const FOG_DEPTH_BEGIN := 40.0     ## 深度雾起点（焦点在平地时；随 _cur_focus_y 整体补偿）
const FOG_DEPTH_END := 95.0       ## 小世界(span 150)：~95 外渐隐进天空，藏住远端循环，保留无限地平线感
const SKY_HORIZON_COLOR := Color(0.76, 0.89, 0.98) ## 天空地平线色 = 雾色（远地渐隐进天空的无缝衔接）；泛白淡蓝（Pokopia 式低对比）
const SKY_ZENITH_COLOR := Color(0.46, 0.69, 0.95)  ## 天顶色（可见天空带上缘的深一档蓝）；粉彩淡蓝
const SKY_WIND := Vector2(0.006, 0.0015)           ## 云漂移速度（uv/秒），非零 = 天空是动的
# 纸片动作演出（_update_paper_motion）
const WALK_SWAY_DEG := 6.0   ## 走路左右摇摆角（度，绕脚底 roll）
const WALK_SWAY_HZ := 2.6    ## 摇摆频率（步频感）
const WALK_FLUTTER := 0.10   ## 走路下摆飘动幅度（米，paper shader 行波）
const IDLE_CURL := 0.045     ## 待机呼吸微卷幅度（米，左右边缘向 Z）
const FLIP_SPEED := 10.0     ## 翻面角速度（rad/s，~0.3s 完成一次转身翻面）
const FACE_MOVE_EPS := 0.5   ## 认定横向移动的最小速度（米/秒），防原地抖动换面
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
var _gfx_buttons := {}              ## 画质开关按钮 {key: Button}（设置页；toggled → 应用 + 存档）
var _locked: PaperCharacter = null ## lock 跟随的角色（null=god 自由模式）
var _stage_player_logical := Vector2.ZERO ## 对话玩家站位（小跳落点）
var _hop_from := Vector2.ZERO      ## 小跳起点 logical
var _hop_t := -1.0                 ## 玩家小跳已播秒数（<0=不在跳，见 _step_hop）
var camera: Camera3D
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
var _vt_send := 0         ## 发 voice_transcript（端侧）/ voice_end（服务端）
var _vt_response := 0     ## character_response 到达
var _vt_tts_out := 0      ## 本轮首个 TTS 音频起播
var _vt_local := false    ## 本轮是否端侧 ASR（决定 ASR/LLM 拆分口径）
var banner: Label
var heard_label: Label   ## 顶部显示 ASR 识别到的文字（"听到：…"，给家长确认）

var critter_tex: Texture2D
var npcs: Array = []              ## [{ node:PaperCharacter, logical:Vector2 }]
var player: Dictionary = {}       ## 玩家角色 { node, logical, id, span }；不进 npcs（拾取/对话只对 NPC）
var selected: PaperCharacter = null
var voice_wave: Control            ## 底部收听 HUD（AIGC 边框贴图 + 声波柱，近身对话期间显示，见 _update_voice_wave）
var _wave_bars: Array = []         ## voice_wave 里的一排 ColorRect 柱子
var _wave_t := 0.0
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

# M2 语音交互（近身开放麦：无按钮，VAD 自动断句，见 _step_voice）
var backend: Backend
var _vad: VoiceVad = null          ## 近身对话期间非 null：端点检测器（进交互创建，退出置空）
var _unmute_t := 0.0               ## 闭麦恢复期剩余秒数（UNMUTE_GRACE 倒计时）
var thinking_label: Label          ## 思考状态源+家长可读小字（幼儿看角色头顶的 _think_bubble 动画）
var _think_timer: Timer            ## 「思考中」兜底超时（响应没回来时自动解卡）
var _think_bubble: Label3D         ## 思考动画气泡：选中角色头顶 ·/··/··· 循环冒泡（不识字友好）
var _think_anim_t := 0.0           ## 思考气泡动画相位
var emotion_bubble: Sprite3D       ## 角色头顶情绪贴纸气泡（AIGC em_*，见 _show_emotion）
var _npc_chat_bubble: Sprite3D     ## NPC 间聊天轮流气泡（同一时刻只演一场，见 _update_npc_chats）
var _emotion_pop_t := -1.0         ## 情绪弹出动画已播秒数（<0 = 不在弹出中）
var _emotion_life := 0.0           ## 情绪气泡剩余展示秒数（尾段淡出后隐藏）
var _speak_anim_t := 0.0           ## 说话呼吸弹跳相位
var _speak_scales_settled := true  ## 所有角色缩放已回正（_update_speak_anim 空转早退用）
var _recording := false
var _os_name := OS.get_name()       ## 平台名（headless 测试可覆盖成 "Android" 验端侧门禁）
var _vad_log := false               ## 录音诊断 logcat（仅 debug）：VAD 收尾原因/阈值/静音累计
var _vad_log_accum := 0.0           ## 录音期周期打点节流（每 1s 一行）
# 空识别退避（缺陷 ①）：误触发录到近静音 → ASR 返回空 → 若立刻重开麦就会被噪声再触发，
# 形成连环录。空结果不再当一轮正常结束，而是闭麦退避一段（连续空则指数退避，见 InteractionFsm）。
var _empty_streak := 0              ## 连续空识别次数（拿到有效转写即清零）
var _cooldown_t := 0.0              ## 退避剩余秒数（>0 即闭麦，派生为 COOLDOWN 态）
# 「说完再走」（缺陷 ④）：leave 指令先挂起，等回应说完再动身 + 关对话。
# { npc, script, seen, arm, deadline }；空 = 没有挂起的离开。
var _pending_leave: Dictionary = {}
# 奖赏系统：进行中委托 + 小红花钱包（服务端权威，world_state/task_complete 同步；见 docs/reward-flower-design.md）
var active_task: Dictionary = {}   ## 进行中委托（空=无），见 _set_active_task
var wallet: Dictionary = { "flowers": 0, "stampProgress": 0, "stampsTotal": 0 } ## 小红花钱包
var task_chip: HBoxContainer       ## 右上角委托提示（目标图标+短名 ⇒ 盖章奖励图标）
# 专门的「创造视图」（造角色/造物共用）：一进创造就退出普通对话构图，相机推近仙子特写、
# 背景压暗，屏幕中央弹 2×2 大图标卡（方案 A）。平时隐藏。
var _creation_view: Control        ## 创造视图根（全屏暗底 + 居中大卡；吃掉卡外点击）
var _creation_cards: GridContainer ## 居中 2×2 大图标卡网格
var _creation_q: Label             ## 顶部问题字幕（语音为主，字给家长）
var _creation_dots: HBoxContainer  ## 顶部进度圆点（每答一轮点亮一个）
var _creation_step := 0            ## 已走过的轮数（点亮的圆点数）
var _creation_cam := false         ## 创造视图相机特写态（推近仙子；退出创造复位）
var _in_creation := false          ## 正在引导式创造（造角色或造物；期间语音/点选都是这次会话的答复）
var _task_check_t := 0.0           ## bring/visit 完成判定的节流计时
var _hud_layer: CanvasLayer        ## HUD 层（奖励飞入动画等临时控件挂这里）
var album_button: Button           ## 左下角手机启动器按钮（AIGC 手机图标）
var album_panel: PanelContainer    ## 手机面板：小红花/集邮、物品、设置分页
var _flower_cells: Array = []      ## 小红花 app 的 3×3 花格（9 个 TextureRect，按 flowers 点亮）
var _stamp_dots: Array = []        ## 集邮盖章进度点（STAMPS_PER_FLOWER 个，按 stampProgress 点亮）
var _stamps_total_label: Label     ## 集邮 app 累计盖章数展示
# 物品系统：语音造物的物件可摆可收，收集册物品页列出收进背包的（服务端权威，state 同步）
var world_props: Dictionary = {}   ## 语音物件 id → { "spec", "state"(placed/bagged), "tile"(Array|null) }
var _album_pages: Dictionary = {}  ## "stickers"/"items"/"settings" → Control（app 页面，挂进手机屏幕）
# —— 手机 HUD：左下角手机菜单，点开在 HUD 里弹「手机壳 + iPhone 式屏幕」——
# 通用换壳管线：手机皮肤 id → 启动器图标/手机壳资产；以后小朋友解锁新手机只需加一项并切
# _phone_skin，资产缺失时回退程序化占位（先搭结构、AIGC 出图后落盘替换）。默认小仙子专属。
## 手机皮肤 id → 资产。有壳图时机身宽高比 + 屏区都从壳贴图「自动检测」（见 _detect_shell_screen_insets），
## 换任何新手机壳只要丢一张图、无需手调几何；屏幕透明、内容直接画在壳自带屏区上。
const PHONE_SKINS := {
	"fairy": { "launcher": "ic_phone_fairy", "shell": "phone_shell_fairy" },
}
var _phone_skin := "fairy"          ## 当前手机皮肤 id
const PHONE_TARGET_H := 660.0        ## 有壳图时机身目标高度（<720 视口；宽按壳宽高比推）
## 屏幕上的 app（前三格实装，其余留白）：[id, 短名, 图标资产]。图标资产缺失回退现有图标占位。
const PHONE_APPS := [
	["flowers", "小红花", "app_flowers"],
	["items", "物品", "app_items"],
	["settings", "设置", "app_settings"],
]
## app 图标占位：AIGC 专属图标未落盘前，先借现有风格一致的图标顶上。
const PHONE_APP_FALLBACK := { "flowers": "reward_flower", "items": "ic_gift", "settings": "ic_gear" }
## 小红花经济常量（与 server/src/types.ts 对齐）。
const MAX_FLOWERS := 9              ## 小红花上限（3×3 格）
const STAMPS_PER_FLOWER := 3        ## 每满 3 章换 1 朵花
## 盖章款式 id（与 server STAMP_STYLES 对齐）→ 图标 stamp_<style>（AIGC 集邮章）。
const STAMP_STYLES := ["star", "smile", "paw", "medal", "heart"]
const PHONE_GRID_COLS := 3          ## 主屏图标网格列数（3x3）
const PHONE_PAGE_SLOTS := 9         ## 每页图标格数（3x3）
const PHONE_HEIGHT_RATIO := 0.9     ## 机身高占视口比（贴右侧、竖向居中）
const PHONE_RIGHT_MARGIN := 24.0    ## 机身距屏幕右边距
## 手机近身相机：开手机时按玩家立绘高度反算距离，让玩家（自适应身高）占屏高约 70%，
## 并把焦点右移，使玩家落在屏幕偏左、右侧留给手机（PHONE_PLAYER_NDC_X 方向若反了取负）。
const PHONE_CAM_FILL := 0.70        ## 玩家立绘占屏高约 70%（按 _char_top 反算距离，自适应身高）
const PHONE_CAM_DIST_MIN := 3.5     ## 近身距离下限（比对话态更近，撑到 70%）
const PHONE_PLAYER_NDC_X := 0.30    ## 玩家横向落点（0=正中，0.30=中心偏左 30%），右侧留给手机
## 可玩时间预算（桌面 widget 用饼图展示剩余；超时冷却）：默认每轮 45 分钟、冷却 10 分钟，循环。
const PLAY_BUDGET_SEC := 2700       ## 每轮可玩时长（45 分钟）
const PLAY_COOLDOWN_SEC := 600      ## 超时冷却时长（10 分钟）
var _phone_screen: Control          ## 屏幕内容区（banner + 主页网格 + app 视图）
var _phone_home: Control            ## 主页：桌面 widget + 3x3 图标分页
var _phone_app_view: Control        ## 打开某个 app 后的视图（顶部返回条 + 页面宿主）
var _phone_app_host: Control        ## app 页面挂载点（复用 _album_pages 的页面）
var _phone_app_title: Label         ## 打开的 app 标题
var _phone_clock: Label             ## 状态栏时钟（实时）
var _phone_signal: Control          ## 状态栏信号格（绿=WS 在线、灰=离线，见 _update_phone_banner）
var _phone_playpie: PlayTimePie     ## 桌面 widget 可玩时间饼图（闹钟+饼，剩余可玩时间可视化）
var _phone_flowers: Label           ## 桌面 widget 小红花数（代笔占位，见 _red_flower_count）
var _phone_open_app := ""           ## 当前打开的 app id（空=停在主页）
var _phone_ui_t := 0.0              ## banner 刷新节流计时
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
var _phone_pager: ScrollContainer   ## 主屏图标分页横滚容器（iPhone 式左右翻页）
var _phone_pages_box: HBoxContainer ## 各页并排（每页宽=分页容器宽）
var _phone_dots: HBoxContainer      ## 翻页圆点指示（>1 页才显示）
var _phone_page := 0                ## 当前页
var _phone_page_w := 0.0            ## 单页宽（=分页容器宽，翻页/贴合用）
var _phone_pager_dragging := false  ## 正在拖拽分页（松手后贴合到最近页）
var _reroll_confirm: HBoxContainer ## 设置页"重新捏角色"的 ✓/✗ 确认行（防小手误触）
var _avatar_btn: Button            ## 设置页"换形象"按钮（生成中禁用防连点）
var _avatar_preview: VBoxContainer ## 换形象预览区（新形象图 + ✓/✗），平时隐藏
var _avatar_img: TextureRect       ## 预览图
var _avatar_hash := ""             ## 待确认的新形象资产 hash（✓ 才落档案）
var _items_grid: GridContainer     ## 物品页网格（bagged 物件动态重建）
var _items_empty: Label            ## 物品页空态提示
const PROP_LONG_PRESS := 0.6       ## 长按拾起阈值（秒），期间手指基本不动
const PROP_DRAG_LIFT := 1.0        ## 拖拽中物件抬离地面的高度（「拎起来了」）
var _prop_press_id := ""           ## 按下时指下的语音物件 id（长按候选，滑动/抬指取消）
var _prop_press_t := 0.0           ## 长按累计秒
var _prop_drag: Dictionary = {}    ## 拖拽中 { id, spec_data, yaw, wander, node, screen, tile, origin }
const BRING_DONE_DIST := 4.5       ## 带人：目标与委托人相邻半径
const VISIT_DONE_DIST := 14.0      ## 探访：玩家到地点中心半径（POI 中心可能不可达，如池塘水面）
var _executors: Array = []        ## 活跃的 BehaviorExecutor
var _stage: StageAgent            ## 舞台协议大脑（剧本系统，见 stage_agent.gd）；_setup_backend 接线
var _hud: HudFactory              ## 舞台 HUD 工厂（计分/倒计时/toast，见 hud_factory.gd）；_setup_hud 建
var _stage_active := false        ## 观演/游戏态：期间吞玩家输入，StageAgent 全权调度演出
var _stage_drives: Array = []     ## 进行中的完成型舞台命令 { ex:BehaviorExecutor, done:Callable }
var _stage_holds: Array = []      ## 设置型持续驱动的执行器（follow/flee）：收场统一 cancel（永不自完成）
var _stage_speaks: Array = []     ## 进行中的舞台念白 { done:Callable, deadline:float, started:bool }
var _fairy_drift_t := 0.0         ## 小仙子漂移/浮动相位
var fairy_voice: FairyVoice       ## 预制台词播放器（构建期 TTS，运行期零调用）
var game_audio: GameAudio         ## BGM + 音效（语音/思考时自动 duck）
var _fairy_bubble: Sprite3D       ## 小仙子说话时的音符气泡（AIGC ic_note）
var _fairy_greeted := false       ## 每次启动只问候一次
var _fairy_chat_t := 3.0          ## 下一次闲聊倒计时（首次 ~3s 内问候）
var _fairy_poi: Dictionary = {}   ## 进行中的 POI 提醒 { point, trigger, spoke, hold }
var _poi_check_t := 6.0           ## POI 扫描倒计时（每 2s 一次，开局先安静一会）

## 默认地形的兴趣点：池塘 / 北部主峰 / 东南瞭望丘风车 / 西南沼泽小潭。
## 发现半径内且台词未冷却时，小仙子飞过去提醒（台词冷却 180s 天然防重复唠叨）。
## name/aliases：语音指令「去某地」的地点名解析（名字与小仙子台词一致，见 _resolve_location）。
const POIS := [
	{ "tile": Vector2i(24, 24), "radius": 20.0, "trigger": "poi_pond", "name": "池塘", "aliases": ["湖", "水边", "河边"] },
	{ "tile": Vector2i(31, 7), "radius": 22.0, "trigger": "poi_mountain", "name": "大山", "aliases": ["山", "高山", "山顶"] },
	{ "tile": Vector2i(59, 54), "radius": 20.0, "trigger": "poi_windmill", "name": "风车", "aliases": ["大风车", "风车山"] },
	{ "tile": Vector2i(13, 50), "radius": 18.0, "trigger": "poi_marsh", "name": "小水潭", "aliases": ["水潭", "树林", "小树林"] },
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
var _player_executor: BehaviorExecutor = null ## 玩家当前移动指令（新点击即替换）
var _approach: Dictionary = {}    ## 正在跑向的目标 NPC 字典（到旁边后进近身视图）
var _stopped: Dictionary = {}     ## 被叫停等玩家的 NPC 字典（退出交互恢复闲逛）
var world_id := ""

# M2-real 在线
var api: Api
var online := false
var _villager_count := 0          ## 村民散开序号（避免堆叠在中心）

# 音频 I/O（真机：麦克风采集 + TTS 播放）
var _mic: MicRecorder
var _tts_player: AudioStreamPlayer
# 边录边传：录音时持续把采集到的 PCM 攒成小块发给后端（上传与说话重叠）
var _pending_pcm := PackedByteArray()
var _chunk_accum := 0.0   ## 距上次发分片的累计秒数
var _asr_local: Object = null # 端侧 ASR 插件（Android MaliangAsr），null = 服务端识别
var _local_asr_session := false # 本次录音走端侧（录音开始时定格，中途不切换）
# 流式 TTS：tts_chunk 分片先积压再按 generator 空位排空（_drain_tts_stream）
var _tts_stream_pcm := PackedByteArray()
var _tts_gen_playback: AudioStreamGeneratorPlayback = null
var _tts_ending := false  ## 已收到 tts_end：积压排空+缓冲播完后主动 stop（generator 不会自己停）
var _tts_gen_capacity := 0 ## generator 空缓冲容量（开播时实测，播完判定的基准）
# clientTts：edge-tts 本地合成（设计见 docs/edge-tts-client-design.md）
var edge_tts: EdgeTts
var _tts_pending := false ## 本地合成/降级请求进行中：视同「角色在说话」（闭麦/压 BGM/相机），防 300ms 空窗漏麦
var _tts_pending_deadline := 0.0 ## pending 兜底超时（降级也石沉大海时放开麦）
var _edge_reprobe_t := 0.0 ## edge 失败后的重探倒计时
@onready var _edge_env_off := OS.get_environment("MALIANG_EDGE_TTS") == "0" ## 回测隔离开关（进程级不变，缓存免每帧 getenv 系统调用）
const EDGE_REPROBE_SEC := 60.0

func _ready() -> void:
	_vad_log = OS.is_debug_build() # 录音诊断日志：仅 debug 构建吐 logcat
	critter_tex = load("res://assets/critter.png")
	_setup_local_asr()
	_setup_environment()
	chunk_manager = ChunkManager.new()
	chunk_manager.name = "ChunkManager"
	add_child(chunk_manager)
	_setup_camera()
	_setup_npcs()
	_setup_player()
	_setup_fairy_offline()
	_setup_hud()
	# 哨兵对：括住整棵树的 _process 跨度（见 ProcProf 注释）
	add_child(ProcProf.Sentinel.make(true))
	add_child(ProcProf.Sentinel.make(false))
	# 移动端 T1 默认档：3D 降采样 0.7（像素填充率是关阴影后的第二堵墙；HUD/UI 走
	# canvas 仍原生分辨率），随后 AdaptiveQuality 按实测帧时自动升/降档并持久化
	if OS.has_feature("mobile"):
		get_viewport().scaling_3d_scale = 0.7
		# 用户在画质设置里显式存过档就不自动定档（用户接管，免自适应覆盖其 override）
		if not FileAccess.file_exists("user://perf_sweep") and not GraphicsSettings.has_saved():
			add_child(AdaptiveQuality.make(self, chunk_manager))
	# 画质档启动恢复：在自适应/默认之后应用用户 override（节点已就绪：_sun/chunk_manager/_gfx_buttons）
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
	_bootstrap() # 在线引导（best-effort，离线则保留占位 NPC）
	_watch_world_ready() # 首屏铺完+引导结束→发 world_ready（loading.gd 据此淡出）

func _setup_audio() -> void:
	# 麦克风采集抽到 MicRecorder（与 onboarding 共用）；TTS 播放器保留在本场景
	_mic = MicRecorder.new()
	_mic.name = "MicRecorder"
	add_child(_mic)
	_tts_player = AudioStreamPlayer.new()
	add_child(_tts_player)
	edge_tts = EdgeTts.new()
	edge_tts.name = "EdgeTts"
	add_child(edge_tts) # 探活由 _step_edge_tts 首帧触发（available 初始 false）
	game_audio = GameAudio.new()
	game_audio.name = "GameAudio"
	add_child(game_audio)
	game_audio.start_bgm() # 三段渐进 loop 轮换，随机起播（每次进世界大概率不同首）

func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	_sun = light
	light.rotation_degrees = Vector3(-55.0, -40.0, 0.0)
	light.light_color = Color(1.0, 0.96, 0.86) # 暖阳（Pokopia 式午后柔光）
	light.light_energy = 1.25
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
	add_child(light)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = _make_day_sky()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# 暖白环境光抬亮阴影（低对比高亮度）：暗部不发蓝灰、留一点暖调
	env.ambient_light_color = Color(0.85, 0.86, 0.81)
	env.ambient_light_energy = 0.72
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

## 幂等应用单个画质开关（设置页 toggle 与启动恢复共用）。self 就是 world，直接够到
## 太阳灯 / chunk_manager / 环境。键定义见 GraphicsSettings。
func _apply_graphics_key(key: String, on: bool) -> void:
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
		"hi_res":  # 3D 原生分辨率 vs 0.7 降采样（与 AdaptiveQuality 同一旋钮）
			get_viewport().scaling_3d_scale = 1.0 if on else 0.7
		"fog":  # 深度雾
			if _env != null:
				_env.fog_enabled = on
		"outline":  # SDF 物件描边 pass
			SdfProp.set_outline_enabled(on, get_tree())
		"prop_anim":  # 会动的 SDF 物件显/隐
			chunk_manager.set_props_shown(on)

## 读画质档并逐项应用（启动恢复用；只在用户显式存过时 override 自适应定档）。
func _apply_saved_graphics() -> void:
	if not GraphicsSettings.has_saved():
		return
	var g := GraphicsSettings.load_all()
	for key in GraphicsSettings.KEYS:
		_apply_graphics_key(key, bool(g[key]))

## 设置页画质开关切换：即时应用到场景 + 把当前全部按钮态存进 profile（重启恢复）。
func _on_graphics_toggled(on: bool, key: String) -> void:
	_apply_graphics_key(key, on)
	var settings := {}
	for k: String in _gfx_buttons:
		settings[k] = (_gfx_buttons[k] as Button).button_pressed
	GraphicsSettings.save_all(settings)

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

func _setup_npcs() -> void:
	var defs := [
		{ "logical": Vector2(10.0, -10.0), "color": Color(0.62, 0.80, 1.0), "name": "小蓝" },
		{ "logical": Vector2(-11.0, -9.0), "color": Color(0.70, 1.0, 0.62), "name": "小绿" },
		{ "logical": Vector2(1.0, -18.0), "color": Color(1.0, 0.82, 0.5), "name": "小黄" },
	]
	for d in defs:
		var npc := PaperCharacter.new()
		add_child(npc)
		npc.setup(critter_tex, d["color"], d["name"])
		var lg := WorldGrid.wrap_pos(d["logical"])
		npcs.append({ "node": npc, "logical": lg, "id": "demo_%s" % d["name"] })
		OccupancyMap.char_register("demo_%s" % d["name"], lg, 2)
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
func _apply_player_sprite() -> void:
	var asset := String(PlayerProfile.load_profile().get("sprite_asset", ""))
	if asset.is_empty() or player.is_empty():
		return
	var tex := await api.fetch_texture(asset)
	if tex == null or player.is_empty():
		return
	var node := player["node"] as PaperCharacter
	node.texture = tex
	# 生成图按高度归一化到 5 单位（小朋友比 6 单位的村民略矮），脚底对齐
	node.pixel_size = 5.0 / float(tex.get_height())
	node.offset = Vector2(0.0, float(tex.get_height()) / 2.0)
	node.modulate = Color.WHITE
	BlobShadow.attach(node, clampf(float(tex.get_width()) * node.pixel_size * 0.38, 0.4, 1.4))
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
			var atlas := await api.fetch_texture(String(rec.get("animAsset", "")))
			if atlas != null and is_instance_valid(node):
				node.play_idle(atlas, meta, world_height, phase)
			return
		if status == "failed":
			return
		if budget <= 0.0:
			return
		await get_tree().create_timer(wait).timeout
		budget -= wait
		wait = minf(wait * 2.0, 12.0)

## 离线模式的小仙子随从（在线时 _bootstrap 会清掉、换成服务端小神仙）。
## 悬浮飞行：不登记占用图、不走寻路，由 _update_fairy 驱动跟随玩家。
func _setup_fairy_offline() -> void:
	var tex: Texture2D = load("res://assets/fairy.png")
	var node := PaperCharacter.new()
	add_child(node)
	node.setup(tex, Color.WHITE, "小神仙")
	node.pixel_size = FAIRY_HEIGHT / float(tex.get_height())
	BlobShadow.detach(node) # 悬浮飞行不落地，脚下暗斑穿帮
	node.wants_ground_shadow = false  # 切「角色实时阴影」刷新时别给悬浮角色挂脚下 blob
	var spawn := WorldGrid.wrap_pos(player["logical"] + Vector2(3.0, 2.0))
	npcs.append({ "node": node, "logical": spawn, "id": "fairy_local", "is_fairy": true, "hover": FAIRY_HOVER })
	fairy_voice = FairyVoice.new()
	fairy_voice.name = "FairyVoice"
	add_child(fairy_voice)
	_fairy_bubble = UiAssets.bubble_sprite("ic_note", 1.4)
	add_child(_fairy_bubble)

## 小仙子随从每帧驱动：悬浮漂移跟在玩家旁（玩家跑动时拖尾追赶，静止时缓慢环绕），
## 轻微上下浮动。永远由这里驱动，不吃行为脚本（见 _run_behavior）。
func _update_fairy(delta: float) -> void:
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
	if _fairy_poi.is_empty():
		_fairy_ambient(delta, fairy)
	else:
		_update_fairy_bubble(fairy) # 飞行提醒中也要挂音符气泡
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

## 周期扫描 POI：玩家进入发现半径且对应台词未冷却 → 小仙子朝 POI 方向飞（距玩家封顶，
## 保持在视野内）。交互/录音/思考/TTS 中不打扰。
func _check_poi(delta: float) -> void:
	if not _fairy_poi.is_empty() or fairy_voice == null:
		return
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
		return
	_fairy_chat_t -= delta
	if _fairy_chat_t > 0.0:
		return
	_fairy_chat_t = randf_range(15.0, 25.0)
	if not _fairy_greeted:
		_fairy_greeted = fairy_voice.try_play("greet")
		return
	fairy_voice.try_play(_ambient_trigger())

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

	# 收听 HUD：近身对话期间浮在横幅上方——AIGC 生成的奶油圆角边框贴图（hud_listen，
	# 麦克风+音波+星饰烤进边框），一排珊瑚色声波柱嵌在边框空心内板、随音量跳动，
	# 给不识字的小朋友一个又大又清楚的「现在在听你说话」提示。
	var hud_h := WAVE_HUD_W * WAVE_HUD_ASPECT
	voice_wave = Control.new()
	voice_wave.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	voice_wave.offset_left = -WAVE_HUD_W * 0.5
	voice_wave.offset_right = WAVE_HUD_W * 0.5
	voice_wave.offset_top = -104.0 - hud_h
	voice_wave.offset_bottom = -104.0
	voice_wave.mouse_filter = Control.MOUSE_FILTER_IGNORE
	voice_wave.visible = false
	layer.add_child(voice_wave)
	# AIGC 边框贴图：整块填满 voice_wave，等比铺满
	var frame := TextureRect.new()
	frame.texture = UiAssets.tex("hud_listen")
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	voice_wave.add_child(frame)
	# 声波柱：锚在 HUD 竖直中心，居中一排排在边框空心内板，底边对齐、只向上长
	var bar_w := 12.0
	var gap := 8.0
	for i in WAVE_BARS:
		var bar := ColorRect.new()
		bar.color = Color(0.96, 0.5, 0.36) # 珊瑚色：与边框描边同调、内板上高对比
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.anchor_left = 0.5
		bar.anchor_right = 0.5
		bar.anchor_top = 0.5
		bar.anchor_bottom = 0.5
		var xoff := (float(i) - float(WAVE_BARS - 1) * 0.5) * (bar_w + gap)
		bar.offset_left = xoff - bar_w * 0.5
		bar.offset_right = xoff + bar_w * 0.5
		bar.offset_bottom = WAVE_BASE_Y
		bar.offset_top = WAVE_BASE_Y - WAVE_MIN_H
		voice_wave.add_child(bar)
		_wave_bars.append(bar)

	# 左下角手机菜单：一台竖屏手机（比旧书本按钮更大更好点），点开在 HUD 里弹手机壳+屏幕。
	album_button = Button.new()
	album_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	album_button.offset_left = 20.0
	album_button.offset_top = -168.0
	album_button.offset_right = 128.0
	album_button.offset_bottom = -20.0
	album_button.pressed.connect(_toggle_album)
	_style_phone_launcher(album_button)
	layer.add_child(album_button)

	# 手机开着时的全屏透明遮罩：点手机外的任何位置→收起手机（吞掉该点击，不当世界移动指令）。
	# 先于机身入层，机身后入 → 机身盖在遮罩之上；机身区域点击照常给机身，机身外给遮罩。
	_phone_scrim = Control.new()
	_phone_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_phone_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_phone_scrim.visible = false
	_phone_scrim.gui_input.connect(_on_phone_scrim_input)
	layer.add_child(_phone_scrim)

	# ── 手机机身：竖屏，贴屏幕右侧、竖向居中、高约 90% 视口；有 AIGC 手机壳资产用图，否则程序化占位 ──
	album_panel = PanelContainer.new()
	album_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	album_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN # 从右锚点向左长
	album_panel.grow_vertical = Control.GROW_DIRECTION_BOTH     # 竖向居中
	album_panel.offset_right = -PHONE_RIGHT_MARGIN
	album_panel.visible = false
	var skin: Dictionary = PHONE_SKINS.get(_phone_skin, {})
	var has_shell := _apply_phone_shell(album_panel)
	# 机身尺寸 + 屏区：有壳图时全部从壳贴图自动推导——宽高比按像素、屏幕区域按中心检测，
	# 换任何新手机壳零手调；占位机身用竖屏近似 + 奶油屏。
	# 机身高 = 视口高 * 90%，并以 PHONE_TARGET_H 兜底（仅在极小/headless 视口时兜底触发，
	# 平板上 90% 永远大于兜底）；宽按壳/占位宽高比推，贴合右侧。
	var vp_h := float(get_viewport().get_visible_rect().size.y)
	var ph := maxf(vp_h * PHONE_HEIGHT_RATIO, PHONE_TARGET_H)
	var aspect := 360.0 / 660.0 # 占位机身竖屏宽高比（无壳图时）
	var ins := { "l": 0.0, "t": 0.0, "r": 0.0, "b": 0.0 }
	if has_shell:
		var shell_tex := UiAssets.tex(String(skin.get("shell", "")))
		var img: Image = shell_tex.get_image() if shell_tex != null else null
		if img != null and img.get_width() > 8 and img.get_height() > 8:
			aspect = float(img.get_width()) / float(img.get_height())
			ins = _detect_shell_screen_insets(img)
		else:
			has_shell = false # 拿不到像素→退回占位机身
	var pw := ph * aspect
	album_panel.custom_minimum_size = Vector2(pw, ph)
	# bezel：有壳图→贴合自动检测出的屏区，让机身+蜻蜓翼当边框露出；占位机身→小边距。
	var bezel := MarginContainer.new()
	if has_shell:
		bezel.add_theme_constant_override("margin_left", int(pw * float(ins["l"])))
		bezel.add_theme_constant_override("margin_right", int(pw * float(ins["r"])))
		bezel.add_theme_constant_override("margin_top", int(ph * float(ins["t"])))
		bezel.add_theme_constant_override("margin_bottom", int(ph * float(ins["b"])))
	else:
		bezel.add_theme_constant_override("margin_left", 18)
		bezel.add_theme_constant_override("margin_right", 18)
		bezel.add_theme_constant_override("margin_top", 30)
		bezel.add_theme_constant_override("margin_bottom", 34)
	album_panel.add_child(bezel)
	# 屏幕：占位机身用奶油圆角底；有壳图则透明，内容直接画在壳自带的屏区上。
	var screen := PanelContainer.new()
	if has_shell:
		screen.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	else:
		var screen_style := UiAssets.card_style(22.0, 1.0)
		screen_style.shadow_size = 0
		screen.add_theme_stylebox_override("panel", screen_style)
	bezel.add_child(screen)
	_phone_screen = screen
	var screen_pad := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		screen_pad.add_theme_constant_override(side, 8 if has_shell else 16)
	screen.add_child(screen_pad)
	var screen_vbox := VBoxContainer.new()
	screen_vbox.add_theme_constant_override("separation", 12)
	screen_pad.add_child(screen_vbox)
	# —— 顶部状态栏（极简 iPhone 式）：当前时间（左）+ 信号格（右，绿=WS 在线 / 灰=离线）——
	# 已玩时长、小红花不在状态栏，改到主屏桌面 widget（见 _build_phone_widget）。
	var banner_bar := HBoxContainer.new()
	banner_bar.add_theme_constant_override("separation", 6)
	_phone_clock = Label.new()
	_style_card_label(_phone_clock, 20)
	_phone_clock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	banner_bar.add_child(_phone_clock)
	_phone_signal = _make_signal_indicator()
	banner_bar.add_child(_phone_signal)
	screen_vbox.add_child(banner_bar)
	screen_vbox.add_child(HSeparator.new())
	# banner 下方内容套一层竖向滚动：内容超出屏区时滚动，绝不把手机壳撑大（横向须自适应贴合）。
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen_vbox.add_child(scroll)
	var scroll_inner := VBoxContainer.new()
	scroll_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(scroll_inner)
	# —— 主屏：桌面 widget（整条卡片：已玩时长 + 小红花）+ 3x3 图标分页（iPhone 式左右翻页）——
	_phone_home = VBoxContainer.new()
	_phone_home.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_phone_home.add_theme_constant_override("separation", 14)
	scroll_inner.add_child(_phone_home)
	_phone_home.add_child(_build_phone_widget())
	# 图标分页：横向 ScrollContainer，内含并排的页（每页一个 3x3 网格）；拖拽翻页、松手贴合、圆点指示。
	_phone_pager = ScrollContainer.new()
	_phone_pager.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_phone_pager.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_phone_pager.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phone_pager.get_h_scroll_bar().modulate = Color(1.0, 1.0, 1.0, 0.0) # 藏横向滚动条（iPhone 无条）
	_phone_pager.gui_input.connect(_on_phone_pager_input)
	_phone_home.add_child(_phone_pager)
	_phone_pages_box = HBoxContainer.new()
	_phone_pages_box.add_theme_constant_override("separation", 0)
	_phone_pager.add_child(_phone_pages_box)
	_build_phone_pages()
	# 翻页圆点（>1 页才显示）
	_phone_dots = HBoxContainer.new()
	_phone_dots.alignment = BoxContainer.ALIGNMENT_CENTER
	_phone_dots.add_theme_constant_override("separation", 8)
	_phone_home.add_child(_phone_dots)
	_rebuild_phone_dots()
	# —— 打开某个 app 后的视图：顶部返回条 + 页面宿主（页面即原贴纸/物品/设置面板）——
	_phone_app_view = VBoxContainer.new()
	_phone_app_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_phone_app_view.add_theme_constant_override("separation", 12)
	_phone_app_view.visible = false
	scroll_inner.add_child(_phone_app_view)
	var app_bar := HBoxContainer.new()
	app_bar.add_theme_constant_override("separation", 8)
	var back_btn := Button.new()
	back_btn.text = "返回"
	back_btn.add_theme_font_size_override("font_size", 20)
	UiAssets.style_card_button(back_btn)
	# 包一层：_close_phone_app 也被 _open_phone 内部调用（每次开手机回主屏），直连会误响。
	back_btn.pressed.connect(func() -> void:
		if game_audio != null:
			game_audio.play_sfx("exit")
		_close_phone_app())
	app_bar.add_child(back_btn)
	_phone_app_title = Label.new()
	_style_card_label(_phone_app_title, 24)
	_phone_app_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phone_app_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	app_bar.add_child(_phone_app_title)
	var app_bar_spacer := Control.new() # 让标题视觉居中（右侧留一块与返回键等宽的空）
	app_bar_spacer.custom_minimum_size = Vector2(48.0, 0.0)
	app_bar.add_child(app_bar_spacer)
	_phone_app_view.add_child(app_bar)
	_phone_app_host = VBoxContainer.new()
	_phone_app_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_phone_app_view.add_child(_phone_app_host)
	# ── 小红花/集邮 app 页面：3×3 花格 + 一排盖章进度点 + 累计盖章数（_refresh_album 刷新）──
	var flowers_page := _build_flowers_page()
	# 物品页：收进背包的语音物件（动态重建），空态给一句提示
	var items_page := VBoxContainer.new()
	items_page.alignment = BoxContainer.ALIGNMENT_CENTER
	_items_grid = GridContainer.new()
	_items_grid.columns = 4
	_items_grid.add_theme_constant_override("h_separation", 8)
	_items_grid.add_theme_constant_override("v_separation", 8)
	_items_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_items_empty = Label.new()
	_items_empty.text = "还没有收起来的物品"
	_items_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_items_empty.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY # 窄屏区不撑宽，自动换行
	_items_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_card_label(_items_empty, 24)
	items_page.add_child(_items_grid)
	items_page.add_child(_items_empty)
	# 设置页：重新捏角色（回童话书重新自我介绍；onboarding 合并保存档案，贴纸/物品不丢）
	var settings_page := VBoxContainer.new()
	settings_page.alignment = BoxContainer.ALIGNMENT_CENTER
	settings_page.add_theme_constant_override("separation", 16)
	var reroll := Button.new()
	reroll.text = "重新捏角色"
	reroll.icon = UiAssets.tex("ic_retry")
	reroll.add_theme_constant_override("icon_max_width", 36)
	reroll.add_theme_font_size_override("font_size", 26)
	UiAssets.style_card_button(reroll)
	reroll.pressed.connect(_on_reroll_pressed)
	settings_page.add_child(reroll)
	_reroll_confirm = HBoxContainer.new()
	_reroll_confirm.alignment = BoxContainer.ALIGNMENT_CENTER
	_reroll_confirm.add_theme_constant_override("separation", 12)
	_reroll_confirm.add_child(UiAssets.icon_rect("ic_question", 48.0))
	var reroll_yes := UiAssets.icon_button("ic_yes", 52.0)
	reroll_yes.pressed.connect(_on_reroll_yes)
	_reroll_confirm.add_child(reroll_yes)
	var reroll_no := UiAssets.icon_button("ic_no", 52.0)
	reroll_no.pressed.connect(_on_reroll_no)
	_reroll_confirm.add_child(reroll_no)
	_reroll_confirm.visible = false
	settings_page.add_child(_reroll_confirm)
	# 换形象：免翻书只重生成形象图（名字/称呼不动），预览满意才落档案
	_avatar_btn = Button.new()
	_avatar_btn.text = "换形象"
	_avatar_btn.icon = UiAssets.tex("ic_wand")
	_avatar_btn.add_theme_constant_override("icon_max_width", 36)
	_avatar_btn.add_theme_font_size_override("font_size", 26)
	UiAssets.style_card_button(_avatar_btn)
	_avatar_btn.pressed.connect(_on_avatar_regen_pressed)
	settings_page.add_child(_avatar_btn)
	_avatar_preview = VBoxContainer.new()
	_avatar_preview.alignment = BoxContainer.ALIGNMENT_CENTER
	_avatar_preview.add_theme_constant_override("separation", 12)
	_avatar_img = TextureRect.new()
	_avatar_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar_img.custom_minimum_size = Vector2(160.0, 160.0)
	_avatar_img.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_avatar_preview.add_child(_avatar_img)
	var avatar_row := HBoxContainer.new()
	avatar_row.alignment = BoxContainer.ALIGNMENT_CENTER
	avatar_row.add_theme_constant_override("separation", 16)
	var avatar_yes := UiAssets.icon_button("ic_yes", 52.0)
	avatar_yes.pressed.connect(_on_avatar_regen_yes)
	avatar_row.add_child(avatar_yes)
	var avatar_no := UiAssets.icon_button("ic_no", 52.0)
	avatar_no.pressed.connect(_on_avatar_regen_no)
	avatar_row.add_child(avatar_no)
	_avatar_preview.add_child(avatar_row)
	_avatar_preview.visible = false
	settings_page.add_child(_avatar_preview)
	# —— 画质分区：GraphicsSettings 的 6 个开关，toggle 即时应用 + 存 profile（重启恢复）——
	# 内容区自带竖向滚动（scroll），多加几行不撑破手机壳。
	var gfx_title := Label.new()
	gfx_title.text = "画质"
	gfx_title.add_theme_font_size_override("font_size", 26)
	gfx_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	settings_page.add_child(gfx_title)
	var gfx_labels := {
		"actor_shadows": "角色阴影", "ground_shadows": "地面阴影", "hi_res": "高清画质",
		"fog": "远景雾", "outline": "描边", "prop_anim": "会动物件",
	}
	var gfx_now := GraphicsSettings.load_all()
	_gfx_buttons = {}
	for key: String in GraphicsSettings.KEYS:
		var b := Button.new()
		b.text = String(gfx_labels[key])
		b.toggle_mode = true  # 按下=开（style_card_button 给 pressed 态上暖黄底）
		b.button_pressed = bool(gfx_now[key])
		b.add_theme_font_size_override("font_size", 24)
		UiAssets.style_card_button(b)
		b.toggled.connect(_on_graphics_toggled.bind(key))
		settings_page.add_child(b)
		_gfx_buttons[key] = b
	_album_pages = { "flowers": flowers_page, "items": items_page, "settings": settings_page }
	for pid in _album_pages:
		var pg := _album_pages[pid] as Control
		pg.visible = false
		_phone_app_host.add_child(pg)
	layer.add_child(album_panel)
	_close_phone_app() # 初始停在主屏
	_update_phone_banner()

	# 进行中委托的提示 chip（右上角，图标为主：目标 ⇒ 奖励贴纸，_update_task_chip 重建）
	task_chip = HBoxContainer.new()
	task_chip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	task_chip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	task_chip.offset_right = -16.0
	task_chip.offset_top = 12.0
	task_chip.alignment = BoxContainer.ALIGNMENT_END
	task_chip.add_theme_constant_override("separation", 8)
	task_chip.visible = false
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

## 奶油卡片内的文字：暖棕、无黑描边（描边是叠在 3D 世界上的文字用的）。
func _style_card_label(l: Label, size: int) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", UiAssets.CARD_TEXT)

## 左下角手机启动器外观：有当前皮肤的 AIGC 手机图标就用图标（透明底），否则程序化画一台
## 竖屏手机占位（深色圆角机身 + 奶油屏幕 + home 点），等专属图标落盘后自动切图。换皮可重复调。
func _style_phone_launcher(b: Button) -> void:
	for c in b.get_children():
		c.queue_free()
	var skin: Dictionary = PHONE_SKINS.get(_phone_skin, {})
	var art := UiAssets.tex(String(skin.get("launcher", "")))
	if art != null:
		b.icon = art
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.flat = true
		for st in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		return
	# —— 程序化占位手机（AIGC 手机图标落盘前顶上）——
	b.icon = null
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.16, 0.16, 0.20)
	body.set_corner_radius_all(24)
	body.set_border_width_all(3)
	body.border_color = Color(0.32, 0.32, 0.40)
	body.shadow_color = Color(0.20, 0.14, 0.06, 0.35)
	body.shadow_size = 10
	body.shadow_offset = Vector2(0.0, 5.0)
	var hover: StyleBoxFlat = body.duplicate()
	hover.bg_color = Color(0.22, 0.22, 0.27)
	b.add_theme_stylebox_override("normal", body)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var screen := Panel.new()  # 屏幕（奶油底）
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.offset_left = 11.0
	screen.offset_top = 13.0
	screen.offset_right = -11.0
	screen.offset_bottom = -22.0
	var ss := StyleBoxFlat.new()
	ss.bg_color = UiAssets.CARD_BG
	ss.set_corner_radius_all(10)
	screen.add_theme_stylebox_override("panel", ss)
	b.add_child(screen)
	var home := Panel.new()  # home 键小圆点（下巴处）
	home.mouse_filter = Control.MOUSE_FILTER_IGNORE
	home.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	home.offset_left = -7.0
	home.offset_right = 7.0
	home.offset_top = -18.0
	home.offset_bottom = -4.0
	var hs := StyleBoxFlat.new()
	hs.bg_color = Color(0.40, 0.40, 0.48)
	hs.set_corner_radius_all(8)
	home.add_theme_stylebox_override("panel", hs)
	b.add_child(home)

## 手机壳外观：有当前皮肤的 AIGC 手机壳资产就用贴图铺满机身（返回 true），否则程序化深色圆角机身占位（返回 false）。
func _apply_phone_shell(panel: PanelContainer) -> bool:
	var skin: Dictionary = PHONE_SKINS.get(_phone_skin, {})
	var art := UiAssets.tex(String(skin.get("shell", "")))
	if art != null:
		var sbt := StyleBoxTexture.new()
		sbt.texture = art
		panel.add_theme_stylebox_override("panel", sbt)
		return true
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.15, 0.15, 0.19)
	body.set_corner_radius_all(46)
	body.set_border_width_all(4)
	body.border_color = Color(0.30, 0.30, 0.38)
	body.shadow_color = Color(0.10, 0.07, 0.03, 0.45)
	body.shadow_size = 22
	body.shadow_offset = Vector2(0.0, 10.0)
	panel.add_theme_stylebox_override("panel", body)
	return false

## 自动检测手机壳贴图的「屏幕区域」：从图片中心出发，沿中轴左右/上下走到屏区边缘（屏幕是壳里
## 一块实心近匀色的大矩形），返回屏区占整图的内缩比例 {l,t,r,b}。屏区非实心/异常则回退保守值。
## 换任何新手机壳无需手调——丢一张图即自动贴合。O(W+H) 只在建 HUD 时跑一次。
func _detect_shell_screen_insets(img: Image) -> Dictionary:
	var fallback := { "l": 0.2, "t": 0.2, "r": 0.2, "b": 0.2 }
	var w := img.get_width()
	var h := img.get_height()
	var cx := int(w / 2)
	var cy := int(h / 2)
	var c0 := img.get_pixel(cx, cy)
	if c0.a < 0.6: # 中心透明=没检测到实心屏区，回退
		return fallback
	var tol := 46.0 / 255.0
	var x0 := cx
	while x0 > 0 and _col_close(img.get_pixel(x0 - 1, cy), c0, tol):
		x0 -= 1
	var x1 := cx
	while x1 < w - 1 and _col_close(img.get_pixel(x1 + 1, cy), c0, tol):
		x1 += 1
	var y0 := cy
	while y0 > 0 and _col_close(img.get_pixel(cx, y0 - 1), c0, tol):
		y0 -= 1
	var y1 := cy
	while y1 < h - 1 and _col_close(img.get_pixel(cx, y1 + 1), c0, tol):
		y1 += 1
	var fw := float(x1 - x0) / float(w)
	var fh := float(y1 - y0) / float(h)
	if fw < 0.2 or fh < 0.2 or fw > 0.98 or fh > 0.98: # 检测异常（中心落在装饰上等），回退
		return fallback
	return { "l": float(x0) / w, "t": float(y0) / h, "r": float(w - x1) / w, "b": float(h - y1) / h }

func _col_close(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol

## 一个 app 图标格：iOS 圆角小卡 + 图标 + 下方短名。app=[id, 短名, 图标资产]，资产缺失回退占位。
func _make_app_icon(app: Array) -> Control:
	var id := String(app[0])
	var tex := UiAssets.tex(String(app[2]))
	if tex == null:
		tex = UiAssets.tex(String(PHONE_APP_FALLBACK.get(id, "st_star")))
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 4)
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(44.0, 44.0)
	btn.icon = tex
	btn.expand_icon = true
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.add_theme_constant_override("icon_max_width", 34)
	# app 图标底：近白 + 明显沙色描边 + 稍大投影，在奶油壳屏上更跳（比奶油底对比高）。
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1.0, 1.0, 0.995)
	st.set_corner_radius_all(16)
	st.set_border_width_all(2)
	st.border_color = Color(0.85, 0.72, 0.50)
	st.shadow_color = Color(0.35, 0.24, 0.10, 0.32)
	st.shadow_size = 5
	st.shadow_offset = Vector2(0.0, 3.0)
	btn.add_theme_stylebox_override("normal", st)
	var stp: StyleBoxFlat = st.duplicate()
	stp.bg_color = UiAssets.CARD_ACCENT
	btn.add_theme_stylebox_override("hover", stp)
	btn.add_theme_stylebox_override("pressed", stp)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.pressed.connect(_open_app.bind(id))
	box.add_child(btn)
	var cap := Label.new()
	cap.text = String(app[1])
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_card_label(cap, 18)
	box.add_child(cap)
	return box

## 桌面 widget（整条卡片，少文字纯 UI）：左「可玩时间闹钟饼图」+ 右「小红花图标+数」。
func _build_phone_widget() -> PanelContainer:
	var card := PanelContainer.new()
	var cs := UiAssets.card_style(18.0, 1.0)
	cs.shadow_size = 0
	card.add_theme_stylebox_override("panel", cs)
	var pad := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(side, 12)
	card.add_child(pad)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	pad.add_child(row)
	# 左：可玩时间闹钟饼图（剩余可玩时间可视化，不识字也能看懂）
	var pie_box := CenterContainer.new()
	pie_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phone_playpie = PlayTimePie.new()
	_phone_playpie.custom_minimum_size = Vector2(64.0, 64.0)
	pie_box.add_child(_phone_playpie)
	row.add_child(pie_box)
	row.add_child(VSeparator.new())
	# 右：小红花（图标 + 数，无文字说明）
	var fl_box := HBoxContainer.new()
	fl_box.alignment = BoxContainer.ALIGNMENT_CENTER
	fl_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fl_box.add_theme_constant_override("separation", 6)
	fl_box.add_child(UiAssets.icon_rect("reward_flower", 34.0))
	_phone_flowers = Label.new()
	_style_card_label(_phone_flowers, 26)
	fl_box.add_child(_phone_flowers)
	row.add_child(fl_box)
	return card

## 按 PHONE_APPS 切页填充图标（每页 3x3=9 格，不足格不铺留白，仿 iPhone 主屏）。
func _build_phone_pages() -> void:
	for c in _phone_pages_box.get_children():
		c.queue_free()
	var n := PHONE_APPS.size()
	var pages := int(ceil(float(maxi(n, 1)) / float(PHONE_PAGE_SLOTS)))
	var idx := 0
	for _p in pages:
		var page := HBoxContainer.new() # 页宽=分页容器宽（每帧同步），网格居中
		page.alignment = BoxContainer.ALIGNMENT_CENTER
		var g := GridContainer.new()
		g.columns = PHONE_GRID_COLS
		g.add_theme_constant_override("h_separation", 16)
		g.add_theme_constant_override("v_separation", 16)
		for _s in PHONE_PAGE_SLOTS:
			if idx < n:
				g.add_child(_make_app_icon(PHONE_APPS[idx]))
				idx += 1
		page.add_child(g)
		_phone_pages_box.add_child(page)

## 翻页圆点：页数=页容器子数；>1 才显示，当前页高亮。
func _rebuild_phone_dots() -> void:
	if _phone_dots == null:
		return
	for c in _phone_dots.get_children():
		c.queue_free()
	var pages := _phone_pages_box.get_child_count() if _phone_pages_box != null else 0
	_phone_dots.visible = pages > 1
	for i in pages:
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(8.0, 8.0)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.add_theme_stylebox_override("panel", _phone_dot_style(i == _phone_page))
		_phone_dots.add_child(dot)

## 只重着色圆点（页切换时用，不重建节点）。
func _highlight_phone_dot() -> void:
	if _phone_dots == null:
		return
	var i := 0
	for dot in _phone_dots.get_children():
		(dot as Panel).add_theme_stylebox_override("panel", _phone_dot_style(i == _phone_page))
		i += 1

func _phone_dot_style(active: bool) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.set_corner_radius_all(4)
	st.bg_color = Color(0.35, 0.24, 0.10, 0.85) if active else Color(0.35, 0.24, 0.10, 0.28)
	return st

## 状态栏信号格：三根递增的小竖条；颜色由 _update_phone_banner 按 WS 在线态刷（绿/灰）。
func _make_signal_indicator() -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.alignment = BoxContainer.ALIGNMENT_END
	for h in [8.0, 13.0, 18.0]:
		var bar := ColorRect.new()
		bar.custom_minimum_size = Vector2(4.0, h)
		bar.size_flags_vertical = Control.SIZE_SHRINK_END
		box.add_child(bar)
	return box

## 手机遮罩点击：点手机外任意处→收起手机（吞掉事件，不下发为世界移动指令）。
func _on_phone_scrim_input(e: InputEvent) -> void:
	var press := (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed) \
			or (e is InputEventMouseButton and (e as InputEventMouseButton).pressed)
	if press:
		_close_phone()
		_phone_scrim.accept_event()

## 分页拖拽：ScrollContainer 原生触摸拖动横滚，松手时贴合到最近页并更新圆点。
func _on_phone_pager_input(e: InputEvent) -> void:
	var pressed := false
	if e is InputEventScreenTouch:
		pressed = (e as InputEventScreenTouch).pressed
	elif e is InputEventMouseButton:
		pressed = (e as InputEventMouseButton).pressed
	else:
		return
	if pressed:
		_phone_pager_dragging = true
	else:
		_phone_pager_dragging = false
		if _phone_page_w > 1.0 and _phone_pages_box != null:
			var last := maxi(0, _phone_pages_box.get_child_count() - 1)
			_phone_page = clampi(int(round(_phone_pager.scroll_horizontal / _phone_page_w)), 0, last)
			_highlight_phone_dot()

## 手机开着时每帧推进分页：同步单页宽=容器宽；未拖拽时把滚动缓动贴合到当前页。
func _step_phone_pager(delta: float) -> void:
	if _phone_pager == null or album_panel == null or not album_panel.visible:
		return
	var w := _phone_pager.size.x
	if w > 1.0 and not is_equal_approx(w, _phone_page_w):
		_phone_page_w = w
		for pg in _phone_pages_box.get_children():
			(pg as Control).custom_minimum_size.x = w
	if not _phone_pager_dragging and _phone_page_w > 1.0:
		var target := int(round(_phone_page * _phone_page_w))
		var cur := _phone_pager.scroll_horizontal
		if absi(cur - target) > 1:
			_phone_pager.scroll_horizontal = int(round(lerpf(float(cur), float(target), minf(1.0, 12.0 * delta))))
		else:
			_phone_pager.scroll_horizontal = target

## 打开一个 app：主屏隐藏、app 视图显示，只显示该页并刷新。
func _open_app(id: String) -> void:
	if not _album_pages.has(id):
		return
	if game_audio != null:
		game_audio.play_sfx("select")
	_phone_open_app = id
	_phone_home.visible = false
	_phone_app_view.visible = true
	for pid in _album_pages:
		(_album_pages[pid] as Control).visible = (pid == id)
	for entry in PHONE_APPS:
		if String(entry[0]) == id:
			_phone_app_title.text = String(entry[1])
	if id == "stickers" or id == "items":
		_refresh_album()

## 返回主屏：收起 app 视图与设置页的确认/预览子部件。
func _close_phone_app() -> void:
	_phone_open_app = ""
	if _phone_app_view != null:
		_phone_app_view.visible = false
	if _phone_home != null:
		_phone_home.visible = true
	if _reroll_confirm != null:
		_reroll_confirm.visible = false
	if _avatar_preview != null:
		_avatar_preview.visible = false
		_avatar_hash = ""

## 手机开着时每秒刷新一次 banner（时钟走字、已玩时长累加）；关着不做事，零开销。
func _step_phone_ui(delta: float) -> void:
	if album_panel == null or not album_panel.visible:
		return
	_phone_ui_t -= delta
	if _phone_ui_t > 0.0:
		return
	_phone_ui_t = 1.0
	_update_phone_banner()

## 手机状态栏 + 桌面 widget 刷新：状态栏时钟（实时）+ 信号格（WS 在线态）；
## widget 已玩时长（本次进入世界起算）+ 小红花数（代笔占位）。
func _update_phone_banner() -> void:
	if _phone_clock == null:
		return
	var t := Time.get_time_dict_from_system()
	_phone_clock.text = "%02d:%02d" % [int(t.get("hour", 0)), int(t.get("minute", 0))]
	if _phone_playpie != null:
		# 桌面 widget 饼图：可玩阶段显示绿色剩余、冷却阶段显示蓝色进度（值由 _step_play_budget 每帧更新）。
		_phone_playpie.set_state(_play_remaining_frac, _play_blocked, _play_cooldown_frac)
	if _phone_flowers != null:
		_phone_flowers.text = "x%d" % _red_flower_count()
	# 信号格：WS 在线→绿、离线→灰（每秒随 _step_phone_ui 刷新）
	if _phone_signal != null:
		var online := backend != null and backend.is_online()
		var col := Color(0.30, 0.78, 0.42) if online else Color(0.60, 0.60, 0.60, 0.5)
		for bar in _phone_signal.get_children():
			(bar as ColorRect).color = col

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
	_style_card_label(title, 34)
	col.add_child(title)
	var msg := Label.new()
	msg.text = "先休息一下，\n等小闹钟转满就能再来玩啦~"
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_style_card_label(msg, 24)
	col.add_child(msg)
	return root

## 小红花数：服务端权威钱包（world_state/task_complete/prop_created/gen_complete 同步）。
func _red_flower_count() -> int:
	return int(wallet.get("flowers", 0))

func _physics_process(delta: float) -> void:
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
	_step_prop_drag()
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
	tp = _prof_lap(tp, "approach")
	_update_fairy(delta)
	tp = _prof_lap(tp, "fairy")
	_step_voice(delta)
	_step_edge_tts(delta)
	_step_pending_leave(delta) # 「说完再走」：回应播完才动身+关对话（缺陷 ④）
	tp = _prof_lap(tp, "voice")
	# 语音链路占用时压低 BGM，给人声让路（与开放麦闭麦判定同一组信号）
	var fsm_in := _fsm_inputs()
	game_audio.set_ducked(InteractionFsm.voice_busy(fsm_in))
	# 对话期间静音 BGM（比 duck 更狠）：无 AEC 的麦克风会把外放 BGM 收进去，音乐峰值
	# （rms≈0.046–0.085，与真人说话同量级）直接顶开 VAD，自己开录、ASR 转出空——真机 logcat 实锤。
	# 只在角色说话时放音乐，其余对话时间一律静音（口径见 InteractionFsm.music_muted）。
	game_audio.set_music_muted(InteractionFsm.music_muted(fsm_in))
	tp = _prof_lap(tp, "duck")
	_step_hop(delta)  # 进对话时玩家跳向站位（在焦点/摆位之前推进，相机随之贴合）
	_step_phone_ui(delta)
	_step_phone_pager(delta)
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
	_update_portal_markers()   # 传送门拱随世界滚动（与角色同一套环面最短位移）
	tp = _prof_lap(tp, "npcs")
	_update_tap_marker(delta)
	_update_voice_wave(delta)
	tp = _prof_lap(tp, "tap/wave")
	_update_think_bubble(delta)
	_update_emotion_bubble(delta)
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

	if chars.is_empty() and player_msg.is_empty():
		return
	backend.send_position_stream(world_id, chars, player_msg, Time.get_ticks_msec() + _stage_offset())

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
		ra = _spawn_remote_actor(id, pos)
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

## 远端玩家 avatar 的渲染副本（占位外观：真实立绘按 profile 拉取留后续）。
func _spawn_remote_actor(id: String, pos: Vector2) -> Dictionary:
	var node := PaperCharacter.new()
	add_child(node)
	node.setup(critter_tex, Color(0.86, 0.92, 1.0), id) # setup 内部归一尺寸 + 挂脚下暗斑
	return { "node": node, "logical": pos, "id": id, "buf": RemoteActorBuffer.new(), "is_remote": true }

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
	var ra: Dictionary = _remote_actors.get(player_id, {})
	if ra.is_empty():
		return
	var node: Node = ra.get("node")
	if is_instance_valid(node):
		node.queue_free()
	_remote_actors.erase(player_id)

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
			var node: Node = ra.get("node")
			if is_instance_valid(node):
				node.queue_free()
			_remote_actors.erase(id)
			continue
		ra["logical"] = buf2.sample(render_ms, ra["logical"])

func _step_executors(delta: float) -> void:
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
	# 翻面后节点本地 X 轴反向，倾角随 cos(fry) 连续反号才始终「顶朝远离相机」；
	# 相机手势环绕时整体加 _gest_yaw（Y 最外层）保持纸面正对相机方位
	node.rotation = Vector3(-lean * cos(fry), fry + _gest_yaw, sway)
	# 待机呼吸微卷用慢相位（走动时让位给飘动）；飘动幅度随走路强度
	node.set_paper_motion(WALK_FLUTTER * w, IDLE_CURL * (1.0 - w) * sin(phase * 0.22))
	_update_action_anim(n, node, delta)

## 指令动作演出（do_action 契约键 paper_action，见 BehaviorExecutor.ACTION_DUR）：
## 挥手=左右摇纸 / 跳=双跳 / 转圈=绕竖轴一整圈（中途侧身纸边）/ 点头=前后倾。
## 叠加在正常姿态之上，sin(k*PI) 包络起收平滑，结束自动清键。
func _update_action_anim(n: Dictionary, node: PaperCharacter, delta: float) -> void:
	var action := String(n.get("paper_action", ""))
	if action.is_empty():
		return
	var t := float(n.get("paper_action_t", 0.0)) + delta
	var dur := float(BehaviorExecutor.ACTION_DUR.get(action, 1.2))
	if t >= dur:
		n.erase("paper_action")
		n.erase("paper_action_t")
		return
	n["paper_action_t"] = t
	var k := t / dur
	match action:
		"wave":
			node.rotation.z += deg_to_rad(16.0) * sin(t * TAU * 2.2) * sin(k * PI)
		"jump":
			node.position.y += absf(sin(k * PI * 2.0)) * 1.4 # 两小跳
		"spin":
			node.rotation.y += TAU * smoothstep(0.0, 1.0, k) # 一整圈，中途露纸边
		"nod":
			node.rotation.x += deg_to_rad(12.0) * sin(t * TAU * 1.6) * sin(k * PI)

## 纯判定（可单测）：近身空闲村民本帧是否该打招呼。busy=选中/聊天/叫停/正在做动作。
static func notice_ready(dist: float, walk: float, busy: bool, cd: float) -> bool:
	return cd <= 0.0 and not busy and walk <= NOTICE_WALK_EPS and dist <= NOTICE_RADIUS

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
		if not notice_ready(d.length(), float(n.get("paper_walk", 0.0)), busy, cd):
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

## 在村民头顶弹一个小表情气泡（per-NPC 懒建 Sprite3D，不复用 selected 单例的 emotion_bubble）。
func _pop_notice_bubble(n: Dictionary) -> void:
	var bub := n.get("notice_bubble") as Sprite3D
	if bub == null or not is_instance_valid(bub):
		bub = UiAssets.bubble_sprite("em_happy", NOTICE_BUBBLE_H)
		add_child(bub)
		n["notice_bubble"] = bub
	bub.texture = UiAssets.emotion_tex(NOTICE_EMOTES[randi() % NOTICE_EMOTES.size()])
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
func _update_voice_wave(delta: float) -> void:
	var active := selected != null and is_instance_valid(selected)
	if voice_wave.visible != active:
		voice_wave.visible = active
	if not active:
		return
	_wave_t += delta
	var lvl := (_vad.level if _vad != null else 0.0)
	# 整体幅度随音量抬升（静息也留 0.25 让波条一直在滚动，孩子看出「一直在听」）；
	# 每根柱子相位错开 → 一条左右流动的声波，音量越大越高越满。柱底钉在 HUD 竖直中心
	# 下方 WAVE_BASE_Y 处（内板中下部），只向上长。
	var base := 0.25 + lvl * 0.75
	for i in _wave_bars.size():
		var bar := _wave_bars[i] as ColorRect
		var shape := 0.5 + 0.5 * sin(_wave_t * 7.0 + float(i) * 0.8)
		var amp := base * (0.4 + 0.6 * shape)
		bar.offset_top = WAVE_BASE_Y - (WAVE_MIN_H + amp * (WAVE_MAX_H - WAVE_MIN_H))

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
	# 调试：选中角色后按 Enter/空格。小神仙→造角色；其他→本地 move_to（离线演示）。
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
	# 拖拽摆放物件中：本指事件全归拖拽（跟指吸附/松手落地），不走跟随/拾取
	if not _prop_drag.is_empty():
		if event is InputEventMouseMotion or event is InputEventScreenDrag:
			_prop_drag["screen"] = event.position
		elif (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed) \
				or (event is InputEventScreenTouch and not event.pressed):
			_end_prop_drag(event.position)
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
			_prop_press_id = "" # 抬指：长按候选作废
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
			_prop_press_id = "" # 抬指：长按候选作废
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
	_prop_press_id = "" # 长按候选作废；拖拽中的物件弹回原位
	_cancel_prop_drag()
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
	# 点自己 = 跟身边的小仙子说话（她是「我」的引导精灵，语音路由到精灵角色）
	if _pick_player(screen_pos):
		var fairy := _find_fairy()
		if not fairy.is_empty():
			_approach_npc(fairy["node"])
		return
	# 点空地：退出交互（恢复被叫停的 NPC），玩家走过去
	if selected != null:
		_exit_interaction()
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
	if _pick_npc(screen_pos) != null or _pick_player(screen_pos):
		return
	if _pick_ground(screen_pos) == Vector2.INF:
		return
	if selected != null:
		_exit_interaction()
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
	_clear_approach()
	_halt_npc(d)
	_approach = d
	_move_player_to(d["logical"], APPROACH_ARRIVE)

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
		_enter_interaction(d["node"])
	else:
		_resume_stopped_npc()

func _enter_interaction(npc: PaperCharacter) -> void:
	selected = npc
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
	# 开放麦：进近身即聆听——开口就说、说完自动发送，全程无按钮无模式（见 _step_voice）
	_mic.start()
	_vad = VoiceVad.new()
	_unmute_t = 0.0
	_reset_empty_streak() # 新一场对话不继承上一场的空识别退避
	_greet_on_enter(d) # 对方先开口打招呼（播放期间 _step_voice 自动闭麦，说完再放开）

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
	if _recording:
		_utterance_cancel() # 说到一半退出：静默丢弃，不留半开会话
	if _in_creation:
		_in_creation = false # 退出与小仙子的交互：取消未完成的造角色会话
		_hide_creation_cards()
		if online:
			backend.send_creation_cancel()
	_mic.stop()
	_vad = null
	selected = null
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
	backend.praise_tts.connect(_on_praise_tts)
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
	backend.prop_pending.connect(_on_prop_pending)
	backend.prop_created.connect(_on_prop_created)
	backend.prop_failed.connect(_on_prop_failed)
	backend.prop_denied.connect(_on_reward_denied)
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
	backend.actor_leave.connect(_on_actor_leave)         # 玩家离场：即时清掉其远端副本
	backend.scene_entered.connect(_on_scene_entered) # 走 portal 换场景：卸旧场景、载新场景
	# 「思考中」兜底超时：即使 voice_failed/character_response 都没回来（响应丢失/TLS/网络），
	# 也在 THINK_TIMEOUT 秒后自动解卡——这是无论后端如何都不再永久卡死的最后一道保险。
	_think_timer = Timer.new()
	_think_timer.one_shot = true
	_think_timer.timeout.connect(_on_think_timeout)
	add_child(_think_timer)

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
	_clear_placeholder(PLACEHOLDER_PORTAL_ID)
	game_audio.play_sfx("oops")
	push_warning("voice/gen failed: %s" % reason)
	if selected != null:
		banner.text = "我没听清呀，再说一次好不好？"
		banner.visible = true
		if _recording:
			_utterance_cancel()

## 在线引导：POST /worlds → 连 WS → 按世界状态生成角色（含小神仙）。离线则保留占位 NPC。
## _bootstrapping 全程置位，无论在线/离线都在收尾清零——world_ready 就绪判定据此知道引导已结束。
## 当前场景 id（模型 B：world 含多 scene）。进世界时按初始场景置初值，走 portal（enter_scene）时更新。
var _scene_id := "village"

## 当前场景的传送点（服务端 scenes[].portals / scene_entered 的 scene.portals 下发）。
## 运行期结构 { tile: Vector2i, radius: float, to_scene: String, to_tile: Vector2i }。
var _portals: Array = []
## 传送去抖：刚换完场景玩家就站在返回传送点上，必须先走出所有半径才重新武装，否则来回弹。
var _portal_armed := false

const FADE_TIME := 0.35          ## 过场黑幕淡入/淡出各自的时长（秒）
const TRANSITION_TIMEOUT := 8.0  ## 服务端不回 scene_entered / 区块铺不完时的兜底：强行淡出，别把小朋友关在黑屏里
var _fade_rect: ColorRect        ## 换场景黑幕（盖在 HUD 之上，过场期间吃掉乱点）
var _fade_a := 0.0               ## 黑幕当前不透明度
var _fade_target := 0.0          ## 黑幕目标不透明度（1=遮住，0=露出世界）
var _transitioning := false      ## 过场进行中：禁止再次触发传送
var _pending_scene := ""         ## 全黑之后才发 enter_scene——卸旧载新绝不在半透明时发生
var _await_skin := false         ## 新场景已落地，等区块重铺完（all_skinned）再淡出
var _transition_t := 0.0         ## 本次过场累计秒（超时兜底用）
var _arrive_tile := Vector2i(-1, -1) ## 走 portal 的目标落点（优先于服务端记的该场景最后位置）

## 传送门视觉标记（每个 portal 一座拱门）。刻意不走 chunk_manager 的 SDF 物件通道：那条路会
## 登记占地（把传送点本身挡住）并进 _dynamic_props（长按就被当语音物件揣走）。这里由 world 直接
## 持有节点、逐帧按环面最短位移摆位；SdfProp 材质自带 world-bend，不再 CPU 端压 y（与区块内物件同口径）。
const PORTAL_MARKER_SPEC := "res://assets/sdf_props/portal_arch.json"
var _portal_markers: Array = [] ## [{ node: SdfProp, logical: Vector2 }]

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

## 逐帧把拱门摆到渲染空间（渲染原点 = focus_logical），高度取所在 tile 的台阶高。
func _update_portal_markers() -> void:
	for m in _portal_markers:
		var node: Variant = m.get("node", null)
		if node == null or not is_instance_valid(node):
			continue
		var logical: Vector2 = m["logical"]
		var d := WorldGrid.shortest_delta(focus_logical, logical)
		var ty := float(TerrainMap.tile_height(WorldGrid.to_tile(logical))) * TerrainMap.STEP_HEIGHT
		(node as Node3D).position = Vector3(d.x, ty, d.y)

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

## 从服务端下发的场景数组里取当前场景并载入（初始进世界用）。任何一步不成就静默保留本地
## _paint()——离线、老服务端、地形未入库、载荷损坏，都必须能照常进世界。
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
	# 场景 id 先告诉 chunk_manager：重铺时散布 deco / 手工地标按目标场景取规则（village 分区+建筑、
	# forest 铺满树+河岸苇+空地）。必须在 rebuild 之前置好，否则重铺仍用旧场景的 deco 规则。
	if chunk_manager != null:
		chunk_manager.scene_id = String(scene.get("sceneId", chunk_manager.scene_id))

	# POI 先应用：与地形字节相互独立，地形拉取失败不该把地点名一起丢了。
	# 解析不出任何合法 POI 时保留内置常量——绝不让世界变成没有地点的空壳。
	var sp := parse_server_pois(scene.get("pois", []))
	if not sp.is_empty():
		pois = sp

	# 传送点同理：地形拉不下来也要认这张图的 portal（走过去还能换场景）。
	# 没有 portal 的场景就是没有出口，_portals 置空即可（离线/老服务端下发不了 portals）。
	_portals = parse_server_portals(scene.get("portals", []))
	_spawn_portal_markers()

	var asset := String(scene.get("terrainAsset", ""))
	if asset.is_empty():
		return
	var buf: PackedByteArray = await api.fetch_bytes(asset)
	if buf.is_empty():
		push_warning("[terrain] 拉取地形 %s 失败，沿用现有地形" % asset)
		return
	var r := TerrainMap.load_from_bytes(buf)
	if not r["ok"]:
		push_warning("[terrain] 服务端地形非法(%s)，沿用现有地形" % r["error"])
		return
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

## 收到 scene_entered：卸载当前场景的角色/物件 → 上新地形并重铺区块 → 生成新场景角色/物件
## → 按该场景玩家最后位置落位。顺序保证「地形在 chunk 重铺、角色/玩家落位之前就位」
## （docs/multi-scene-design.md 步骤⑤边界1）。
func _on_scene_entered(data: Dictionary) -> void:
	var sid := String(data.get("sceneId", ""))
	if sid.is_empty():
		return
	_portal_armed = false # 落地时多半正站在返回传送点上：走出去才重新武装（_step_portal）
	_unload_scene()

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

	# 新场景物件（placed 的落地，bagged 的留背包）。
	_restore_world_props(data.get("props", []))

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
	# 仙女跨场景跟随：服务端记的还是旧场景的坐标，重新降生后直接搬到玩家身旁
	# （黑幕遮着瞬移不穿帮），免得揭幕后从半张地图外飞一大段追过来。
	var fairy := _find_fairy()
	if not fairy.is_empty():
		fairy["logical"] = WorldGrid.wrap_pos(focus_logical + Vector2(2.6, 1.8))
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
	_fairy_poi = {} # 旧场景的 POI 提醒点在新场景是野坐标，别让仙女飞过去
	for n in npcs:
		if not bool(n.get("is_fairy", false)):
			OccupancyMap.char_unregister(String(n.get("id", "")))
		var node: Variant = n.get("node", null)
		if node != null and is_instance_valid(node):
			(node as Node).queue_free()
	npcs.clear()
	_villager_count = 0
	_reported_tiles.clear() # 位置去重重置：新场景角色从头全报一次
	# 语音物件：释放占地 + 清运行时清单（rebuild 后不再把旧场景物件重生成到新场景）
	if chunk_manager != null:
		chunk_manager.clear_dynamic_props()
	world_props.clear()
	_portals.clear() # 旧场景的出口不属于新场景；新场景的由 _apply_scene 重新下发
	_clear_portal_markers()

## 初载角色过滤：只留当前场景的角色（仙女恒随，与 enter_scene 同款约定）。get_world 回的是
## 全库角色，不过滤会把别场景的角色全生在村里，positions_report 随后把它们拖成 village
## （scene-drag-guard 实锤过：刚 seed 的森林村民被初载客户端整批拖空）。缺 sceneId 的存量按 village。
func _filter_boot_characters(all: Array) -> Array:
	var chars: Array = []
	for c in all:
		var cd := c as Dictionary
		if bool(cd.get("isFairy", false)) or String(cd.get("sceneId", "village")) == _scene_id:
			chars.append(cd)
	return chars

func _bootstrap() -> void:
	_bootstrapping = true
	_player_restore_pending = true
	_boot_status = "连接精灵世界…"
	_apply_player_sprite() # 档案形象替换占位（并行拉取，不阻塞世界引导）
	# 加载固定的 default 世界（含预生成村民），不再每次新建
	var world: Dictionary = await api.get_world("default")
	_boot_stage = 1 # 网络已定音（成功或离线），loading 进度推进到中段
	if not world.is_empty():
		online = true
		world_id = String(world.get("id", "default"))
		await _load_server_terrain(world.get("scenes", []))
		backend.url = (api.base as String).replace("http", "ws") + "/ws"
		backend.player_id = PlayerProfile.ensure_player_id() # 设备端稳定 UUID，_send 统一注入
		backend.connect_to_server()
		for n in npcs:
			OccupancyMap.char_unregister(String(n.get("id", "")))
			(n["node"] as Node).queue_free() # 清掉离线占位
		npcs.clear()
		var chars: Array = _filter_boot_characters(world.get("characters", []))
		# 先并发预取所有角色素材（anim 优先，跳静态大图）：冷启动从「逐个立绘串行下载」的长尾
		# 降到「最慢一个并发」，杜绝首次进世界接近 25s 揭幕硬超时、村民后补的观感。
		var total := chars.size()
		_boot_status = "唤醒村民 0/%d" % total
		var prefetched := await _prefetch_characters(chars)
		# 素材已就位，顺序降生（命中内存缓存瞬时）；逐个推进 _boot_sub，loading 仙子据此持续前行。
		for i in range(total):
			_boot_status = "唤醒村民 %d/%d" % [i + 1, total]
			await _spawn_server_character(chars[i] as Dictionary, Vector2.INF, prefetched)
			_boot_sub = float(i + 1) / float(total) if total > 0 else 1.0
		_boot_status = "布置世界…"
		_restore_world_props(world.get("props", []))
		# 玩家搬到小神仙旁边降生，相机跟着玩家过去
		var fairy := _find_fairy()
		if not fairy.is_empty():
			focus_logical = fairy["logical"]
			if not player.is_empty():
				var spot := _find_free_spot(WorldGrid.wrap_pos(fairy["logical"] + Vector2(5.0, 3.0)), PLAYER_SPAN)
				player["logical"] = spot
				OccupancyMap.char_register(PLAYER_ID, spot, PLAYER_SPAN)
	else:
		_boot_status = "离线模式"
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
		var tex := await api.fetch_texture(String(pick["hash"]))
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
	var is_fairy := bool(c.get("isFairy", false))
	if is_fairy:
		BlobShadow.detach(npc) # 悬浮飞行不落地，脚下暗斑穿帮
		npc.wants_ground_shadow = false  # 切「角色实时阴影」刷新时别给悬浮角色挂脚下 blob
		if use_anim: # 已是动画图集：直接以动画降生（play_idle 覆盖 setup 的静态尺寸，同帧无闪）
			npc.play_idle(tex, anim_meta, FAIRY_HEIGHT, 0.0)
		else:
			# 小仙子随从：头部大小（时之笛式），无论真图/占位都按 FAIRY_HEIGHT 归一
			npc.pixel_size = FAIRY_HEIGHT / float(tex.get_height())
			if real: # 静态就位后后台轮询 idle 动画，就绪则切动画
				_poll_idle_anim(npc, asset, FAIRY_HEIGHT, 0.0)
	elif real:
		# 相位按 id 错开，避免整村同帧起跳的机械感（31帧/8fps 循环约 3.9s）。
		var anim_phase := float(cid.hash() % 256) / 256.0 * 3.9
		if use_anim: # 已是动画图集：直接以动画降生
			npc.play_idle(tex, anim_meta, 6.0, anim_phase)
		else:
			# 生成图分辨率高，按高度归一化到约 6 单位，脚底对齐原点
			var h := float(tex.get_height())
			npc.pixel_size = 6.0 / h
			npc.offset = Vector2(0.0, h / 2.0)
			BlobShadow.attach(npc, clampf(float(tex.get_width()) * npc.pixel_size * 0.38, 0.4, 1.4))
			# 村民真图就绪后，后台轮询 idle 动画，就绪则静态切动画（与玩家/仙子同一条链路）。
			_poll_idle_anim(npc, asset, 6.0, anim_phase)
	var logical := at_logical
	if logical == Vector2.INF:
		logical = _restore_logical(c, is_fairy)
	var dict := { "node": npc, "logical": logical, "id": cid, "is_fairy": is_fairy }
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
var _placeholders := {} ## 占位符 id → 落位 tile（Vector2i）

## 在玩家身旁立起占位符。gen_progress 会来好几次（逐阶段），只认第一次。
func _spawn_placeholder(id: String, spec: Dictionary) -> void:
	if _placeholders.has(id):
		return
	var anchor: Vector2 = player["logical"] if not player.is_empty() else focus_logical
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos(anchor + Vector2(3.0, 2.0)))
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

func _on_gen_complete(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet")) # 造角色扣了 1 朵花，同步最新钱包
	var character: Dictionary = data.get("character", {})
	_in_creation = false
	_hide_creation_cards()
	thinking_label.visible = false
	# 新伙伴从传送门里走出来；传送门没立成（放不下/离线）就退回小神仙旁降生
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

## 造物开工（服务端已扣花）：退出对话，立起魔法熔炉。
func _on_prop_pending(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet")) # 花在开造那一刻就扣掉
	_in_creation = false
	_hide_creation_cards()
	if selected != null:
		_exit_interaction()
	thinking_label.visible = false
	_spawn_placeholder(PLACEHOLDER_FORGE_ID, PlaceholderSpecs.FORGE)
	banner.text = "魔法熔炉烧起来啦！"
	banner.visible = true

## 语音造物完成：物件从熔炉所在的位置出来，落位 tile 回报服务端持久化。
func _on_prop_created(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet")) # 造物扣了 1 朵花，同步最新钱包
	var prop: Dictionary = data.get("prop", {})
	thinking_label.visible = false
	var spec: Dictionary = prop.get("spec", {})
	# 先收熔炉腾出格子，成品就落在那儿；熔炉没立成就退回玩家身旁
	var tile := _clear_placeholder(PLACEHOLDER_FORGE_ID)
	var want := tile
	if want.x < 0:
		var anchor: Vector2 = player["logical"] if not player.is_empty() else focus_logical
		want = WorldGrid.to_tile(WorldGrid.wrap_pos(anchor + Vector2(3.0, 2.0)))
	var placed := chunk_manager.add_dynamic_prop(spec, want, randf() * 360.0, _prop_wander(spec), String(prop.get("id", "")))
	if placed.x < 0:
		banner.text = "这里放不下啦，换个地方试试"
		banner.visible = true
		return
	world_props[String(prop.get("id", ""))] = { "spec": spec, "state": "placed", "tile": [placed.x, placed.y] }
	backend.send_prop_place(world_id, String(prop.get("id", "")), placed)
	game_audio.play_sfx("fanfare")
	banner.text = "变出来啦！"
	banner.visible = true

func _on_prop_failed(_reason: String) -> void:
	thinking_label.visible = false
	_clear_placeholder(PLACEHOLDER_FORGE_ID) # 造砸了：熔炉收起来，别让它烧到天荒地老
	banner.text = "没变出来，再说一次试试"
	banner.visible = true

## 小红花不足被拦（造物/造角色）：同步钱包 + 横幅引导 + 播服务端带来的仙子引导语。
func _on_reward_denied(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet"))
	_in_creation = false
	_hide_creation_cards()
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

# ── 物品摆放：长按拾起 + 拖拽 tile 吸附 + 松手落地/收纳（服务端状态机同步） ──────

## 服务端 props → world_props 登记；placed 且有 tile 的落进世界（重载/重启恢复）。
## 旧服务端无 state 字段：视为已摆放。bagged 的留在收集册物品页，不进世界。
func _restore_world_props(props: Array) -> void:
	for p in props:
		var pd: Dictionary = p
		var state := String(pd.get("state", "placed"))
		var tile: Variant = pd.get("tile", null)
		world_props[String(pd.get("id", ""))] = { "spec": pd.get("spec", {}), "state": state, "tile": tile }
		if state == "placed" and tile is Array and (tile as Array).size() >= 2:
			var t := Vector2i(int(tile[0]), int(tile[1]))
			chunk_manager.add_dynamic_prop(pd.get("spec", {}), t, float(hash(pd.get("id", "")) % 360), _prop_wander(pd.get("spec", {})), String(pd.get("id", "")))

## 按下时记录指下的语音物件（长按候选）。按在 NPC/玩家上的交互优先，不算物件。
func _begin_prop_press(screen_pos: Vector2) -> void:
	_prop_press_id = ""
	_prop_press_t = 0.0
	if not _prop_drag.is_empty() or _pick_npc(screen_pos) != null or _pick_player(screen_pos):
		return
	var ground := _pick_ground(screen_pos)
	if ground == Vector2.INF:
		return
	var hit_id := chunk_manager.dynamic_prop_at(WorldGrid.to_tile(ground))
	_prop_press_id = hit_id if _is_pickable_prop(hit_id) else ""

## 这个物件能不能被长按拎起来。施法中的占位符不行——把正在传送新伙伴的传送门抱在手里，
## 成品落位时记账就对不上了（_placeholders 还记着它，chunk_manager 里却已经没有）。
func _is_pickable_prop(id: String) -> bool:
	if id.is_empty():
		return false
	return not _placeholders.has(id)

## 长按累计：手指滑走（变成拖屏/跟随）即取消；到阈值把物件拎起来。
func _step_prop_press(delta: float) -> void:
	if _prop_press_id.is_empty() or not _prop_drag.is_empty():
		return
	if _dragging:
		_prop_press_id = ""
		return
	_prop_press_t += delta
	if _prop_press_t >= PROP_LONG_PRESS:
		_begin_prop_drag()

## 拾起：物件从世界摘出（占地已释放），节点归世界层跟手指走。
func _begin_prop_drag() -> void:
	var picked: Dictionary = chunk_manager.pickup_dynamic_prop(_prop_press_id)
	_prop_press_id = ""
	if picked.is_empty():
		return
	_hold_follow = false # 拾起接管本次按压，不再按住跟随
	_cancel_player_move()
	var node: Node3D = picked.get("node") if is_instance_valid(picked.get("node")) else null
	if node == null: # 区块刚重刷节点被清：造个替身继续拖
		node = SdfProp.from_spec(picked.get("spec_data", {}))
		if node == null:
			return
		add_child(node)
	else:
		node.reparent(self)
	(node as SdfProp).enable_wander(0.0) # 拖拽中钉住，不让它自己走
	picked["node"] = node
	picked["origin"] = picked["tile"]
	picked["screen"] = _press_pos
	_prop_drag = picked
	if game_audio != null:
		game_audio.play_sfx("enter")

## 拖拽跟指（每帧）：指下地面 tile 吸附，抬高一点表示拎着；tile 记下来松手用。
func _step_prop_drag() -> void:
	if _prop_drag.is_empty():
		return
	var node: Node3D = _prop_drag["node"]
	if not is_instance_valid(node):
		_prop_drag = {}
		return
	var ground := _pick_ground(_prop_drag.get("screen", _press_pos))
	if ground == Vector2.INF:
		return
	var tile := WorldGrid.to_tile(ground)
	_prop_drag["tile"] = tile
	var center := Vector2((float(tile.x) + 0.5) * WorldGrid.TILE_SIZE, (float(tile.y) + 0.5) * WorldGrid.TILE_SIZE)
	var d := WorldGrid.shortest_delta(focus_logical, center)
	var ty := float(TerrainMap.tile_height(tile)) * TerrainMap.STEP_HEIGHT
	_place_on_bent_ground(node, Vector3(d.x, ty + PROP_DRAG_LIFT, d.y))

## 松手：拖到收集册按钮上=收纳；指下 tile 有位=落地挪位；没位=弹回原处。
func _end_prop_drag(screen_pos: Vector2) -> void:
	if _prop_drag.is_empty():
		return
	var drag := _prop_drag
	_prop_drag = {}
	if album_button.get_global_rect().has_point(screen_pos):
		_store_dragged_prop(drag)
		return
	_drop_prop(drag, drag.get("tile", drag["origin"]), true)

## 手势接管/异常中断：物件弹回原位（不发 prop_move——位置没变）。
func _cancel_prop_drag() -> void:
	if _prop_drag.is_empty():
		return
	var drag := _prop_drag
	_prop_drag = {}
	_drop_prop(drag, drag["origin"], false)

## 落地共用：目标 tile 精确摆放 → 失败弹回原位（放宽搜索兜底，原位可能被角色压住）
## → 还不行就收进背包（物件绝不凭空消失）。摆放成功按需同步服务端。
func _drop_prop(drag: Dictionary, target: Vector2i, notify: bool) -> void:
	var id := String(drag.get("id", ""))
	var spec: Dictionary = drag.get("spec_data", {})
	var yaw := float(drag.get("yaw", 0.0))
	var wander := float(drag.get("wander", 0.0))
	var placed := chunk_manager.add_dynamic_prop(spec, target, yaw, wander, id, 0)
	if placed.x < 0 and target != drag["origin"]:
		placed = chunk_manager.add_dynamic_prop(spec, drag["origin"], yaw, wander, id, 0)
		if notify:
			banner.text = "这里放不下啦"
			banner.visible = true
	if placed.x < 0:
		placed = chunk_manager.add_dynamic_prop(spec, drag["origin"], yaw, wander, id, 3)
	var node: Node3D = drag["node"]
	if is_instance_valid(node):
		node.queue_free() # add_dynamic_prop 重新生成了正式节点，拖拽中的退场
	if placed.x < 0: # 连原位附近都塞不下（极端）：收进背包兜底
		_store_dragged_prop(drag) # 内含 fanfare，别再叠一层落地音
		return
	# 只在 notify（孩子松手落地）时出声；notify=false 是取消拖拽自动归位，不该响。
	if notify and game_audio != null:
		game_audio.play_sfx("pop") # drop_002 本就是「放下」音
	if world_props.has(id):
		world_props[id]["tile"] = [placed.x, placed.y]
	if notify and online and placed != Vector2i(drag["origin"]):
		backend.send_prop_move(world_id, id, placed)

## 收纳：物件从世界消失进收集册物品页，同步服务端状态机。
func _store_dragged_prop(drag: Dictionary) -> void:
	var id := String(drag.get("id", ""))
	var node: Node3D = drag["node"]
	if is_instance_valid(node):
		node.queue_free()
	if world_props.has(id):
		world_props[id]["state"] = "bagged"
		world_props[id]["tile"] = null
	if online:
		backend.send_prop_store(world_id, id)
	banner.text = "收进册子啦！"
	banner.visible = true
	_pulse_album_button()
	if game_audio != null:
		game_audio.play_sfx("fanfare")

## 物品页点一下：物件摆回玩家身旁（就近找位），同步服务端。
func _take_prop_out(pid: String) -> void:
	var wp: Dictionary = world_props.get(pid, {})
	if wp.is_empty() or String(wp.get("state", "")) != "bagged":
		return
	var spec: Dictionary = wp.get("spec", {})
	var anchor: Vector2 = player["logical"] if not player.is_empty() else focus_logical
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos(anchor + Vector2(3.0, 2.0)))
	var placed := chunk_manager.add_dynamic_prop(spec, want, randf() * 360.0, _prop_wander(spec), pid, 3)
	if placed.x < 0:
		banner.text = "这里放不下啦，换个地方试试"
		banner.visible = true
		return
	wp["state"] = "placed"
	wp["tile"] = [placed.x, placed.y]
	if online:
		backend.send_prop_take(world_id, pid, placed)
	if game_audio != null:
		game_audio.play_sfx("pluck") # 从册子拈出来（对称于收进去的 fanfare）
	_close_phone() # 收起手机看物件落地（幂等，同时退近身相机）
	banner.text = "摆出来啦！"
	banner.visible = true

## 小神仙造角色（在线）。
func _request_create(intent: String) -> void:
	if online:
		thinking_label.text = "施法中…"
		thinking_label.visible = true
		backend.send_create_character(world_id, intent)

## 端侧 ASR（Android 插件 MaliangAsr）：有则异步加载模型，识别结果直送 voice_transcript。
## 桌面/编辑器没有该单例 → _asr_local 保持 null，一切走服务端识别（原路径）。
func _setup_local_asr() -> void:
	if not Engine.has_singleton("MaliangAsr"):
		# Android 上没有单例 = 导出漏带 ASR 的 AAR（坏包），硬报错拒进游戏；
		# 桌面/编辑器天然没有该单例，合法走服务端识别。
		if AsrGuard.is_fatal(OS.get_name(), false):
			AsrGuard.block(get_tree(), AsrGuard.MSG_MISSING)
		return
	_asr_local = Engine.get_singleton("MaliangAsr")
	_asr_local.connect("final_result", _on_local_asr_final)
	_asr_local.connect("asr_error", _on_local_asr_error)
	_asr_local.connect("asr_ready", _on_local_asr_ready)
	_asr_local.initialize()

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
	if _vad != null:
		_vad.reset()
	if _vad_log:
		print("[vad] EMPTY streak=%d cooldown=%.1fs" % [_empty_streak, _cooldown_t])

## 拿到有效转写：退避清零，恢复正常聆听节奏。
func _reset_empty_streak() -> void:
	_empty_streak = 0
	_cooldown_t = 0.0

## 模型异步加载完成（~秒级）。在此之前 _step_voice 不喂 VAD，不会开麦。
func _on_local_asr_ready() -> void:
	if _vad_log:
		print("[asr] 端侧模型就绪，开放麦")

## 端侧 ASR 是否可用于本次 utterance。Android 上未就绪即禁止开麦（绝不回落服务端）。
func _asr_is_ready() -> bool:
	return _asr_local != null and _asr_local.isReady()

func _on_local_asr_final(text: String) -> void:
	_local_asr_session = false
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
	_vt_send = Time.get_ticks_msec() # 发转写 → 到 character_response 即纯 LLM 耗时
	backend.send_voice_transcript(world_id, _selected_id(), t)

func _on_local_asr_error(msg: String) -> void:
	_local_asr_session = false
	# Android 上端侧 ASR 是硬依赖：初始化/识别失败即模型问题，硬报错，绝不静默回落服务端。
	if AsrGuard.is_fatal(OS.get_name(), false):
		AsrGuard.block(get_tree(), AsrGuard.MSG_INIT_FAILED % msg)
		return
	push_warning("端侧 ASR 出错，本次运行回落服务端识别: %s" % msg)
	_asr_local = null

# ── 近身对话开放麦（VAD 自动断句：开口即录、说完即发，零按钮零模式）─────────

## 每帧驱动：角色思考/说话时闭麦（半双工防自听），其余时间把麦克风增量喂 VAD。
## 当前帧的交互标志位快照 → 喂给显式状态机（见 interaction_fsm.gd）。
## 字段与旧 _step_voice 的闭麦表达式逐字对应，行为等价由 test_interaction_fsm 的 64 组合护栏保证。
func _fsm_inputs() -> InteractionFsm.Inputs:
	return InteractionFsm.Inputs.new({
		"in_interaction": selected != null,
		"approaching": not _approach.is_empty(),
		"thinking": thinking_label != null and thinking_label.visible,
		"tts_busy": (_tts_player != null and _tts_player.playing) or _tts_pending,
		"fairy_speaking": fairy_voice != null and fairy_voice.is_playing(),
		"recording": _recording,
		"in_creation": _in_creation,
		"cooldown": _cooldown_t > 0.0,
	})

## 本帧的显式交互状态。
func _fsm_state() -> InteractionFsm.State:
	return InteractionFsm.derive(_fsm_inputs())

func _step_voice(delta: float) -> void:
	if _vad == null:
		return
	var x := _fsm_inputs()
	# 退避只在「否则就该开麦」时倒计时：角色说话/思考期本就闭麦，别把退避空烧掉，
	# 否则 TTS 一停麦就全开，退避形同虚设。
	if _cooldown_t > 0.0 and not (x.thinking or x.speaking()):
		_cooldown_t = maxf(_cooldown_t - delta, 0.0)
	var pcm := _mic.drain_pcm16k() # 闭麦期间也持续排空采集缓冲，恢复聆听时不会吃到角色的声音
	# 端侧模型还在异步加载：不喂 VAD、不开麦。Android 上绝不把 PCM 回落上传服务端
	# （加载失败会走 asr_error 硬报错，不会长期卡在这里）。桌面无单例，此处恒为 false。
	# 排在 FSM 闭麦判定之前：未就绪时无论交互态如何都不许开麦。
	if AsrGuard.must_wait_for_ready(_os_name, _asr_is_ready()):
		_vad.reset()
		return
	if not InteractionFsm.mic_open(InteractionFsm.derive(x)):
		if _recording:
			_utterance_cancel() # 时序兜底：闭麦瞬间还在录 → 静默丢弃
		_vad.reset()
		_unmute_t = UNMUTE_GRACE # 闭麦刚结束的残响尾音不算开口
		return
	# 自播音效正在外放：平板无 AEC，它会被自己的麦克风收回去，被 VAD 听成「孩子开口」
	# （enter=212ms、bell=123ms，都长过 START_MS=90ms）→ 凭空一轮空录音 → ASR 返回空
	# → COOLDOWN 退避。SFX 是 -6dB，比已被真机 logcat 实证能顶开 VAD 的 BGM(-14dB) 更响，
	# 而 set_music_muted 只压 Music bus，SFX bus 从未受保护。
	# 只在「还没开口」时挡：录音中屏蔽会吃掉孩子正在说的话（mic_on 那 139ms 混音是已知取舍，
	# 此时 VAD 已 speaking，音效不会再造成误判开口，只是混进 PCM 开头）。
	if not _recording and game_audio != null and game_audio.sfx_bleeding():
		_vad.reset()
		_unmute_t = UNMUTE_GRACE # 音效外放的余响同样不算开口（0.3s > 最长开麦态音效 0.22s）
		return
	if _unmute_t > 0.0:
		_unmute_t -= delta
		return
	_feed_voice_pcm(pcm)
	if _recording:
		if _vad_log:
			_vad_log_accum += delta
			if _vad_log_accum >= 1.0:
				_vad_log_accum = 0.0
				var st: Dictionary = _vad.debug_stats()
				# silence_ms 若始终涨不上去（背景声灌满麦克风）→ 说完也断不了句，是卡顿指纹
				print("[vad] rec level=%.3f thr=%.4f silence=%dms speech=%dms" % [
					st["level"], st["threshold"], st["silence_ms"], st["speech_ms"]])
		_chunk_accum += delta
		if _chunk_accum >= 0.15:
			_flush_pending_chunk() # 上传与说话重叠，断句时音频已基本传完
			_chunk_accum = 0.0

## VAD 事件驱动。独立函数：headless 测试注入合成 PCM 走同一链路（test_visual_click_move）。
func _feed_voice_pcm(pcm: PackedByteArray) -> void:
	if _vad == null:
		return
	for ev in _vad.feed(pcm):
		match String(ev["type"]):
			"start":
				if _vad_log:
					var st: Dictionary = _vad.debug_stats()
					print("[vad] START noise=%.4f thr=%.4f" % [st["noise"], st["threshold"]])
				_utterance_begin(ev["pcm"] as PackedByteArray)
			"speech":
				_pending_pcm.append_array(ev["pcm"] as PackedByteArray)
			"end":
				if _vad_log:
					# reason=cap 说明 900ms 静音判定始终没触发、撞 12s 硬顶 = 卡顿实锤
					print("[vad] END reason=%s speech=%dms silence=%dms noise=%.4f thr=%.4f" % [
						ev.get("reason", "?"), ev.get("speech_ms", 0), ev.get("silence_ms", 0),
						ev.get("noise", 0.0), ev.get("threshold", 0.0)])
				_utterance_commit()
			"cancel":
				if _vad_log:
					print("[vad] CANCEL reason=%s speech=%dms silence=%dms" % [
						ev.get("reason", "?"), ev.get("speech_ms", 0), ev.get("silence_ms", 0)])
				_utterance_cancel()

## 开口：开一个识别会话（路由定格），VAD 给的预录头块先送（首音节不丢）。
func _utterance_begin(head: PackedByteArray) -> void:
	if selected == null or _recording:
		return
	_recording = true
	# 语音耗时：开口即新一轮，清零各段戳
	_vt_speak_start = Time.get_ticks_msec()
	_vt_speak_end = 0
	_vt_asr_done = 0
	_vt_send = 0
	_vt_response = 0
	_vt_tts_out = 0
	game_audio.play_sfx("mic_on")
	_pending_pcm = head.duplicate()
	_chunk_accum = 0.0
	# 路由定格：端侧模型就绪 → 本地识别（分片不上传，只送最终文本）；否则服务端流式。
	_local_asr_session = _asr_local != null and _asr_local.isReady()
	if _local_asr_session:
		_asr_local.startSession()
	else:
		backend.send_voice_start(world_id, _selected_id())
	_flush_pending_chunk()

## 说完（静音断句）：残留分片发出，触发识别/回复。
func _utterance_commit() -> void:
	if not _recording:
		return
	_recording = false
	game_audio.play_sfx("mic_off")
	thinking_label.visible = true
	banner.visible = false
	_flush_pending_chunk()
	if _local_asr_session:
		_asr_local.stopSession() # final_result 信号回来后走 voice_transcript
	else:
		backend.send_voice_end()
	# 语音耗时：断句时刻 + 本轮 ASR 口径；服务端路径此刻即已发出(voice_end)，send 戳就是断句戳
	_vt_speak_end = Time.get_ticks_msec()
	_vt_local = _local_asr_session
	if not _local_asr_session:
		_vt_send = _vt_speak_end
	_think_timer.start(THINK_TIMEOUT)  # 兜底：响应没回来也会自动解卡

## 太短的误触/中途退出：静默丢弃本段，双 ASR 路径都不产生任何回复。麦克风保持聆听。
func _utterance_cancel() -> void:
	if not _recording:
		return
	_recording = false
	_pending_pcm = PackedByteArray()
	if _local_asr_session:
		_local_asr_session = false # 弃会话即可：插件下次 startSession 会自动释放旧流
	else:
		backend.send_voice_cancel()

func _flush_pending_chunk() -> void:
	if _pending_pcm.size() > 0:
		if _local_asr_session:
			_asr_local.feedPcm(_pending_pcm) # 端侧：原始 PCM 直喂插件，不上传
		else:
			backend.send_voice_chunk(Marshalls.raw_to_base64(_pending_pcm))
		_pending_pcm = PackedByteArray()

func _on_character_response(data: Dictionary) -> void:
	if _think_timer != null:
		_think_timer.stop()
	thinking_label.visible = false
	# 主动招呼（对方先开口）：不是玩家发起的一轮，跳过「听到/没听清」提示，只放招呼台词+TTS
	var is_greeting := bool(data.get("greeting", false))
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

## 进创造视图：退出普通对话构图（关横幅/情绪气泡/听到字幕，麦保留——孩子仍可语音答复），
## 相机推近仙子特写、背景压暗，点亮创造视图。幂等（每轮 creation_prompt 都可安全调）。
func _enter_creation_view() -> void:
	_in_creation = true
	_creation_cam = true
	banner.visible = false          # 普通对话的横幅/提示不在创造视图里出现
	heard_label.visible = false
	if emotion_bubble != null:
		emotion_bubble.visible = false # 收起头顶情绪气泡（创造视图是干净特写）
	_emotion_life = 0.0
	if _creation_view != null:
		_creation_view.visible = true

## 引导式创造追问一轮（造角色或造物共用此路径）：仙子念问句 + 屏幕中央弹 2×2 大卡；点卡或直接说都行。
## 消息 goal-agnostic：客户端只管渲染服务端给的 options、回传 optionId，造角色还是物件由服务端 goal 决定。
func _on_creation_prompt(data: Dictionary) -> void:
	if _think_timer != null:
		_think_timer.stop()
	thinking_label.visible = false
	_enter_creation_view() # 首轮：退出普通对话构图、相机推近仙子特写、点亮创造视图
	# 问题只给家长看的字幕（幼儿不识字，靠 TTS 念）
	_creation_q.text = String(data.get("question", data.get("replyText", "")))
	_creation_q.visible = true
	_advance_creation_dots()
	_build_creation_cards(data.get("options", []))
	var asset := String(data.get("ttsAsset", ""))
	if not asset.is_empty():
		_play_tts(asset) # 仙子把问题和选项念出来（幼儿不识字）
	else:
		# clientTts：仙子问句本地 edge 合成（幼儿不识字，念不出来就降级服务端）
		_speak_line(String(data.get("replyText", data.get("question", ""))), String(data.get("voiceId", "")))

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
		card.pressed.connect(_on_creation_card.bind(oid))
		_creation_cards.add_child(card)

## 选项卡图标（生成后 iconAsset 才非空）：异步拉图贴到按钮，失败保留文字兜底。
func _apply_card_icon(card: Button, asset: String) -> void:
	var tex := await api.fetch_texture(asset)
	if tex != null and is_instance_valid(card):
		card.icon = tex
		card.expand_icon = true
		card.text = "" # 有图就不显字

## 点了某张大卡：答复小仙子，转「施法中…」等下一轮/成品（视图仍留着，等下一个 prompt 或退出）。
func _on_creation_card(option_id: String) -> void:
	if not _in_creation or selected == null:
		return
	game_audio.play_sfx("bell")
	backend.send_creation_reply(world_id, _selected_id(), option_id)
	for c in _creation_cards.get_children():
		c.queue_free()
	_creation_q.text = "施法中…"

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
	_creation_cam = false # 松开特写：后续按 _locked（对话两景）或 GOD（已 _exit_interaction）复位
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
	_tts_player.play()
	_tts_gen_playback = _tts_player.get_stream_playback()
	_tts_ending = false
	_tts_gen_capacity = _tts_gen_playback.get_frames_available() # 刚开播缓冲全空 = 实际容量
	_mark_tts_out()

func _on_tts_chunk(pcm: PackedByteArray) -> void:
	if _tts_gen_playback != null:
		_tts_stream_pcm.append_array(pcm)
		_drain_tts_stream()

## 把积压 PCM16 按 generator 剩余空位转成帧推入（每帧 Vector2 双声道同值）。
func _drain_tts_stream() -> void:
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
	if _vt_local:
		lines.append("ASR %d 端侧" % maxi(0, _vt_asr_done - _vt_speak_end))
		lines.append("LLM %d" % llm)
	else:
		lines.append("ASR server")
		lines.append("LLM %d 含ASR" % llm)
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

const STAGE_NARRATE_VOICE := "zh-CN-XiaoyiNeural" ## 旁白固定用小仙子音色（edge 原生名，直通 map_voice）
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

## 服务端造好 spec 的道具落位（完成型）：near 解析为世界坐标 → 就近落位 → 持久化 → 回 done 带 id。
func stage_prop_spawn(id: String, spec: Dictionary, near: Variant, done: Callable) -> void:
	var anchor := _stage_near_pos(near)
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos(anchor + Vector2(2.0, 1.0)))
	var placed := chunk_manager.add_dynamic_prop(spec, want, randf() * 360.0, _prop_wander(spec), id)
	if placed.x < 0:
		if done.is_valid():
			done.call(false, { "error": "道具没地方放" })
		return
	world_props[id] = { "spec": spec, "state": "placed", "tile": [placed.x, placed.y] }
	backend.send_prop_place(world_id, id, placed)
	if done.is_valid():
		done.call(true, { "id": id })

## 已造道具挪位（脚本 prop.place）：先拾起（释放旧位/节点）再按 at 落位。
func stage_prop_place(id: String, at: Variant) -> void:
	var entry: Dictionary = world_props.get(id, {})
	var spec: Dictionary = entry.get("spec", {})
	var picked := chunk_manager.pickup_dynamic_prop(id)
	if not picked.is_empty():
		var node: Node3D = picked.get("node")
		if is_instance_valid(node):
			node.queue_free()
		if spec.is_empty():
			spec = picked.get("spec_data", {})
	if spec.is_empty():
		return
	var want := WorldGrid.to_tile(WorldGrid.wrap_pos(_stage_near_pos(at)))
	var placed := chunk_manager.add_dynamic_prop(spec, want, randf() * 360.0, _prop_wander(spec), id)
	if placed.x >= 0:
		world_props[id] = { "spec": spec, "state": "placed", "tile": [placed.x, placed.y] }
		backend.send_prop_place(world_id, id, placed)

## 移除道具（脚本 prop.remove）。
func stage_prop_remove(id: String) -> void:
	var picked := chunk_manager.pickup_dynamic_prop(id)
	if not picked.is_empty():
		var node: Node3D = picked.get("node")
		if is_instance_valid(node):
			node.queue_free()
	world_props.erase(id)

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
	_speak_line(text, voice_id) # async：内部 await edge 合成后播放；此处不 await，完成靠轮询
	# 时长兜底（0.22s/字，1.5–12s）：真机 TTS 空闲检测可靠，但 headless dummy 音频 playing 永真，
	# 靠此兜底保证 ack 必达不卡场。
	var est := clampf(0.22 * float(text.strip_edges().length()), 1.5, 12.0)
	_stage_speaks.append({ "done": done, "deadline": Time.get_ticks_msec() / 1000.0 + est, "started": false })

func _is_tts_busy() -> bool:
	return (_tts_player != null and _tts_player.playing) or _tts_pending

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

## 连上 WS 后上报世界地点名清单（POI 规范名），让意图 LLM 把「去某地」归一到真实地名。
func _send_world_info() -> void:
	var names: Array = []
	for poi in pois:
		names.append(String(poi.get("name", "")))
	backend.send_world_info(world_id, names, PlayerProfile.upload_dict(), _scene_id) # 带档案供服务端首见建玩家；_scene_id 让服务端回读本场景 playerPos

# ── 奖赏系统：委托状态 / 提示 chip / 完成判定 ──────────────────────────────

## world_info 的回包：同步贴纸背包与进行中委托（断线重连/重启后补状态）。
func _on_world_state(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet"))
	_set_active_task(data.get("activeTask"))
	_restore_player_pos(data.get("playerPos"))

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

## 应用服务端下发的钱包（world_state/task_complete/prop_created/gen_complete 各处复用）：更新状态 + 刷 UI。
func _apply_wallet(w: Variant) -> void:
	if typeof(w) == TYPE_DICTIONARY:
		wallet = w
	_refresh_album()

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

## chip 里的小图标/短字（图标为主，家长可读短名）。
func _chip_icon(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(38.0, 38.0)
	return r

func _chip_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_label(l, 26)
	return l

## 委托提示 chip：目标图标+短名 ⇒ 奖励贴纸图标（AIGC 贴纸，_set_active_task 时重建）。
func _update_task_chip() -> void:
	if task_chip == null:
		return
	for c in task_chip.get_children():
		c.queue_free()
	if active_task.is_empty():
		task_chip.visible = false
		return
	task_chip.add_child(_chip_icon(UiAssets.tex("ic_target")))
	match String(active_task.get("type", "")):
		"deliver":
			task_chip.add_child(_chip_icon(UiAssets.tex("ic_chat")))
			task_chip.add_child(_chip_label("→%s" % active_task.get("targetName", "")))
		"bring":
			task_chip.add_child(_chip_icon(UiAssets.tex("ic_handshake")))
			task_chip.add_child(_chip_label("%s→%s" % [active_task.get("targetName", ""), active_task.get("npcName", "")]))
		"visit":
			task_chip.add_child(_chip_icon(UiAssets.tex("ic_pin")))
			task_chip.add_child(_chip_label(String(active_task.get("locationName", ""))))
	task_chip.add_child(_chip_label("⇒"))
	task_chip.add_child(_chip_icon(UiAssets.tex(_stamp_icon(String(active_task.get("stampStyle", "star")))))) # 奖励=盖这款集邮章
	task_chip.visible = true

## 盖章款式 id → 图标名（stamp_<style>，未知款式回退 stamp_star）。
func _stamp_icon(style: String) -> String:
	return "stamp_%s" % style if STAMP_STYLES.has(style) else "stamp_star"

## 委托完成：盖 1 章（满 3 升 1 花）、更新钱包、收起 chip、庆祝演出。
func _on_task_complete(data: Dictionary) -> void:
	_apply_wallet(data.get("wallet"))
	_set_active_task(null)
	var flower_gained := bool(data.get("flowerGained", false))
	banner.text = "哇！集满盖章换到一朵小红花啦！" if flower_gained else "太棒啦！得到一个新盖章！"
	banner.visible = true
	_celebrate_reward(flower_gained, data.get("task", {}))

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
	album_button.pivot_offset = album_button.size * 0.5
	var tw := create_tween()
	tw.tween_property(album_button, "scale", Vector2(1.3, 1.3), 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(album_button, "scale", Vector2.ONE, 0.2)

## 手机开合（点左下角手机按钮切换）：开→显示机身+遮罩+进近身相机；关→反之。
## 音效挂在这里而非 _open_phone/_close_phone：那两个是幂等内部函数，
## _open_phone 会调 _close_phone_app 回主屏、_take_prop_out 会调 _close_phone 收起手机，
## 挂进去就会在非用户操作时误响。这里是 album_button 的唯一入口。
func _toggle_album() -> void:
	if game_audio != null:
		game_audio.play_sfx("page")
	if album_panel.visible:
		_close_phone()
	else:
		_open_phone()

## 打开手机：机身+全屏遮罩显示，回主屏、刷新册子/banner，相机进近身（玩家挪屏左）。
func _open_phone() -> void:
	album_panel.visible = true
	if _phone_scrim != null:
		_phone_scrim.visible = true
	_close_phone_app() # 每次打开手机都回到主屏
	_refresh_album()
	_update_phone_banner()
	_enter_phone_cam()

## 收起手机：机身+遮罩隐藏，相机还原到近身前视角（幂等，未开则不动）。
func _close_phone() -> void:
	if album_panel == null or not album_panel.visible:
		return
	album_panel.visible = false
	if _phone_scrim != null:
		_phone_scrim.visible = false
	_exit_phone_cam()

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

## 设置页：重新捏角色——先 ？✓✗ 确认一遍防小手误触，确认后回童话书 onboarding。
func _on_reroll_pressed() -> void:
	if game_audio != null:
		game_audio.play_sfx("click")
	_reroll_confirm.visible = true

## 点按音效放完再切场景（本节点一切走音就断了，同 menu.gd 的 _go_to）。
func _on_reroll_yes() -> void:
	if game_audio != null:
		game_audio.play_sfx("confirm")
		await get_tree().create_timer(0.15).timeout
	get_tree().change_scene_to_file("res://onboarding.tscn")

func _on_reroll_no() -> void:
	if game_audio != null:
		game_audio.play_sfx("click")
	_reroll_confirm.visible = false

## 设置页：换形象——用档案答案重新生图（走服务端朝向保险丝），预览 ✓ 才落档案并热更新。
func _on_avatar_regen_pressed() -> void:
	if _avatar_btn.disabled:
		return
	_avatar_btn.disabled = true
	_avatar_preview.visible = false
	var desc := PlayerProfile.avatar_description(PlayerProfile.load_profile())
	var res := await api.post_json("/player-sprite", { "visualDescription": desc })
	var new_hash := String(res.get("spriteAsset", ""))
	var tex: Texture2D = null
	if not new_hash.is_empty():
		tex = await api.fetch_texture(new_hash)
	if not is_inside_tree() or _avatar_btn == null:
		return # 面板已销毁（切场景），静默放弃
	_avatar_btn.disabled = false
	if tex == null:
		return # 离线/生成失败：按钮恢复可再试，不打断小朋友
	_avatar_hash = new_hash
	_avatar_img.texture = tex
	_avatar_preview.visible = true
	game_audio.play_sfx("reveal")

func _on_avatar_regen_yes() -> void:
	if _avatar_hash.is_empty():
		return
	var profile := PlayerProfile.load_profile()
	profile["sprite_asset"] = _avatar_hash
	PlayerProfile.save_profile(profile)
	_avatar_hash = ""
	_avatar_preview.visible = false
	game_audio.play_sfx("confirm")
	_apply_player_sprite() # 热更新在场玩家贴图，立即生效

func _on_avatar_regen_no() -> void:
	_avatar_hash = ""
	_avatar_preview.visible = false

## 小红花/集邮 app 页：3×3 花格(按 flowers 点亮) + 一排盖章进度点(按 stampProgress) + 累计盖章数。
func _build_flowers_page() -> Control:
	var page := VBoxContainer.new()
	page.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_theme_constant_override("separation", 14)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_flower_cells.clear()
	for _i in MAX_FLOWERS:
		var cell := UiAssets.icon_rect("reward_flower", 44.0)
		grid.add_child(cell)
		_flower_cells.append(cell)
	page.add_child(grid)
	# 盖章进度点（集满 STAMPS_PER_FLOWER 个换一朵花）
	var stamp_row := HBoxContainer.new()
	stamp_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stamp_row.add_theme_constant_override("separation", 10)
	_stamp_dots.clear()
	for _i in STAMPS_PER_FLOWER:
		var dot := UiAssets.icon_rect("stamp_star", 34.0)
		stamp_row.add_child(dot)
		_stamp_dots.append(dot)
	page.add_child(stamp_row)
	# 累计盖章数（图标 + 数，去文字化）
	var total_row := HBoxContainer.new()
	total_row.alignment = BoxContainer.ALIGNMENT_CENTER
	total_row.add_theme_constant_override("separation", 6)
	total_row.add_child(UiAssets.icon_rect("stamp_star", 26.0))
	_stamps_total_label = Label.new()
	_style_card_label(_stamps_total_label, 22)
	total_row.add_child(_stamps_total_label)
	page.add_child(total_row)
	return page

## 刷新小红花/集邮 app：3×3 花格按 flowers 点亮、盖章点按 stampProgress 点亮、累计盖章数。
func _refresh_album() -> void:
	var flowers := int(wallet.get("flowers", 0))
	for i in _flower_cells.size():
		(_flower_cells[i] as TextureRect).modulate = Color.WHITE if i < flowers else Color(0.28, 0.28, 0.34)
	var prog := int(wallet.get("stampProgress", 0))
	for i in _stamp_dots.size():
		(_stamp_dots[i] as TextureRect).modulate = Color.WHITE if i < prog else Color(0.28, 0.28, 0.34)
	if _stamps_total_label != null:
		_stamps_total_label.text = "x%d" % int(wallet.get("stampsTotal", 0))
	_refresh_items_page()

## 物品页：重建 bagged 物件网格（礼盒贴纸+物件名）。物件不多，全量重建最简单。
func _refresh_items_page() -> void:
	if _items_grid == null:
		return
	for c in _items_grid.get_children():
		c.queue_free()
	var bagged := []
	for pid in world_props:
		if String(world_props[pid].get("state", "")) == "bagged":
			bagged.append(pid)
	_items_empty.visible = bagged.is_empty()
	for pid in bagged:
		var spec: Dictionary = world_props[pid].get("spec", {})
		var cell := VBoxContainer.new()
		cell.alignment = BoxContainer.ALIGNMENT_CENTER
		cell.custom_minimum_size = Vector2(44.0, 0.0)
		var glyph := UiAssets.icon_button("ic_gift", 44.0) # 点一下摆回玩家身旁
		glyph.pressed.connect(_take_prop_out.bind(String(pid)))
		var name_label := Label.new()
		name_label.text = String(spec.get("name", "小玩意"))
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		name_label.custom_minimum_size = Vector2(44.0, 0.0)
		_style_label(name_label, 18)
		cell.add_child(glyph)
		cell.add_child(name_label)
		_items_grid.add_child(cell)

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
