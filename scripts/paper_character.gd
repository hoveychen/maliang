class_name PaperCharacter
extends MeshInstance3D
## HD-2D 纸片角色：3D 世界里的 2D 立绘。不用 billboard——而是面向相机方向 +
## 固定小倾角（织梦岛/纸片马里奥式：站在地上、面向玩家，仍有立体感）。
## 倾角由 world.gd 随相机角度设置（rotation.x）。相机方位固定在 +Z，故默认朝向即正对相机。
##
## v2：从 Sprite3D 换成细分 QuadMesh + paper_character.gdshader——单面片只有 4 个顶点
## 弯不了，细分后顶点位移才能做「纸」的卷曲/飘动/翻面演出。
## 对外保持 Sprite3D 同名属性（texture/pixel_size/offset/modulate），上层零改动。

var char_name: String = "小伙伴"
## 该角色静态立绘的资产 hash（world.gd spawn 时灌入）。焦点视频 LOD 据此向服务端拉 ogv 段。空=占位/无真图。
var sprite_hash: String = ""

## 占位立绘的世界高度（米）。在线生成 sprite 由 world.gd 覆盖为 ~6 单位。
const PLACEHOLDER_HEIGHT := 3.2
## 细分密度：宽 6 × 高 12 段（~91 顶点）足够卷曲平滑，安卓无压力。
const SUBDIV_W := 6
const SUBDIV_H := 12

static var _shader: Shader = null
static var _xray_shader: Shader = null

## X 光穿透剪影开关（画质旋钮 xray 驱动，同 SdfProp._snap_iters 模式）：
## 该 pass 每角色每帧多画一个全 quad 透明面并逐像素采样深度图，老 Mali 上深度采样
## 打断 tiled 渲染快路径。默认全平台开——角色走到房子/树后面仍见剪影是体验的一部分
## （老板拍板：默认保留），只有弱机被 benchmark 定档摘除、或用户在设置页手动关。
static var _xray_enabled := true

## 换档入口：作用于已存在（paper_chars 组）与后续创建的所有角色。
static func set_xray_enabled(on: bool, tree: SceneTree) -> void:
	_xray_enabled = on
	for n in tree.get_nodes_in_group("paper_chars"):
		var p := n as PaperCharacter
		if p != null:
			p._mat.next_pass = p._xray_mat if on else null
			p._pm_flutter = INF  # 重挂后强制下次 set_paper_motion 补齐 X 光 pass 的参数

var texture: Texture2D = null:
	set(v):
		texture = v
		_mat.set_shader_parameter("albedo_tex", v)
		_xray_mat.set_shader_parameter("albedo_tex", v)
		_refresh_geometry()
var pixel_size := 0.01:
	set(v):
		pixel_size = v
		_refresh_geometry()
## 与 Sprite3D.offset 同语义：按像素平移贴图（world.gd 传 (0, h/2) 把锚点放到脚底）。
var offset := Vector2.ZERO:
	set(v):
		offset = v
		_refresh_geometry()
var modulate := Color.WHITE:
	set(v):
		modulate = v
		_mat.set_shader_parameter("modulate", v)

var _mat: ShaderMaterial
## 穿透 pass 材质：被建筑/树/地形挡住时画半透明剪影浮在遮挡物上（见 paper_xray.gdshader）。
var _xray_mat: ShaderMaterial
## 动画图集 meta（空=静态整图）；非空时几何按单格 cellW×cellH 算、shader 分格播放。
var _sheet: Dictionary = {}
## 段名 → {start, count}（服务端 meta.clips）。空 = 老的单段图集（v1），整张图集就是 idle。
var _clips: Dictionary = {}
## 当前播放的段名。
var _clip := ""

