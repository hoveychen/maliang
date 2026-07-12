extends SceneTree
## 占位符 SDF spec 的几何断言：手写坐标最容易犯的错是「埋进地面」和「悬在半空」，
## 两者在 headless 里都看不出来，只有真机上才发现。这里逐件算 AABB 下沿来兜住。
## 运行: godot --headless --path . --script res://test/test_placeholder_specs.gd

var fails := 0

func _init() -> void:
	_check_spec("传送门", PlaceholderSpecs.PORTAL)
	_check_spec("魔法熔炉", PlaceholderSpecs.FORGE)
	_check_spec("魔法画板", PlaceholderSpecs.EASEL)
	if fails == 0:
		print("placeholder_specs tests PASS")
	else:
		printerr("placeholder_specs tests FAILED: %d" % fails)
	quit(fails)

func _check_spec(label: String, spec: Dictionary) -> void:
	var parsed := SdfSpec.parse(spec)
	if not bool(parsed.get("ok", false)):
		_fail("%s spec 解析失败: %s" % [label, str(parsed.get("error", ""))])
		return
	_ok("%s spec 解析通过" % label)

	# 部件数不能超过 shader 的 MAX_PRIMS，否则多出来的静默不渲染
	var parts: Array = parsed["parts"]
	_expect(label + " 部件数 ≤ MAX_PRIMS", parts.size() <= SdfSpec.MAX_PRIMS, true)

	var lowest := 1e9
	for i in range(parts.size()):
		var p: Dictionary = parts[i]
		var bottom := _bottom_of(p)
		lowest = minf(lowest, bottom)
		_expect("%s 第%d件不埋进地面 (bottom=%.3f)" % [label, i + 1, bottom], bottom >= -0.001, true)
		# 旋转件转一圈也不能沉下去：轨道最低点 = 轴心y - 轨道半径 - 自身半径
		var spin: Dictionary = p.get("spin", {})
		if not spin.is_empty():
			var orbit_bottom := _orbit_bottom(p, spin)
			_expect("%s 第%d件转一圈不沉地 (orbit_bottom=%.3f)" % [label, i + 1, orbit_bottom],
				orbit_bottom >= -0.001, true)

	# 最低的那件必须贴地：整体悬空 0.2 米在游戏里一眼假
	_expect("%s 贴地 (lowest=%.3f)" % [label, lowest], lowest <= 0.05, true)

## 部件 AABB 的下沿：把局部半尺寸经 rot 投到世界 y 轴。
func _bottom_of(p: Dictionary) -> float:
	var pos: Vector3 = p["pos"]
	var basis: Basis = p["rot"]
	var prm: Vector3 = p["params"]
	var half := Vector3.ZERO
	match int(p["shape"]):
		SdfMath.SHAPE_SPHERE:
			return pos.y - prm.x                       # r
		SdfMath.SHAPE_CAPSULE:
			half = Vector3(0.0, prm.y, 0.0)            # 半长（沿局部 y），端头再减 r
			return pos.y - _proj_y(basis, half) - prm.x
		SdfMath.SHAPE_CONE:
			half = Vector3(0.0, prm.z, 0.0)            # 半高
			return pos.y - _proj_y(basis, half) - maxf(prm.x, prm.y)
		SdfMath.SHAPE_BOX:
			half = prm                                  # 半边长
			return pos.y - _proj_y(basis, half)
	return pos.y

## |R·half| 在 y 轴上的投影长度（AABB 的半高）。
func _proj_y(basis: Basis, half: Vector3) -> float:
	return absf(basis.x.y * half.x) + absf(basis.y.y * half.y) + absf(basis.z.y * half.z)

## 旋转件绕 pivot 转一圈时，自身 AABB 下沿能到的最低处。
func _orbit_bottom(p: Dictionary, spin: Dictionary) -> float:
	var pos: Vector3 = p["pos"]
	var pivot: Vector3 = spin["pivot"]
	var axis: Vector3 = spin["axis"]
	var arm := pos - pivot
	# 轨道半径 = 手臂在垂直于轴的平面上的分量长度；轨道能压到的最低 y = pivot.y - radius（当轴水平时）
	var along := axis * arm.dot(axis)
	var radius := (arm - along).length()
	# 轴与 y 轴越接近平行，轨道越水平、越压不下去：用轴的水平度缩放下压量
	var tilt := sqrt(maxf(0.0, 1.0 - axis.normalized().y * axis.normalized().y))
	var self_half := pos.y - _bottom_of(p) # 自身下沿到中心的距离
	return pivot.y + along.y - radius * tilt - self_half

func _expect(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		_ok(name)
	else:
		_fail("%s: got %s want %s" % [name, str(got), str(want)])

func _ok(name: String) -> void:
	print("  ok %s" % name)

func _fail(msg: String) -> void:
	fails += 1
	printerr("  FAIL %s" % msg)
