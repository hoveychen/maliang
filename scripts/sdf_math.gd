class_name SdfMath
extends RefCounted
## SDF blend-shell 的 CPU 侧数学库：基本体符号距离场、smooth-min 融合、梯度与表面投影。
## 与 shaders/sdf_blend_shell.gdshader 的 GLSL 实现一一对应——CPU 侧供单测校验与
## 构建期计算（包围盒/埋没判定），GPU 侧在顶点阶段做同样的吸附。两边改必须同步改。
##
## 约定：基本体自身不带缩放（xform 仅旋转+平移），尺寸全部走 params，
## 这样距离场保持真实距离（缩放会破坏 SDF 的度量，投影迭代不收敛）。

const SHAPE_SPHERE := 0
const SHAPE_CAPSULE := 1  ## params: x=半径, y=半身长（两球心距的一半），沿局部 Y
const SHAPE_CONE := 2     ## 圆头锥: x=底半径(y=-半高处), y=顶半径(y=+半高处), z=半高
const SHAPE_BOX := 3      ## params: xyz=半边长，圆角=最小半边长×BOX_ROUND_FRAC

const BOX_ROUND_FRAC := 0.2

## 单个 SDF 基本体。xform 是基本体局部→物件空间。
class Prim:
	var shape: int = SdfMath.SHAPE_SPHERE
	var params := Vector3.ZERO
	var color := Color.WHITE
	var blend := 0.25  ## 参与融合的最大 blend 半径；细件（天线/幌杆）调小防被吞掉
	var xform := Transform3D.IDENTITY:
		set(v):
			xform = v
			inv = v.affine_inverse()
	var inv := Transform3D.IDENTITY

static func sphere(pos: Vector3, r: float, color := Color.WHITE, blend := 0.25) -> Prim:
	var p := Prim.new()
	p.shape = SHAPE_SPHERE
	p.params = Vector3(r, 0.0, 0.0)
	p.color = color
	p.blend = blend
	p.xform = Transform3D(Basis.IDENTITY, pos)
	return p

static func capsule(xform: Transform3D, r: float, half_len: float, color := Color.WHITE, blend := 0.25) -> Prim:
	var p := Prim.new()
	p.shape = SHAPE_CAPSULE
	p.params = Vector3(r, half_len, 0.0)
	p.color = color
	p.blend = blend
	p.xform = xform
	return p

static func cone(xform: Transform3D, r_bottom: float, r_top: float, half_h: float, color := Color.WHITE, blend := 0.25) -> Prim:
	var p := Prim.new()
	p.shape = SHAPE_CONE
	p.params = Vector3(r_bottom, r_top, half_h)
	p.color = color
	p.blend = blend
	p.xform = xform
	return p

static func box(xform: Transform3D, half_extents: Vector3, color := Color.WHITE, blend := 0.25) -> Prim:
	var p := Prim.new()
	p.shape = SHAPE_BOX
	p.params = half_extents
	p.color = color
	p.blend = blend
	p.xform = xform
	return p

## 让局部 Y 轴对准 a→b、原点在中点的刚体变换（腿骨/绳段摆位用）。
static func between_xform(a: Vector3, b: Vector3) -> Transform3D:
	var d := b - a
	var dir := d / maxf(d.length(), 1e-6)
	var q: Quaternion
	if dir.dot(Vector3.UP) < -0.9999:
		q = Quaternion(Vector3.RIGHT, PI)
	else:
		q = Quaternion(Vector3.UP, dir)
	return Transform3D(Basis(q), (a + b) * 0.5)

## 两球心分别在 a、b 的胶囊。
static func capsule_between(a: Vector3, b: Vector3, r: float, color := Color.WHITE, blend := 0.25) -> Prim:
	return capsule(between_xform(a, b), r, a.distance_to(b) * 0.5, color, blend)

## 底球心在 a（半径 r1）、顶球心在 b（半径 r2）的圆头锥。
static func cone_between(a: Vector3, b: Vector3, r1: float, r2: float, color := Color.WHITE, blend := 0.25) -> Prim:
	return cone(between_xform(a, b), r1, r2, a.distance_to(b) * 0.5, color, blend)