# ── 焦点视频 LOD（docs/video-hero-lod-design.md）─────────────────────────────
## 进对话的「焦点」角色叠一路 24fps 真视频（图集档只有 8fps），离开对话即撤回图集。
## 任意时刻 ≤1 路解码——单个 VideoStreamPlayer，切 idle/talking 时换它的 stream（不同时开两路）。
## 真机实测 1 路 ~56fps 稳、8 路掉到 47fps（memory video-as-animation-tablet-decode-limit）。
static var _video_shader: Shader = null  ## 抠绿视频 shader，首次开视频才 load（多数角色永不用）
var _video_mat: ShaderMaterial = null
var _vsp: VideoStreamPlayer = null
var _video_lod := false
var _video_clip := ""
var _video_idle: VideoStream = null
var _video_talking: VideoStream = null
var _video_height := 0.0   ## 目标角色世界高度（米）：进视频用图集档身高，观感不跳
var _video_wait := 0.0     ## 等首帧解码的累计秒数（超时=平台不支持/坏流，放弃留图集）

## 首帧解码迟迟不来的放弃阈值（秒）：Theora 软解在目标机都能出帧（spike 实证华为 ~56fps），
## 超过此值仍无首帧 = 平台不支持/坏流，静默撤回留图集，别让 VideoStreamPlayer 空转 CPU。
const VIDEO_FIRST_FRAME_TIMEOUT := 3.0

## 视频帧里角色竖向占比（源立绘/视频角色约占帧高 86~93%，见 sprite_sheet.ts cellH 注释）。P3/P4 调参旋钮。
const VIDEO_FILL := 0.9
## 角色脚底在视频帧里的归一化 y（原点顶，越接近 1 越靠帧底）。P3/P4 调参旋钮。
const VIDEO_FOOT := 0.97

func _init() -> void:
	if _shader == null:
		_shader = load("res://shaders/paper_character.gdshader")
	if _xray_shader == null:
		_xray_shader = load("res://shaders/paper_xray.gdshader")
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_xray_mat = ShaderMaterial.new()
	_xray_mat.shader = _xray_shader
	if _xray_enabled:
		_mat.next_pass = _xray_mat  # 穿透剪影作为主材质的 next_pass，排在不透明之后读深度
	var q := QuadMesh.new()
	q.subdivide_width = SUBDIV_W
	q.subdivide_depth = SUBDIV_H
	mesh = q
	material_override = _mat

## 脚下伪影半径（setup/play_anim 记录，refresh_ground_shadow 复用）；wants_ground_shadow
## 落地角色为真、悬浮角色（仙子/飞行）由 world 置假——切「角色实时阴影」时据此挂/摘 blob。
var _blob_radius := 0.6
var wants_ground_shadow := true

func _enter_tree() -> void:
	add_to_group("paper_chars")  # set_xray_enabled / refresh_ground_shadow 换档批量寻址用

## 画质切「角色实时阴影」后刷新脚下 blob：attach 内部按 BlobShadow.suppress_actor_blob
## 自动挂/摘（suppress 时会 detach 旧的且不建新）。悬浮角色跳过（脚下暗斑穿帮）。
func refresh_ground_shadow() -> void:
	if wants_ground_shadow:
		BlobShadow.attach(self, _blob_radius)

func setup(tex: Texture2D, color: Color, cname: String) -> void:
	char_name = cname
	modulate = color
	# 任意分辨率纹理：按高度归一化到 PLACEHOLDER_HEIGHT；
	# 锚点移到脚底（上移半高，底边落在节点原点，绕脚底倾斜/翻面）
	var h := float(tex.get_height())
	pixel_size = PLACEHOLDER_HEIGHT / h
	offset = Vector2(0.0, h / 2.0)
	texture = tex
	# 脚下伪影（替代实时阴影，见 BlobShadow 注释）；换贴图重设尺寸时同步重挂
	_blob_radius = clampf(float(tex.get_width()) * pixel_size * 0.38, 0.4, 1.4)
	BlobShadow.attach(self, _blob_radius)

# ── 贴纸附着（character-anchors，docs/character-anchors-design.md §4）────────
# 锚点=立绘归一化坐标(原点左上)，服务端 vision 检测下发；缺失时按 alpha 现算兜底。
# 附着物是子节点，跟随面片倾斜/翻面(rotation.y=PI)。翻面后单片会转到角色面片背后
# 被深度遮挡，故每个槽位是「前后三明治」双片(±STICKER_Z，背片预转 PI)——哪面朝相机
# 哪面赢深度，背面看到镜像贴纸与角色本身镜像一致。

