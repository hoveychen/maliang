class_name SdfSpec
extends RefCounted
## SDF 物件的 JSON spec 解析与骨架（rig）搭建。
## 一只可动物件 ≈ 15 行 JSON：调色板 + 若干"身体件"（球/胶囊/圆头锥/圆角盒）
## + 一种运动方式（walker 2/4/6 腿 | hopper | flyer | none）+ 若干物理绳。
## 腿/翅膀/绳段不用手摆——由 locomotion/ropes 配置程序化生成，LLM 只描述"长什么样、怎么动"。
##
## parse() 做校验并补默认值（LLM 产物必须过这关才能进场景）；
## build_rig() 产出静止姿态基本体数组 + 动画元数据（索引/骨长/锚点），供 SdfProp/SdfAnimator 用。

const MAX_PRIMS := 24  ## 与 shaders/sdf_field.gdshaderinc 的 MAX_PRIMS 一致

const SHAPE_NAMES := {
	"sphere": SdfMath.SHAPE_SPHERE,
	"capsule": SdfMath.SHAPE_CAPSULE,
	"cone": SdfMath.SHAPE_CONE,
	"box": SdfMath.SHAPE_BOX,
}
const LOCO_TYPES := ["none", "walker", "hopper", "flyer"]

## 解析并校验 spec。返回 {"ok": true, ...config} 或 {"ok": false, "error": 原因}。
static func parse(spec: Dictionary) -> Dictionary:
	var name := str(spec.get("name", "prop"))
	var palette: Array[Color] = []
	for c in spec.get("palette", ["#c9c9c9"]):
		var col := Color.from_string(str(c), Color.TRANSPARENT)
		if col == Color.TRANSPARENT:
			return _err("palette 颜色不合法: %s" % str(c))
		palette.append(col)
	if palette.is_empty():
		return _err("palette 为空")

	var parts: Array[Dictionary] = []
	var raw_parts: Array = spec.get("parts", [])
	if raw_parts.is_empty():
		return _err("parts 为空")
	for rp in raw_parts:
		if not (rp is Dictionary):
			return _err("parts 项不是对象")
		var shape_name := str(rp.get("shape", ""))
		if not SHAPE_NAMES.has(shape_name):
			return _err("未知形状: %s" % shape_name)
		var shape: int = SHAPE_NAMES[shape_name]
		var pos := _vec3(rp.get("pos", [0, 0, 0]))
		var params := Vector3.ZERO
		match shape:
			SdfMath.SHAPE_SPHERE:
				params = Vector3(_f(rp.get("r", 0.2)), 0.0, 0.0)
			SdfMath.SHAPE_CAPSULE:
				params = Vector3(_f(rp.get("r", 0.15)), _f(rp.get("len", 0.4)) * 0.5, 0.0)
			SdfMath.SHAPE_CONE:
				params = Vector3(_f(rp.get("r1", 0.3)), _f(rp.get("r2", 0.1)), _f(rp.get("h", 0.4)) * 0.5)
			SdfMath.SHAPE_BOX:
				params = _vec3(rp.get("size", [0.4, 0.4, 0.4])) * 0.5
		if params.x <= 0.0:
			return _err("%s 尺寸必须为正" % shape_name)
		var ci := int(rp.get("color", 0))
		if ci < 0 or ci >= palette.size():
			return _err("color 索引越界: %d" % ci)
		var rot_deg := _vec3(rp.get("rot", [0, 0, 0]))
		parts.append({
			"shape": shape,
			"pos": pos,
			"rot": Basis.from_euler(rot_deg * (PI / 180.0)),
			"params": params,
			"color": palette[ci],
			"blend": _f(rp.get("blend", -1.0)),  # <0 表示用全局 blend
			"group": str(rp.get("group", "body")),
		})

	var raw_loco: Dictionary = spec.get("locomotion", {})
	var loco_type := str(raw_loco.get("type", "none"))
	if not LOCO_TYPES.has(loco_type):
		return _err("未知 locomotion.type: %s" % loco_type)
	var legs := int(raw_loco.get("legs", 4))
	if loco_type == "walker" and not (legs in [2, 4, 6]):
		return _err("walker 腿数只支持 2/4/6, 收到 %d" % legs)
	var loco := {
		"type": loco_type,
		"legs": legs,
		"leg_r": _f(raw_loco.get("leg_r", 0.1)),
		"hip_h": _f(raw_loco.get("hip_h", 0.6)),
		"stance": _vec2(raw_loco.get("stance", [0.4, 0.35])),
		"hop_h": _f(raw_loco.get("hop_h", 0.45)),
		"rate": _f(raw_loco.get("rate", 1.4)),
		"hover_h": _f(raw_loco.get("hover_h", 1.2)),
		"wing_r": _f(raw_loco.get("wing_r", 0.06)),
		"wing_len": _f(raw_loco.get("wing_len", 0.35)),
		"wing_pos": _vec3(raw_loco.get("wing_pos", [0.3, 1.5, 0.0])),
		"speed": _f(raw_loco.get("speed", 0.8)),
	}

	var ropes: Array[Dictionary] = []
	for rr in spec.get("ropes", []):
		if not (rr is Dictionary):
			return _err("ropes 项不是对象")
		var segs := int(rr.get("segments", 3))
		if segs < 1 or segs > 8:
			return _err("rope segments 需在 1..8, 收到 %d" % segs)
		var rci := int(rr.get("color", 0))
		if rci < 0 or rci >= palette.size():
			return _err("rope color 索引越界: %d" % rci)
		ropes.append({
			"anchor": _vec3(rr.get("pos", [0, 0.5, 0])),
			"segments": segs,
			"r": _f(rr.get("r", 0.06)),
			"seg_len": _f(rr.get("len", 0.2)),
			"color": palette[rci],
		})

	var config := {
		"ok": true,
		"name": name,
		"palette": palette,
		"blend": _f(spec.get("blend", 0.25)),
		"color_k": _f(spec.get("color_k", 0.18)),
		"outline": _f(spec.get("outline", 0.04)),
		"parts": parts,
		"locomotion": loco,
		"ropes": ropes,
	}
	var total := _prim_total(config)
	if total > MAX_PRIMS:
		return _err("基本体总数 %d 超过上限 %d（身体件+腿×2+翅膀+绳段）" % [total, MAX_PRIMS])
	return config

