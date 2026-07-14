class_name TerrainDeco
extends RefCounted
## 草地顶面 3D 装饰散布（Pokopia 化 P6，docs/pokopia-block-design-analysis.md ⑥）：
## 厚叶草簇 ×2 + 大头花丛，全是程序化低模 ArrayMesh——「细节感全由几何提供」，
## 顶面贴图保持素净（P2 平色化不回退）。
##
## 分工：本类只管「哪个 tile 长什么、长在哪、什么姿态」（纯函数，headless 可单测）
## 和「三种 mesh 长什么样」；合批渲染完全复用 chunk_manager 的 _batch/_flush_batches
## MultiMesh 路（每区块每种一次 draw call），材质复用 SdfStaticBaker.material()
## （world_bend + 顶点色，纸艺开关自动跟随）。占地过滤（房屋/树/动态物件脚下不长）
## 是世界状态，留在 chunk_manager 的散布循环里做。
##
## 密度/姿态旋钮全在下面常量区（P1-P5 的地形旋钮在 chunk_manager 顶部，此处是散布自己的）。

## —— 密度旋钮 ——
## 花只成片长（Pokopia 花是一畦一畦种的，不是撒胡椒面）：世界按 PATCH_CELL tile 分粗格，
## PATCH_FRACTION 的粗格是花畦；花畦内 FLOWER_FRACTION 的草 tile 出花丛。
const PATCH_CELL := 4          ## 花畦粗格边长（tile）
const PATCH_FRACTION := 0.18   ## 粗格中花畦占比
const FLOWER_FRACTION := 0.35  ## 花畦内草 tile 出花率
const TUFT_BIG_FRACTION := 0.14    ## 大草簇：全体草 tile 出率
const TUFT_SMALL_FRACTION := 0.30  ## 小草芽：全体草 tile 出率（最常见，最便宜）

## —— 姿态旋钮 ——
const OFFSET_MAX := 0.6   ## tile 中心抖动半径（米）；tile 半宽 1m、崖顶 bevel 0.12，0.6 稳在平顶内
const SCALE_MIN := 0.85
const SCALE_MAX := 1.25

## 渲染键（chunk_manager._scatter_kind 按 "deco_" 前缀走程序化分支，不进 PackRegistry）
const KEYS: Array[String] = ["deco_tuft_a", "deco_tuft_b", "deco_flower"]

## —— 落点决策（纯函数：只看 TerrainMap + hash，确定性，重刷不闪）——
## 返回 {} = 本 tile 不长；否则 { key, off: Vector2(米), yaw: float(度), scale: float }。
## hash 盐与物品外观抖动 hash(gt) 区分，避免「有石头的 tile 永远同款草」的相关性。
static func pick(gt: Vector2i) -> Dictionary:
	if TerrainMap.tile_type(gt) != TerrainMap.T_GRASS:
		return {}
	var hk := hash(Vector3i(gt.x, gt.y, 0xDEC0))
	var roll := float(posmod(hk, 1000)) / 1000.0
	var key := ""
	if _in_flower_patch(gt) and roll < FLOWER_FRACTION:
		key = "deco_flower"
	elif roll < TUFT_BIG_FRACTION:
		key = "deco_tuft_a"
	elif roll < TUFT_BIG_FRACTION + TUFT_SMALL_FRACTION:
		key = "deco_tuft_b"
	else:
		return {}
	return {
		"key": key,
		"off": Vector2(
			(float(posmod(hk >> 10, 121)) / 60.0 - 1.0) * OFFSET_MAX,
			(float(posmod(hk >> 17, 121)) / 60.0 - 1.0) * OFFSET_MAX),
		"yaw": float(posmod(hk >> 3, 360)),
		"scale": lerpf(SCALE_MIN, SCALE_MAX, float(posmod(hk >> 24, 97)) / 96.0),
	}

static func _in_flower_patch(gt: Vector2i) -> bool:
	var patch := Vector2i(gt.x / PATCH_CELL, gt.y / PATCH_CELL)
	return float(posmod(hash(Vector3i(patch.x, patch.y, 0xF10)), 1000)) / 1000.0 < PATCH_FRACTION

## —— 程序化 mesh（每种建一次全局缓存；顶点色写 linear，与 SdfStaticBaker 同约定）——
static var _meshes: Dictionary = {}

