class_name Item3DViewer
extends SubViewportContainer
## 物品详情页的 live 3D 查看器（item-detail-3d）：把造物的**真实 3D 模型**放进一个透明底
## SubViewport 里连续渲染，绕 Y 慢慢自转；小朋友按住拖动可自己转着看（水平转为主，竖直小幅俯仰）。
## 松手继续自转。贴纸/无 3D 的物品不该用它（调用方回落平面图）。
##
## 与缩略图（ItemThumbnailer）的区别：那边是「离屏渲一张静态图」——多件按需连续渲会撞 SubViewport
## 冻结坑；这边是「一个视口一直显」，UPDATE_ALWAYS 连续渲染正是要的（同主游戏视口）。造节点复用
## ItemThumbnailer.build_item_node（同一份 renderRef 分发，不重复）。
##
## 生命周期：调用方 setup(def)；换物品/退详情/翻页时 free 掉本控件即整树连视口一起释放（不常驻吃 GPU）。

const AUTO_SPIN_DEG_PER_SEC := 24.0   ## 自转速度（慢，别晃眼）
const DRAG_YAW_DEG_PER_PX := 0.55     ## 水平拖动灵敏度（绕 Y）
const DRAG_PITCH_DEG_PER_PX := 0.35   ## 竖直拖动灵敏度（俯仰）
const PITCH_MIN := -35.0              ## 俯仰下限（别翻到看底面）
const PITCH_MAX := 60.0               ## 俯仰上限
const CAM_ELEV_DEG := 35.0            ## 相机基础俯角（3/4 斜俯：够高不见帽/顶底面「屁股」，又不至于压成正俯视）
const RESUME_SPIN_AFTER := 1.2        ## 松手后多久恢复自转（秒）

var _vp: SubViewport = null
var _pivot: Node3D = null             ## 模型挂在它下面、绕它转（居中到 AABB 中心）
var _cam: Camera3D = null
var _yaw := 0.0
var _pitch := 0.0
var _dragging := false
var _idle_since := 0.0                ## 松手计时（到 RESUME_SPIN_AFTER 才恢复自转）
var _ready_ok := false
var _node: Node3D = null              ## 造出的 3D 模型（_ready 里进树后再取景）

func setup(def: Dictionary) -> bool:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP # 自己吃拖动，别透给底下
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS # live 连续渲染（自转要每帧刷）
	_vp.msaa_3d = Viewport.MSAA_4X
	add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -40, 0)
	sun.light_energy = 1.2
	_vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 140, 0)
	fill.light_energy = 0.4
	_vp.add_child(fill)

	_cam = Camera3D.new()
	_cam.near = 0.01
	_cam.far = 100000.0
	_vp.add_child(_cam)
	_pivot = Node3D.new()
	_vp.add_child(_pivot)

	var node := ItemThumbnailer.build_item_node(def)
	if node == null:
		return false # 贴纸/无 3D → 调用方回落平面图
	_pivot.add_child(node)
	_node = node
	return true # 取景在 _ready（进树后 get_tree 才非空）

func _ready() -> void:
	if _node != null:
		_frame_when_ready(_node)

## 等几帧让 SDF 顶点吸附/transform 摆定，再据 AABB 把模型居中到 pivot、摆相机。
func _frame_when_ready(node: Node3D) -> void:
	for _i in range(6):
		await get_tree().process_frame
	if not is_instance_valid(node) or not is_instance_valid(_cam):
		return
	var aabb := ItemThumbnailer.item_node_aabb(node)
	if aabb.size == Vector3.ZERO:
		aabb = AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1, 1))
	var center := aabb.position + aabb.size * 0.5
	node.position -= center # 视觉中心移到 pivot 原点，绕 pivot 转不偏心
	var radius := aabb.size.length() * 0.5
	# 相机固定在 pivot 前斜俯位；模型靠 pivot 旋转，相机不动（构图稳定）。
	var elev := deg_to_rad(CAM_ELEV_DEG)
	var dist := maxf(radius * 1.35 / tan(deg_to_rad(_cam.fov * 0.5)), 0.6)
	_cam.position = Vector3(0, sin(elev) * dist, cos(elev) * dist)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	_ready_ok = true

func _process(delta: float) -> void:
	if not _ready_ok or _pivot == null:
		return
	# 性能：手机收起/翻到别页时本控件不可见 → 停视口渲染（UPDATE_ALWAYS 会一直吃 GPU），
	# 也不自转（看不见白转）。重新可见即恢复。
	var vis := is_visible_in_tree()
	if _vp != null:
		var want := SubViewport.UPDATE_ALWAYS if vis else SubViewport.UPDATE_DISABLED
		if _vp.render_target_update_mode != want:
			_vp.render_target_update_mode = want
	if not vis:
		return
	if not _dragging:
		if _idle_since < RESUME_SPIN_AFTER:
			_idle_since += delta
		if _idle_since >= RESUME_SPIN_AFTER:
			_yaw += AUTO_SPIN_DEG_PER_SEC * delta
	_apply_rot()

func _apply_rot() -> void:
	_pivot.rotation = Vector3(deg_to_rad(_pitch), deg_to_rad(_yaw), 0.0)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or (event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT):
		_dragging = event.pressed
		if not event.pressed:
			_idle_since = 0.0 # 松手：计时归零，RESUME_SPIN_AFTER 后恢复自转
		accept_event()
	elif event is InputEventScreenDrag or (event is InputEventMouseMotion and _dragging):
		var rel: Vector2 = (event as InputEventScreenDrag).relative if event is InputEventScreenDrag else (event as InputEventMouseMotion).relative
		_yaw += rel.x * DRAG_YAW_DEG_PER_PX          # 水平拖 → 绕 Y 转（主）
		_pitch = clampf(_pitch + rel.y * DRAG_PITCH_DEG_PER_PX, PITCH_MIN, PITCH_MAX) # 竖直拖 → 小幅俯仰
		_idle_since = 0.0
		_apply_rot()
		accept_event()