const STICKER_Z := 0.02          ## 贴纸离角色面片的前后距离（米），防 z-fight
const STICKER_W_RATIO := 0.22    ## 贴纸世界宽 ≈ 角色可见高的比例
## 兜底比例（与服务端 anchors.ts 同参）：手部所在身高比例/由身体边缘内收比例
const FALLBACK_HAND_Y := 0.55
const FALLBACK_HAND_INSET := 0.05

## 归一化锚点 { "headTop": {x,y}, "handL": {...}, "handR": {...} }；空 = 未下发（走兜底）。
var _anchors: Dictionary = {}
## 槽位 → 附着 holder 节点（Node3D，含前后两片）。
var _stickers: Dictionary = {}

## world.gd 在 spawn/换装时灌入服务端下发的 appearance.anchors（缺省空字典）。
func set_anchors(anchors: Dictionary) -> void:
	_anchors = anchors if anchors != null else {}
	for slot in _stickers:
		_position_sticker(slot) # 锚点后到（如老档案补算）时重摆已挂贴纸

## 挂贴纸到槽位（headTop/handL/handR）。同槽重复挂 = 换贴图。tex 为贴纸图（含白描边）。
## 前后三明治双片的几何/材质走 PaperQuad.make_sandwich 共享 helper（与组合物零件同一套数学）。
func attach_sticker(slot: String, tex: Texture2D) -> void:
	detach_sticker(slot)
	var h := visible_height()
	var w := h * STICKER_W_RATIO
	var sh := w * float(tex.get_height()) / float(tex.get_width())
	var holder := PaperQuad.make_sandwich(tex, w, sh, STICKER_Z)
	holder.name = "sticker_" + slot
	holder.set_meta("sticker_h", sh) # _position_sticker 用它把头顶贴纸底边对齐锚点
	add_child(holder)
	_stickers[slot] = holder
	_position_sticker(slot)

func detach_sticker(slot: String) -> void:
	var old: Node3D = _stickers.get(slot)
	if old != null:
		old.name = old.name + "_dying" # 让出槽位名：同帧重挂时新 holder 才不被自动改名（@Node3D@N）
		old.queue_free()
	_stickers.erase(slot)

## 锚点 → 面片局部坐标：quad 局部 y∈[0,h]（脚底原点）、x∈[-w/2,w/2]；
## 归一化 (ax,ay) 原点左上 → x=(ax-0.5)*w、y=(1-ay)*h。
## 头顶槽贴纸「底边」对齐锚点（帽子坐在头上），手槽「中心」对齐。
func _position_sticker(slot: String) -> void:
	var holder: Node3D = _stickers.get(slot)
	if holder == null or texture == null:
		return
	var a := _anchor_for(slot)
	var tw := float(texture.get_width())
	var th := float(texture.get_height())
	if not _sheet.is_empty():
		tw = float(_sheet.get("cellW", tw))
		th = float(_sheet.get("cellH", th))
	var w := tw * pixel_size
	var h := th * pixel_size
	var y := (1.0 - float(a.y)) * h
	if slot == "headTop":
		y += float(holder.get_meta("sticker_h", 0.0)) * 0.5
	holder.position = Vector3((float(a.x) - 0.5) * w, y, 0.0)

## 槽位锚点：优先服务端下发；缺失按贴图 alpha 现算（与服务端 anchors.ts 兜底同规则）并缓存。
func _anchor_for(slot: String) -> Dictionary:
	var a: Variant = _anchors.get(slot)
	if typeof(a) == TYPE_DICTIONARY and (a as Dictionary).has("x"):
		return a
	var fb := _fallback_anchor(slot)
	_anchors[slot] = fb
	return fb