static func _prim_total(config: Dictionary) -> int:
	var n: int = config.parts.size()
	match config.locomotion.type:
		"walker":
			n += int(config.locomotion.legs) * 2
		"flyer":
			n += 2
	for rope in config.ropes:
		n += int(rope.segments)
	return n

## 由 parse 产物搭建静止姿态骨架。
## 返回 {"prims": Array[SdfMath.Prim], "meta": {...}}；meta 记录动画所需的一切索引与骨长：
##   body: [{"idx", "rest": Transform3D, "group"}]
##   legs: [{"upper", "lower": prim 索引, "hip": Vector3(身体空间), "foot_rest": Vector3, "seg_len", "r"}]
##   wings: [{"idx", "shoulder": Vector3, "side": ±1, "len", "r"}]
##   ropes: [{"start": 首段 prim 索引, "count", "anchor": Vector3, "seg_len", "r", "rest_points"}]
static func build_rig(config: Dictionary) -> Dictionary:
	var prims: Array = []
	var body: Array[Dictionary] = []
	var global_blend: float = config.blend
	for part in config.parts:
		var pr := SdfMath.Prim.new()
		pr.shape = part.shape
		pr.params = part.params
		pr.color = part.color
		pr.blend = part.blend if part.blend >= 0.0 else global_blend
		pr.xform = Transform3D(part.rot, part.pos)
		body.append({"idx": prims.size(), "rest": pr.xform, "group": part.group})
		prims.append(pr)

	var loco: Dictionary = config.locomotion
	var legs: Array[Dictionary] = []
	var wings: Array[Dictionary] = []
	if loco.type == "walker":
		var rows := _leg_rows(int(loco.legs))
		var leg_blend: float = minf(global_blend, maxf(loco.leg_r * 1.6, 0.06))
		for row: float in rows:
			for side: float in [-1.0, 1.0]:
				var hip := Vector3(side * loco.stance.x, loco.hip_h, row * loco.stance.y)
				var foot := Vector3(hip.x * 1.15, loco.leg_r * 0.8, hip.z)
				# 骨长：直立距离的 55%，留出常态微屈
				var seg_len: float = hip.distance_to(foot) * 0.55
				var knee := _solve_knee(hip, foot, seg_len, side)
				var color: Color = config.palette[config.palette.size() - 1]
				var upper := SdfMath.capsule_between(hip, knee, loco.leg_r, color, leg_blend)
				var lower := SdfMath.cone_between(knee, foot, loco.leg_r, loco.leg_r * 0.75, color, leg_blend)
				legs.append({
					"upper": prims.size(),
					"lower": prims.size() + 1,
					"hip": hip,
					"foot_rest": foot,
					"seg_len": seg_len,
					"r": loco.leg_r,
				})
				prims.append(upper)
				prims.append(lower)
	elif loco.type == "flyer":
		var wp: Vector3 = loco.wing_pos
		var wing_blend: float = minf(global_blend, maxf(loco.wing_r * 1.8, 0.05))
		var wcolor: Color = config.palette[config.palette.size() - 1]
		for side: float in [-1.0, 1.0]:
			var shoulder := Vector3(side * wp.x, wp.y, wp.z)
			var tip := shoulder + Vector3(side * loco.wing_len, loco.wing_len * 0.25, 0)
			wings.append({
				"idx": prims.size(),
				"shoulder": shoulder,
				"side": side,
				"len": loco.wing_len,
				"r": loco.wing_r,
			})
			prims.append(SdfMath.cone_between(shoulder, tip, loco.wing_r, loco.wing_r * 0.5, wcolor, wing_blend))

	var ropes: Array[Dictionary] = []
	for rope in config.ropes:
		var anchor: Vector3 = rope.anchor
		var dir := Vector3.DOWN
		var horiz := Vector3(anchor.x, 0.0, anchor.z)
		if horiz.length() > 0.15:
			dir = (horiz.normalized() * 0.7 + Vector3.DOWN * 0.7).normalized()
		var pts := PackedVector3Array([anchor])
		for k in range(rope.segments):
			pts.append(pts[k] + dir * rope.seg_len)
		var rope_blend: float = minf(global_blend, maxf(rope.r * 1.6, 0.04))
		var start := prims.size()
		for k in range(rope.segments):
			var t0 := float(k) / float(rope.segments)
			var t1 := float(k + 1) / float(rope.segments)
			var r0: float = rope.r * (1.0 - 0.45 * t0)
			var r1: float = rope.r * (1.0 - 0.45 * t1)
			prims.append(SdfMath.cone_between(pts[k], pts[k + 1], r0, r1, rope.color, rope_blend))
		ropes.append({
			"start": start,
			"count": int(rope.segments),
			"anchor": anchor,
			"seg_len": float(rope.seg_len),
			"r": float(rope.r),
			"rest_points": pts,
		})

	return {
		"prims": prims,
		"meta": {"body": body, "legs": legs, "wings": wings, "ropes": ropes},
	}

## 两段等长骨的膝盖解：余弦定理求膝点，弯曲方向朝外侧偏前（顶视）。
static func _solve_knee(hip: Vector3, foot: Vector3, seg_len: float, side: float) -> Vector3:
	var mid := (hip + foot) * 0.5
	var d := hip.distance_to(foot)
	var h2 := seg_len * seg_len - d * d * 0.25
	var h := sqrt(maxf(h2, 0.0))
	var axis := (foot - hip).normalized()
	# 弯曲平面法向：外侧向 + 前向的混合，避免 4/6 腿互相打架
	var out_dir := (Vector3(side, 0, 0) * 0.6 + Vector3(0, 0, 1) * 0.8).normalized()
	var bend := (out_dir - axis * out_dir.dot(axis)).normalized()
	return mid + bend * h

static func _leg_rows(legs: int) -> Array:
	match legs:
		2: return [0.0]
		4: return [-1.0, 1.0]
	return [-1.0, 0.0, 1.0]

static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}

static func _f(v: Variant) -> float:
	return float(v)

static func _vec2(v: Variant) -> Vector2:
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO

static func _vec3(v: Variant) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO
