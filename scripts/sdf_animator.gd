class_name SdfAnimator
extends RefCounted
## SDF 物件的程序化动画驱动——没有任何动画片段，全部实时生成：
##   walker  2/4/6 腿共用一套反应式 IK 步态（腿分组交替，脚锚定在父空间不滑步）
##   hopper  蹲伸状态机（蓄力压扁→抛物线腾空拉伸→落地缓冲）
##   flyer   悬停浮动+振翅+朝速度方向倾侧
##   none    待机呼吸
## 控制器（游走/指令）只需要做两件事：移动节点本身 + 每帧喂 move_vel（物件局部空间平面速度）。
## 动画结果写回 prims 的 xform/params，由 SdfProp.push_uniforms 送进 shader 重新吸附。

var prop: SdfProp
var move_vel := Vector3.ZERO  ## 物件局部空间期望速度（y 忽略）
var time := 0.0

var _loco: Dictionary
var _rest: Array[Transform3D] = []
var _rest_params: Array[Vector3] = []
var _phase := 0.0

# walker：每腿一份脚步状态；脚锚存父空间（跟地面走，节点移动才会触发迈步）
var _feet: Array[Dictionary] = []
var _groups: Array = []  ## 交替迈步的腿分组（索引进 meta.legs）

# hopper 状态机
var _hop_state := "idle"
var _hop_t := 0.0
var _hop_y := 0.0
var _hop_vy := 0.0

# 物理绳（verlet）：点存父空间，锚点钉在身体件上；绳段基本体每帧按点重摆
var _rope_pts: Array[PackedVector3Array] = []
var _rope_prev: Array[PackedVector3Array] = []

const ROPE_GRAVITY := Vector3(0, -6.5, 0)  ## 装饰性偏轻的重力，甩起来更"纸"
const ROPE_DAMP := 0.985
const ROPE_ITERS := 3

const STEP_DUR := 0.18       ## 单步耗时
const STEP_TRIGGER := 0.22   ## 脚锚偏离期望位置多远触发迈步（×hip_h）
const HOP_GRAVITY := 14.0
const CROUCH_DUR := 0.16
const LAND_DUR := 0.14

func _init(p: SdfProp) -> void:
	prop = p
	_loco = p.config.locomotion
	for pr: SdfMath.Prim in p.prims:
		_rest.append(pr.xform)
		_rest_params.append(pr.params)
	var legs: Array = p.meta.legs
	for _i in range(legs.size()):
		_feet.append({"anchor": Vector3.ZERO, "t": -1.0, "from": Vector3.ZERO, "to": Vector3.ZERO})
	match legs.size():
		2: _groups = [[0], [1]]
		4: _groups = [[0, 3], [1, 2]]
		6: _groups = [[0, 3, 4], [1, 2, 5]]
	reset_pose()

## 把脚锚与绳点重置到当前节点姿态下的静止位（初始化/被瞬移后调用）。
func reset_pose() -> void:
	var xf := _prop_xf()
	for i in range(_feet.size()):
		_feet[i].anchor = xf * (prop.meta.legs[i].foot_rest as Vector3)
		_feet[i].t = -1.0
	_rope_pts.clear()
	_rope_prev.clear()
	for rope in prop.meta.ropes:
		var pts := PackedVector3Array()
		for p in rope.rest_points:
			pts.append(xf * p)
		_rope_pts.append(pts)
		_rope_prev.append(pts.duplicate())

func advance(delta: float) -> void:
	delta = minf(delta, 0.05)  # 掉帧保护：verlet 大步长会爆
	time += delta
	match str(_loco.type):
		"walker": _advance_walker(delta)
		"hopper": _advance_hopper(delta)
		"flyer": _advance_flyer(delta)
		_: _apply_body(_breath_xf())
	_ropes_step(delta)

## 当前是否允许平移（hopper 只在腾空段位移，蹲伸阶段原地蓄力）。
func can_translate() -> bool:
	return str(_loco.type) != "hopper" or _hop_state == "air"

## ---- 通用 ----

func _prop_xf() -> Transform3D:
	return prop.transform

## 把身体组（body/head）按 body_xf 相对静止姿态摆位；head 额外一点点点头/摇头；
## 带 spin 的件绕各自 pivot/axis 持续旋转（风车叶/陀螺——多件共用 pivot 即刚性同转）。
func _apply_body(body_xf: Transform3D) -> void:
	var head_xf := body_xf * Transform3D(
		Basis.from_euler(Vector3(sin(time * 1.7) * 0.05, sin(time * 1.1) * 0.08, 0.0)), Vector3.ZERO)
	for b in prop.meta.body:
		var xf := head_xf if b.group == "head" else body_xf
		var rest: Transform3D = b.rest
		var spin: Dictionary = b.get("spin", {})
		if not spin.is_empty():
			var pivot: Vector3 = spin.pivot
			var rot := Transform3D(Basis(spin.axis as Vector3, time * float(spin.rate) * TAU), Vector3.ZERO)
			rest = Transform3D(Basis.IDENTITY, pivot) * rot * Transform3D(Basis.IDENTITY, -pivot) * rest
		prop.prims[b.idx].xform = xf * rest

func _breath_xf() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0, sin(time * 1.6) * 0.02, 0))

## ---- walker：反应式 IK 步态 ----

func _advance_walker(delta: float) -> void:
	var legs: Array = prop.meta.legs
	var speed := Vector2(move_vel.x, move_vel.z).length()
	var hip_h: float = _loco.hip_h
	_phase += delta * (1.5 + speed * 2.0)

	# 身体：走动上下颠 + 微前倾；停下时呼吸
	var bob := absf(sin(_phase * 2.0)) * 0.035 * hip_h * clampf(speed / maxf(_loco.speed, 0.1), 0.0, 1.0)
	var lean := clampf(speed * 0.06, 0.0, 0.1)
	var body_xf := Transform3D(Basis.from_euler(Vector3(lean, 0, sin(_phase) * lean * 0.4)),
		Vector3(0, bob + (sin(time * 1.6) * 0.015 if speed < 0.05 else 0.0), 0))
	_apply_body(body_xf)

	var xf := _prop_xf()
	var inv := xf.affine_inverse()

	# 迈步决策：偏离期望落点超过阈值就迈步；两组交替，另一组有脚在空中时本组等待
	for gi in range(_groups.size()):
		var other_stepping := false
		var oi := (gi + 1) % _groups.size()
		for li in _groups[oi]:
			if _feet[li].t >= 0.0:
				other_stepping = true
		for li in _groups[gi]:
			var leg: Dictionary = legs[li]
			var f: Dictionary = _feet[li]
			if f.t >= 0.0:
				continue
			var desired_obj: Vector3 = leg.foot_rest + Vector3(move_vel.x, 0, move_vel.z) * 0.15
			var anchor_obj: Vector3 = inv * (f.anchor as Vector3)
			var err := Vector2(anchor_obj.x - desired_obj.x, anchor_obj.z - desired_obj.z).length()
			var trigger := STEP_TRIGGER * hip_h * (1.0 if speed > 0.05 else 1.6)
			if err > trigger and not other_stepping:
				f.t = 0.0
				f.from = f.anchor
				# 落点再往运动方向多带半步，减少小碎步
				f.to = xf * (desired_obj + Vector3(move_vel.x, 0, move_vel.z) * STEP_DUR * 0.6)

	# 推进迈步 + IK 解算写回腿骨
	for li in range(legs.size()):
		var leg: Dictionary = legs[li]
		var f: Dictionary = _feet[li]
		var foot_parent: Vector3 = f.anchor
		if f.t >= 0.0:
			f.t += delta / STEP_DUR
			if f.t >= 1.0:
				f.anchor = f.to
				f.t = -1.0
				foot_parent = f.anchor
			else:
				var t: float = ease(f.t, -1.8)  # 缓入缓出
				foot_parent = (f.from as Vector3).lerp(f.to, t)
				foot_parent.y += sin(PI * f.t) * (0.1 + 0.25 * hip_h * clampf(speed, 0.0, 1.0)) * 0.5
		var foot_obj: Vector3 = inv * foot_parent
		var hip_cur: Vector3 = _hip_now(leg)
		var side := signf((leg.hip as Vector3).x)
		# 步幅超过腿长时把脚往髋方向收，保证 IK 有解
		var reach: float = leg.seg_len * 2.0 * 0.995
		if hip_cur.distance_to(foot_obj) > reach:
			foot_obj = hip_cur + (foot_obj - hip_cur).normalized() * reach
		var knee := SdfSpec.solve_knee(hip_cur, foot_obj, leg.seg_len, side)
		prop.prims[leg.upper].xform = SdfMath.between_xform(hip_cur, knee)
		prop.prims[leg.lower].xform = SdfMath.between_xform(knee, foot_obj)