## ---- 距离场 ----

static func prim_dist(pr: Prim, p: Vector3) -> float:
	var lp := pr.inv * p
	match pr.shape:
		SHAPE_SPHERE:
			return lp.length() - pr.params.x
		SHAPE_CAPSULE:
			var q := lp
			q.y -= clampf(q.y, -pr.params.y, pr.params.y)
			return q.length() - pr.params.x
		SHAPE_CONE:
			return _round_cone(lp, pr.params.x, pr.params.y, pr.params.z)
		SHAPE_BOX:
			return _round_box(lp, pr.params)
	return 1e9

## IQ 的 sdRoundCone：底球(半径 r1)在 y=-half_h，顶球(半径 r2)在 y=+half_h。
static func _round_cone(p: Vector3, r1: float, r2: float, half_h: float) -> float:
	var h := 2.0 * half_h
	var py := p.y + half_h  # 平移到底球在原点的 IQ 参考系
	var b := clampf((r1 - r2) / maxf(h, 1e-6), -0.999, 0.999)
	var a := sqrt(1.0 - b * b)
	var qx := Vector2(p.x, p.z).length()
	var q := Vector2(qx, py)
	var k := q.dot(Vector2(-b, a))
	if k < 0.0:
		return q.length() - r1
	if k > a * h:
		return (q - Vector2(0.0, h)).length() - r2
	return q.dot(Vector2(a, b)) - r1

static func _round_box(p: Vector3, he: Vector3) -> float:
	var rr := minf(he.x, minf(he.y, he.z)) * BOX_ROUND_FRAC
	var q := p.abs() - he + Vector3(rr, rr, rr)
	var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length()
	var inside := minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
	return outside + inside - rr

## 多项式 smooth-min：k 越大融合越圆润。k→0 退化为 min。
static func smin(a: float, b: float, k: float) -> float:
	if k <= 1e-6:
		return minf(a, b)
	var h := clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
	return lerpf(b, a, h) - k * h * (1.0 - h)

## 整组基本体的融合距离场。逐个 smin 折叠；每步的 blend 半径取
## min(全局 k, 该基本体的 blend 上限)——细件因此不会被大件吞没。
static func eval(prims: Array, p: Vector3, k: float) -> float:
	var d := 1e9
	for pr: Prim in prims:
		d = smin(d, prim_dist(pr, p), minf(k, pr.blend))
	return d

## 四面体四采样数值梯度（比六采样省 2 次求值，精度够用）。
static func gradient(prims: Array, p: Vector3, k: float, eps := 0.01) -> Vector3:
	var g := Vector3.ZERO
	for s: Vector3 in [
		Vector3(1, -1, -1), Vector3(-1, -1, 1), Vector3(-1, 1, -1), Vector3(1, 1, 1),
	]:
		g += s * eval(prims, p + s * eps, k)
	return g / (4.0 * eps)

## 把点沿梯度投影到 iso 等值面（iso=0 即表面；负值在皮下）。
## 返回投影后的点；迭代数固定，误差由单测约束。
static func project(prims: Array, p: Vector3, k: float, iso := 0.0, iters := 6) -> Vector3:
	var q := p
	for _i in range(iters):
		var d := eval(prims, q, k) - iso
		if absf(d) < 1e-4:
			break
		var g := gradient(prims, q, k)
		var len := g.length()
		if len < 1e-6:
			break
		q -= g / len * d
	return q

## 整组基本体在静止姿态下的保守包围盒（含 blend 外扩）。
static func rest_aabb(prims: Array, margin := 0.1) -> AABB:
	var aabb := AABB()
	var first := true
	for pr: Prim in prims:
		var r := pr.params.x + pr.blend + margin
		match pr.shape:
			SHAPE_CAPSULE, SHAPE_CONE:
				r += maxf(pr.params.y, pr.params.z)
			SHAPE_BOX:
				r = pr.params.length() + pr.blend + margin
		var c := pr.xform.origin
		var b := AABB(c - Vector3(r, r, r), Vector3(2 * r, 2 * r, 2 * r))
		aabb = b if first else aabb.merge(b)
		first = false
	return aabb