static func mesh(key: String) -> ArrayMesh:
	if _meshes.has(key):
		return _meshes[key]
	var m: ArrayMesh = null
	match key:
		"deco_tuft_a":
			# 大丛：5 外圈外倾 + 2 内芯高挺（Pokopia 草簇中间高四周散）。
			# 尺寸对参考图（serebii_1）：丛高 ~0.6m、径 ~0.8m ≈ 0.4 tile，首版 0.42 太秀气。
			# 配色比地表深一档（树冠同族）：与亮草地同色系会隐身（首截图实测只剩内面深色刀片），
			# 深基浅尖的族内渐变负责立体感
			m = _build_tuft(5, 0.62, 0.24, 38.0, 2, 0.72, 0.18, 14.0,
				Color(0.24, 0.50, 0.28), Color(0.82, 0.96, 0.74))
		"deco_tuft_b":
			# 小芽：3 叶，再深一点（低草贴地，别抢大丛的戏）
			m = _build_tuft(3, 0.38, 0.17, 30.0, 0, 0.0, 0.0, 0.0,
				Color(0.21, 0.45, 0.26), Color(0.56, 0.80, 0.52))
		"deco_flower":
			m = _build_flower_cluster()
	_meshes[key] = m
	return m

## 通用三角面（flat shading = 低模块面感，与纸艺折面语言一致）：
## 顶点序 a→b→c 使 (c-a)×(b-a) 指向正面（与 chunk_manager._emit_quad 同绕序约定）。
static func _tri(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		a: Vector3, b: Vector3, cc: Vector3, ca: Color, cb: Color, ccc: Color) -> void:
	var nrm := (cc - a).cross(b - a).normalized()
	v.append(a); v.append(b); v.append(cc)
	for _k in range(3):
		n.append(nrm)
	c.append(ca); c.append(cb); c.append(ccc)

## 单片厚叶（多肉状）：基部一点收拢，55% 处最宽并向外鼓（凸折），收到叶尖。
## 双面各 4 三角——god 俯角下外倾叶的可见面一半是朝丛心的内面，单面版被背面剔除
## 只剩剪影刀片（截图实测）；内面色压深 25% 顺手当 AO，叶肉厚度感免费到手。
## yaw 绕 Y 转叶朝向；tilt 从竖直向外倒（度）。
static func _leaf(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		yaw_deg: float, tilt_deg: float, length: float, width: float,
		base_col: Color, tip_col: Color) -> void:
	var rot := Basis(Vector3.UP, deg_to_rad(yaw_deg))
	var t := deg_to_rad(tilt_deg)
	var dir := rot * Vector3(0.0, cos(t), sin(t))       # 基→尖
	var side := rot * Vector3(1.0, 0.0, 0.0)
	var out_h := rot * Vector3(0.0, 0.0, 1.0)           # 水平外向（凸折方向）
	var b := Vector3.ZERO
	var mid := dir * (length * 0.55)
	var m := mid + out_h * (width * 0.35)               # 中脊外鼓 = 厚叶肉感
	var ml := mid - side * (width * 0.5)
	var mr := mid + side * (width * 0.5)
	var tip := dir * length
	var mid_col := base_col.lerp(tip_col, 0.55)
	# 外面（朝 out_h 侧）
	_tri(v, n, c, b, ml, m, base_col, mid_col, mid_col)
	_tri(v, n, c, b, m, mr, base_col, mid_col, mid_col)
	_tri(v, n, c, ml, tip, m, mid_col, tip_col, mid_col)
	_tri(v, n, c, m, tip, mr, mid_col, tip_col, mid_col)
	# 内面（反绕序 + 压深）
	var bi := base_col.darkened(0.25)
	var mi := mid_col.darkened(0.25)
	var ti := tip_col.darkened(0.25)
	_tri(v, n, c, b, m, ml, bi, mi, mi)
	_tri(v, n, c, b, mr, m, bi, mi, mi)
	_tri(v, n, c, ml, m, tip, mi, mi, ti)
	_tri(v, n, c, m, mr, tip, mi, mi, ti)

## 草簇：n_out 片外圈叶（等角环布+确定性微扰）+ n_in 片内芯叶。颜色写 linear。
static func _build_tuft(n_out: int, out_len: float, out_w: float, out_tilt: float,
		n_in: int, in_len: float, in_w: float, in_tilt: float,
		base_srgb: Color, tip_srgb: Color) -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var base_col := base_srgb.srgb_to_linear()
	var tip_col := tip_srgb.srgb_to_linear()
	for i in range(n_out):
		var jig := _jig(i)  # 确定性微扰：环布不整齐才像活物
		var yaw := float(i) * 360.0 / float(n_out) + jig * 24.0
		_leaf(v, n, c, yaw, out_tilt + jig * 8.0, out_len * (1.0 + jig * 0.18), out_w, base_col, tip_col)
	for i in range(n_in):
		var jig := _jig(i + 17)
		var yaw := float(i) * 360.0 / float(maxi(n_in, 1)) + 45.0 + jig * 30.0
		_leaf(v, n, c, yaw, in_tilt + jig * 5.0, in_len * (1.0 + jig * 0.12), in_w, base_col, tip_col)
	return _commit(v, n, c)