func _hip_now(leg: Dictionary) -> Vector3:
	# 髋挂在身体上：跟随身体件的刚体增量
	return _body_delta_xf() * (leg.hip as Vector3)

## ---- hopper：蹲伸状态机 ----

func _advance_hopper(delta: float) -> void:
	_hop_t += delta
	var squash := 1.0
	match _hop_state:
		"idle":
			if _hop_t > 0.9 / maxf(float(_loco.rate), 0.2):
				_hop_state = "crouch"
				_hop_t = 0.0
		"crouch":
			squash = lerpf(1.0, 0.72, ease(clampf(_hop_t / CROUCH_DUR, 0.0, 1.0), -1.6))
			if _hop_t >= CROUCH_DUR:
				_hop_state = "air"
				_hop_t = 0.0
				_hop_vy = sqrt(2.0 * HOP_GRAVITY * float(_loco.hop_h))
		"air":
			_hop_y += _hop_vy * delta
			_hop_vy -= HOP_GRAVITY * delta
			squash = clampf(1.0 + absf(_hop_vy) * 0.045, 1.0, 1.18)
			if _hop_y <= 0.0 and _hop_vy < 0.0:
				_hop_y = 0.0
				_hop_state = "land"
				_hop_t = 0.0
		"land":
			squash = lerpf(0.76, 1.0, ease(clampf(_hop_t / LAND_DUR, 0.0, 1.0), -1.6))
			if _hop_t >= LAND_DUR:
				_hop_state = "idle"
				_hop_t = 0.0
	if _hop_state == "idle":
		_apply_body(_breath_xf())
	else:
		_apply_squash(squash, _hop_y)

## 以地面为基准的压扁/拉伸：位置按 (sx, sy, sx) 缩放，
## 尺寸按各件长轴的"竖直程度"插值缩放（旋转过的件也能得到合理近似）。
func _apply_squash(sy: float, y_off: float) -> void:
	var sx := 1.0 / sqrt(maxf(sy, 0.2))
	for b in prop.meta.body:
		var rest: Transform3D = b.rest
		var o := rest.origin
		var pos := Vector3(o.x * sx, o.y * sy + y_off, o.z * sx)
		prop.prims[b.idx].xform = Transform3D(rest.basis, pos)
		var axis_up := absf((rest.basis * Vector3.UP).y)
		var long_s := lerpf(sx, sy, axis_up)
		var rad_s := lerpf((sx + sy) * 0.5, sx, axis_up)
		var rp: Vector3 = _rest_params[b.idx]
		var pr: SdfMath.Prim = prop.prims[b.idx]
		match pr.shape:
			SdfMath.SHAPE_SPHERE:
				pr.params = rp * ((sx * 2.0 + sy) / 3.0)
			SdfMath.SHAPE_CAPSULE:
				pr.params = Vector3(rp.x * rad_s, rp.y * long_s, 0.0)
			SdfMath.SHAPE_CONE:
				pr.params = Vector3(rp.x * rad_s, rp.y * rad_s, rp.z * long_s)
			SdfMath.SHAPE_BOX:
				pr.params = Vector3(rp.x * sx, rp.y * sy, rp.z * sx)