## alpha 兜底：headTop=最顶不透明行中心；hand=身高 55% 行身体边缘内收 5%。
## 图集(sprite-sheet)模式只扫左上第 0 格：cell0 在原点，把扫描范围收到单格 cellW×cellH 即可，
## 锚点归一化到单格（与 _position_sticker/几何同坐标系）。取不到 Image（贴图未就绪）时才退固定比例。
func _fallback_anchor(slot: String) -> Dictionary:
	var img: Image = texture.get_image() if texture != null else null
	if img == null:
		match slot:
			"headTop": return { "x": 0.5, "y": 0.02 }
			"handL": return { "x": 0.25, "y": FALLBACK_HAND_Y }
			_: return { "x": 0.75, "y": FALLBACK_HAND_Y }
	var w := img.get_width()
	var h := img.get_height()
	if not _sheet.is_empty():
		w = int(_sheet.get("cellW", w))
		h = int(_sheet.get("cellH", h))
	if slot == "headTop":
		for y in range(h):
			var sum := 0.0
			var n := 0
			for x in range(w):
				if img.get_pixel(x, y).a > 0.03:
					sum += float(x)
					n += 1
			if n > 0:
				return { "x": sum / float(n) / float(w - 1), "y": float(y) / float(h - 1) }
		return { "x": 0.5, "y": 0.02 }
	var row := int(FALLBACK_HAND_Y * float(h - 1))
	var min_x := -1
	var max_x := -1
	for x in range(w):
		if img.get_pixel(x, row).a > 0.03:
			if min_x < 0:
				min_x = x
			max_x = x
	if min_x < 0:
		return { "x": 0.25 if slot == "handL" else 0.75, "y": FALLBACK_HAND_Y }
	var inset := float(w) * FALLBACK_HAND_INSET
	var px := float(min_x) + inset if slot == "handL" else float(max_x) - inset
	return { "x": clampf(px / float(w - 1), 0.0, 1.0), "y": FALLBACK_HAND_Y }

## 演出参数量化步长（米）：4mm 对 45mm 的慢呼吸卷曲肉眼不可辨，
## 却把待机时的 uniform 上传从每帧降到 ~1/5——旧版每角色每帧 4 次 set_shader_parameter。
const PM_STEP := 0.004
var _pm_flutter := INF
var _pm_curl := INF

## 纸片演出参数（world.gd 每帧驱动）：走路飘动幅度 / 待机呼吸卷曲，单位米。
## 量化脏检查：值未跨过步长格子就不重传；X 光 pass 摘除时也不给游离材质上传。
func set_paper_motion(flutter_amp: float, curl: float) -> void:
	var qf := snappedf(flutter_amp, PM_STEP)
	var qc := snappedf(curl, PM_STEP)
	if qf == _pm_flutter and qc == _pm_curl:
		return
	_pm_flutter = qf
	_pm_curl = qc
	_mat.set_shader_parameter("flutter_amp", qf)
	_mat.set_shader_parameter("curl", qc)
	if _mat.next_pass != null:
		_xray_mat.set_shader_parameter("flutter_amp", qf)
		_xray_mat.set_shader_parameter("curl", qc)

## 折纸机关参数（动作层每帧驱动，仅折纸类动作期间非零）。折痕格式见 shader 注释：
## crease=Vector4(痕点 xn,yn, 痕方向 dx,dy)（归一化纸面坐标）。全零→全零是恒等快路径，
## 待机时零上传；动作期间角度连续变化，逐帧重传（每场景同时折纸的角色至多一两个）。
var _fold_active := false

func set_paper_fold(f1: Vector4, a1: float, f2: Vector4, a2: float, pleat: float, crumple: float) -> void:
	var active := a1 != 0.0 or a2 != 0.0 or pleat != 0.0 or crumple != 0.0
	if not active and not _fold_active:
		return
	_fold_active = active
	var mats := [_mat] if _mat.next_pass == null else [_mat, _xray_mat]
	for m in mats:
		var sm := m as ShaderMaterial
		sm.set_shader_parameter("fold1", f1)
		sm.set_shader_parameter("fold1_angle", a1)
		sm.set_shader_parameter("fold2", f2)
		sm.set_shader_parameter("fold2_angle", a2)
		sm.set_shader_parameter("pleat_amp", pleat)
		sm.set_shader_parameter("crumple_amp", crumple)