## 大头花丛：3 朵（2 粉 1 白）+ 3 片基叶。Pokopia 语法（serebii_31）：
## 5 瓣浅杯型 + 黄心圆盘 + 十字茎片，花头大茎短、成小丛。
static func _build_flower_cluster() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var pink := Color(0.95, 0.62, 0.72).srgb_to_linear()
	var white := Color(0.97, 0.95, 0.90).srgb_to_linear()
	var spots := [
		[Vector3(0.0, 0.0, -0.19), 0.32, pink],
		[Vector3(0.20, 0.0, 0.13), 0.27, white],
		[Vector3(-0.21, 0.0, 0.12), 0.25, pink],
	]
	for i in range(spots.size()):
		_flower(v, n, c, spots[i][0], spots[i][1], spots[i][2], float(i) * 40.0)
	# 基叶：矮宽深绿，填花脚
	var leaf_base := Color(0.26, 0.50, 0.27).srgb_to_linear()
	var leaf_tip := Color(0.44, 0.70, 0.40).srgb_to_linear()
	for i in range(3):
		var yaw := float(i) * 120.0 + 25.0
		_leaf(v, n, c, yaw, 52.0, 0.22, 0.16, leaf_base, leaf_tip)
	return _commit(v, n, c)

## 单朵大头花：茎（十字两片）→ 5 瓣（内窄外宽梯形，上翘 20° 浅杯）→ 黄心。
static func _flower(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		at: Vector3, head_h: float, petal_col: Color, yaw0: float) -> void:
	var stem_col := Color(0.30, 0.55, 0.30).srgb_to_linear()
	var core_col := Color(0.98, 0.85, 0.35).srgb_to_linear()
	# 茎：两片正交竖窄条，双面（单面版从半数视角被剔除，花头悬空）
	for k in range(2):
		var rot := Basis(Vector3.UP, deg_to_rad(yaw0 + float(k) * 90.0))
		var s := rot * Vector3(0.03, 0.0, 0.0)
		var top := at + Vector3(0.0, head_h - 0.02, 0.0)
		_tri(v, n, c, at - s, at + s, top + s, stem_col, stem_col, stem_col)
		_tri(v, n, c, at - s, top + s, top - s, stem_col, stem_col, stem_col)
		_tri(v, n, c, at - s, top + s, at + s, stem_col, stem_col, stem_col)
		_tri(v, n, c, at - s, top - s, top + s, stem_col, stem_col, stem_col)
	# 5 瓣：内缘窄（r0）外缘宽（r1），外缘抬 sin(20°) 成浅杯（尺寸对参考图：花头径 ~0.4m）
	var petal_lite := petal_col.lerp(Color.WHITE, 0.25)
	var hy := at.y + head_h
	for i in range(5):
		var rot := Basis(Vector3.UP, deg_to_rad(yaw0 + float(i) * 72.0))
		var dir := rot * Vector3(0.0, 0.0, 1.0)
		var side := rot * Vector3(1.0, 0.0, 0.0)
		var i0 := at + Vector3(0.0, head_h, 0.0) + dir * 0.035
		var o := at + Vector3(0.0, head_h + 0.06, 0.0) + dir * 0.19
		var il := i0 - side * 0.03
		var ir := i0 + side * 0.03
		var ol := o - side * 0.085
		var orr := o + side * 0.085
		# 绕序保法线朝上（朝下会被背面剔除——首版实测花瓣全隐身只剩黄心）
		_tri(v, n, c, il, orr, ol, petal_col, petal_lite, petal_lite)
		_tri(v, n, c, il, ir, orr, petal_col, petal_col, petal_lite)
	# 黄心：小方片盖在瓣心上方
	var cy := hy + 0.014
	var cs := 0.048
	_tri(v, n, c, at + Vector3(-cs, cy - at.y, -cs), at + Vector3(cs, cy - at.y, -cs), at + Vector3(cs, cy - at.y, cs), core_col, core_col, core_col)
	_tri(v, n, c, at + Vector3(-cs, cy - at.y, -cs), at + Vector3(cs, cy - at.y, cs), at + Vector3(-cs, cy - at.y, cs), core_col, core_col, core_col)

## 确定性微扰 [-1,1]（同 flower_field 的 sin-hash 惯用法，无随机源、重建不闪）
static func _jig(i: int) -> float:
	return fmod(sin(float(i) * 12.9898) * 43758.5453, 1.0) * 2.0 - 1.0

static func _commit(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_COLOR] = c
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