## ---- 物理绳：verlet 链，绳段即 SDF 基本体 ----

## 点在父空间积分（节点跑动/跳跃时绳自然甩动），锚点钉在身体件的当前姿态上；
## 距离约束迭代收敛后，把每段圆头锥基本体重摆到相邻两点之间——
## 绳段和身体在同一个 smooth-min 场里，甩动中依然无缝融合。
func _ropes_step(delta: float) -> void:
	var ropes: Array = prop.meta.ropes
	if ropes.is_empty():
		return
	var xf := _prop_xf()
	var inv := xf.affine_inverse()
	var body_delta := _body_delta_xf()
	var dt2 := delta * delta
	for ri in range(ropes.size()):
		var rope: Dictionary = ropes[ri]
		var pts := _rope_pts[ri]
		var prev := _rope_prev[ri]
		# 锚点跟身体动画走
		pts[0] = xf * (body_delta * (rope.anchor as Vector3))
		# verlet 积分（跳过锚点），带一点随时间的微风让静止时也有生气
		var wind := Vector3(sin(time * 1.3 + float(ri) * 2.1), 0, cos(time * 0.9)) * 0.35
		for k in range(1, pts.size()):
			var cur := pts[k]
			pts[k] = cur + (cur - prev[k]) * ROPE_DAMP + (ROPE_GRAVITY + wind) * dt2
			prev[k] = cur
		# 距离约束：保持段长（锚点视为无限质量）
		var seg_len: float = rope.seg_len
		for _it in range(ROPE_ITERS):
			for k in range(pts.size() - 1):
				var d := pts[k + 1] - pts[k]
				var l := d.length()
				if l < 1e-6:
					continue
				var corr := d * ((l - seg_len) / l)
				if k == 0:
					pts[k + 1] -= corr
				else:
					pts[k] += corr * 0.5
					pts[k + 1] -= corr * 0.5
		# 写回绳段基本体（物件空间）
		for k in range(int(rope.count)):
			var a := inv * pts[k]
			var b := inv * pts[k + 1]
			prop.prims[int(rope.start) + k].xform = SdfMath.between_xform(a, b)

## 身体件相对静止姿态的刚体增量（绳锚/髋关节挂载用）。
func _body_delta_xf() -> Transform3D:
	var body: Array = prop.meta.body
	if body.is_empty():
		return Transform3D.IDENTITY
	var b0: Dictionary = body[0]
	return prop.prims[b0.idx].xform * (b0.rest as Transform3D).affine_inverse()

## ---- flyer：悬停+振翅+倾侧 ----

func _advance_flyer(delta: float) -> void:
	var hover := sin(time * 1.9) * 0.07 + sin(time * 0.7) * 0.03
	var bank := clampf(-move_vel.x * 0.35, -0.4, 0.4)
	var pitch := clampf(move_vel.z * 0.3, -0.35, 0.35)
	var body_xf := Transform3D(Basis.from_euler(Vector3(pitch, 0, bank)), Vector3(0, hover, 0))
	_apply_body(body_xf)
	var flap := sin(time * TAU * float(_loco.rate)) * 0.55 - 0.12
	for w in prop.meta.wings:
		var shoulder: Vector3 = w.shoulder
		var rot := Transform3D(Basis(Vector3(0, 0, 1), -w.side * flap), Vector3.ZERO)
		var pivot := Transform3D(Basis.IDENTITY, shoulder) * rot * Transform3D(Basis.IDENTITY, -shoulder)
		prop.prims[w.idx].xform = body_xf * pivot * (_rest[w.idx] as Transform3D)