## 从静态立绘切到动画图集。meta 为服务端 SpriteSheetMeta
## （cols/rows/frameCount/fps/cellW/cellH，+ 可选 clips{段名:{start,count}}）。
## world_height：期望世界高度（米），与切换前静态立绘保持一致，观感不跳。phase：相位偏移（秒）。
## 落地即播 idle 段；之后由 world.gd 按角色状态 set_clip 切 moving/talking。
func play_anim(atlas: Texture2D, meta: Dictionary, world_height: float, phase := 0.0) -> void:
	var ch := float(meta.get("cellH", 0))
	var cw := float(meta.get("cellW", 0))
	if atlas == null or ch <= 0.0 or cw <= 0.0:
		return
	_sheet = meta
	var clips: Variant = meta.get("clips")
	_clips = clips if typeof(clips) == TYPE_DICTIONARY else {}
	_clip = "idle"
	# 起手播 idle 段：v2 图集从 clips.idle 取区间；v1 单段图集就是整张图（start=0, 全部帧）。
	var r := _range_of("idle")
	for m in [_mat, _xray_mat]:
		m.set_shader_parameter("sheet_cols", int(meta.get("cols", 1)))
		m.set_shader_parameter("sheet_rows", int(meta.get("rows", 1)))
		m.set_shader_parameter("sheet_start", int(r.x))
		m.set_shader_parameter("sheet_frames", int(r.y))
		m.set_shader_parameter("sheet_fps", float(meta.get("fps", 8)))
		m.set_shader_parameter("sheet_phase", phase)
	pixel_size = world_height / ch  # setter 会触发 _refresh_geometry（此时 _sheet 已置）
	offset = Vector2(0.0, ch / 2.0)
	texture = atlas
	_blob_radius = clampf(cw * pixel_size * 0.38, 0.4, 1.4)
	BlobShadow.attach(self, _blob_radius)

## 切动画段（idle / moving / talking）。世界层每帧按角色状态调，同段重复调是零成本快路径。
##
## 只改 sheet_start/sheet_frames 两个 uniform——不动几何、不换贴图。这是安全的，因为服务端
## 各段共用同一个并集裁剪盒（sprite_sheet.ts），cellW/cellH 全段相同；若哪天各段自己裁，
## 这里就必须连 pixel_size/offset 一起重算，角色身高才不会在切段时抽一下。
##
## 图集里没有这一段 → 回落播 idle（_range_of）。**必须回落、不能"保持当前段不动"**：
## 服务端不生成 moving 段（走路是程序化的，见 world.gd），世界层照样每帧请求 "moving"；
## 若这里空操作，角色说完话一走动就永远卡在 talking 帧上——_clip 停在 "talking"，
## 而后续每帧的 set_clip("moving") 都被当成"没这段，不动"，再也回不到 idle。
func set_clip(name: String) -> void:
	if _sheet.is_empty() or name == _clip:
		return
	_clip = name # 记的是"要什么"，不是"落到了哪段"——下一帧同名请求才能走零成本快路径
	var r := _range_of(name)
	for m in [_mat, _xray_mat]:
		m.set_shader_parameter("sheet_start", r.x)
		m.set_shader_parameter("sheet_frames", r.y)

## 当前请求的段名（""=还没进动画模式）。图集里没有这段时实际播的是 idle。
func current_clip() -> String:
	return _clip

## 段名 → Vector2i(start, count)。逐级回落：本段 → idle 段 → 整张图集（v1 单段图集即此路径）。
func _range_of(name: String) -> Vector2i:
	for key in [name, "idle"]:
		var c: Variant = _clips.get(key)
		if typeof(c) == TYPE_DICTIONARY:
			var count := int((c as Dictionary).get("count", 0))
			if count > 0:
				return Vector2i(int((c as Dictionary).get("start", 0)), count)
	return Vector2i(0, int(_sheet.get("frameCount", 0)))

## 可见世界高度（米）：动画图集按单格 cellH 算，静态整图按贴图高算。
## 头顶挂饰定位/相机构图都按这个——整张图集高度是 rows×cellH，会把动画角色算高 rows 倍。
func visible_height() -> float:
	if texture == null:
		return 0.0
	var th := float(texture.get_height())
	if not _sheet.is_empty():
		th = float(_sheet.get("cellH", th))
	return th * pixel_size

## 委托提示 chip 用的小头像：静态角色返回整张立绘；动画角色裁出图集第 0 帧
## （直接用整张图集会把多帧糊成一片）。纹理已随角色降生加载好，同步返回、无需拉取。
func portrait_tex() -> Texture2D:
	if texture == null:
		return null
	if _sheet.is_empty():
		return texture
	var cw := float(_sheet.get("cellW", 0.0))
	var ch := float(_sheet.get("cellH", 0.0))
	if cw <= 0.0 or ch <= 0.0:
		return texture
	var at := AtlasTexture.new()
	at.atlas = texture
	at.region = Rect2(0.0, 0.0, cw, ch)  # 第 0 帧在图集左上角
	return at

# ── 焦点视频 LOD 原语 ────────────────────────────────────────────────────────

## 开启视频 LOD：牌子材质换成抠绿视频 shader，建一个隐藏的 VideoStreamPlayer 只取解码纹理。
## ★核心坑（spike 实证）：VideoStreamPlayer 是 Control，加进树后默认把原始视频画在 2D 层盖住
## 3D 视口——只取解码纹理时必须 visible=false + 挪出屏幕（见 docs/video-hero-lod-design.md）。
## idle/talking 两段传入 VideoStream，起手播 idle；talking 缺省（null）则只有 idle。
## world_height：目标角色世界高度（米），传图集档 visible_height() 保持切换观感不跳；<=0 用当前可见高。
func start_video_lod(idle_stream: VideoStream, talking_stream: VideoStream = null, world_height := 0.0) -> void:
	if idle_stream == null:
		return
	_video_idle = idle_stream
	_video_talking = talking_stream
	_video_height = world_height if world_height > 0.0 else visible_height()
	if _video_mat == null:
		if _video_shader == null:
			_video_shader = load("res://shaders/chroma_video.gdshader")
		_video_mat = ShaderMaterial.new()
		_video_mat.shader = _video_shader
	if _vsp == null:
		_vsp = VideoStreamPlayer.new()
		_vsp.name = "video_lod"
		_vsp.loop = true
		_vsp.volume_db = -80.0
		_vsp.expand = false
		_vsp.visible = false                       # 只取解码纹理，不让它自绘到 2D 层（★核心坑）
		_vsp.position = Vector2(-100000, -100000)  # 双保险：挪出屏幕
		add_child(_vsp)
	_video_lod = true
	_video_clip = "idle"
	_video_wait = 0.0
	_vsp.stream = idle_stream
	_play_vsp()
	# ★不立刻换材质：解码要几十 ms 才吐首帧，此刻换成视频材质会因 video_tex 未设而透明闪一下；
	# 更糟的是平台不支持时永远无帧 → 角色永久隐身。改为在 _process 拿到首帧那刻才无缝换材质，
	# 首帧前一直显示图集档。这就是 P4「ogv 失败/平台不支持 → 静默留图集」的兜底。
	set_process(true)

## 切视频段（idle/talking）：换 VideoStreamPlayer 的 stream，保持单路解码。缺该段（如没 talking
## 原片）→ 保持当前段不动。同段重复调是零成本快路径。
func set_video_clip(name: String) -> void:
	if not _video_lod or name == _video_clip:
		return
	var stream: VideoStream = _video_idle if name == "idle" else _video_talking
	if stream == null:
		return  # 没这段原片 → 保持当前段
	_video_clip = name
	_vsp.stream = stream
	_play_vsp()

## VideoStreamPlayer.play() 要求节点已在树内（否则 ERR_FAIL）。正常路径（world.gd 在活动
## 场景里对已 spawn 的角色调）必在树内；防御性地对「尚未入树」延迟到入树后再播。
func _play_vsp() -> void:
	if _vsp.is_inside_tree():
		_vsp.play()
	else:
		_vsp.play.call_deferred()

## 撤回视频 LOD：停播、释放 VideoStreamPlayer（无残留解码/泄漏）、材质换回图集档、几何复原。幂等。
func stop_video_lod() -> void:
	if not _video_lod:
		return
	_video_lod = false
	_video_clip = ""
	set_process(false)
	if _vsp != null:
		_vsp.stop()
		_vsp.queue_free()
		_vsp = null
	material_override = _mat  # 换回图集主材质（含其 xray next_pass）
	_refresh_geometry()       # 从图集档的 texture/_sheet/pixel_size/offset 复原 quad 几何

func is_video_lod() -> bool:
	return _video_lod

## 当前请求的视频段名（""=没在视频档）。
func current_video_clip() -> String:
	return _video_clip

func _process(delta: float) -> void:
	if not _video_lod or _vsp == null:
		return
	var vt := _vsp.get_video_texture()
	# 坏流/平台不支持时 get_video_texture 返回的不是 null，而是一张 0×0 的空纹理（实测）——
	# 必须按尺寸判有无真帧，只判 null 会把空纹理当成有效帧、换过去后角色变黑/透明。
	if vt == null or vt.get_width() <= 0 or vt.get_height() <= 0:
		# 还没首帧：累计等待，超时判定平台不支持/坏流 → 撤回留图集（别让解码器空转）。
		_video_wait += delta
		if _video_wait > VIDEO_FIRST_FRAME_TIMEOUT:
			stop_video_lod()
		return
	_video_mat.set_shader_parameter("video_tex", vt)
	if material_override != _video_mat:
		# 首帧到手：此刻才无缝把图集换成视频（之前一直显图集，无透明闪）。
		# 同帧按真视频宽高比重算几何——目标身高取自图集档 visible_height，故切换观感不跳。
		_apply_video_geometry(vt)
		material_override = _video_mat  # 视频档不带 xray next_pass（穿透剪影是图集档专属）

## 首帧到手后按视频宽高比重算 quad 几何：让视频里的角色（竖向占 VIDEO_FILL）身高对齐图集档身高、
## 脚底落在节点原点。只改 QuadMesh 尺寸/中心偏移——不碰 texture/_sheet/pixel_size/offset（那是图集档
## 状态，stop 时 _refresh_geometry 靠它复原）。VIDEO_FILL/VIDEO_FOOT 是 P3/P4 真机调参旋钮。
func _apply_video_geometry(vt: Texture2D) -> void:
	var vw := float(vt.get_width())
	var vh := float(vt.get_height())
	if vw <= 0.0 or vh <= 0.0 or _video_height <= 0.0:
		return
	var frame_h := _video_height / VIDEO_FILL   # 整帧世界高（角色只占其中 VIDEO_FILL）
	var frame_w := frame_h * (vw / vh)
	var q := mesh as QuadMesh
	q.size = Vector2(frame_w, frame_h)
	# 脚底（帧内归一化 y=VIDEO_FOOT，原点顶）对齐节点原点 y=0 → center_offset.y = frame_h*(VIDEO_FOOT-0.5)
	q.center_offset = Vector3(0.0, frame_h * (VIDEO_FOOT - 0.5), 0.0)

func _refresh_geometry() -> void:
	if texture == null:
		return
	# sprite-sheet 模式按单格尺寸算几何（整张图集含多格，可见的只有一格）
	var tw := float(texture.get_width())
	var th := float(texture.get_height())
	if not _sheet.is_empty():
		tw = float(_sheet.get("cellW", tw))
		th = float(_sheet.get("cellH", th))
	var w := tw * pixel_size
	var h := th * pixel_size
	var q := mesh as QuadMesh
	q.size = Vector2(w, h)
	q.center_offset = Vector3(offset.x * pixel_size, offset.y * pixel_size, 0.0)
	_mat.set_shader_parameter("quad_size", Vector2(w, h))
	_xray_mat.set_shader_parameter("quad_size", Vector2(w, h))
