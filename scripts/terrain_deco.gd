class_name TerrainDeco
extends RefCounted
## 地表顶面 3D 装饰散布（Pokopia 化 P6 草地首发；pokopia-themes P2 扩到主题层）：
## 草地=厚叶草簇 ×2 + 大头花丛；主题层按 tile 类型分发（海草/珊瑚/蕨叶/石子/冰晶/
## 雪堆/麦茬，见 THEME_GROUPS）。全是程序化低模 ArrayMesh——「细节感全由几何提供」，
## 顶面贴图保持素净（P2 平色化不回退）。结构面（石板/沥青/室内地板…）刻意不长。
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

## —— 主题层散布（pokopia-themes P2）——
## 按地表 tile 类型分发装饰组（P1 差距矩阵：11 个非草主题零装饰是「死寂感」头号来源，
## docs/pokopia-themes-gap-matrix.md）。密度全部低于草地档（村庄 +11.9% 三角已是预算
## 大头，真机未 benchmark）；结构面（石板/沥青/室内地板…）刻意不长——装饰该来自 items。
## 表值 [[key, 累计出率], ...]：roll 依次比累计上限，pick 用（一格一株，与草地同约定）。
const THEME_GROUPS := {
	TerrainMap.T_SEAGRASS: [["deco_seaweed_a", 0.12], ["deco_seaweed_b", 0.30]],
	TerrainMap.T_CORAL_SAND: [["deco_coral", 0.18]],
	TerrainMap.T_FERN: [["deco_fern", 0.22]],
	TerrainMap.T_VOLCANIC: [["deco_stones", 0.14]],
	TerrainMap.T_RUBBLE: [["deco_stones", 0.10]],
	TerrainMap.T_ICE: [["deco_ice_crystal", 0.10]],
	TerrainMap.T_PACKED_SNOW: [["deco_ice_crystal", 0.04], ["deco_frost_tuft", 0.14]],
	TerrainMap.T_SNOW: [["deco_ice_crystal", 0.03], ["deco_frost_tuft", 0.15]],
	TerrainMap.T_FARM_FURROW: [["deco_stubble", 0.38]],
	TerrainMap.T_LAWN_GRID: [["deco_tuft_b", 0.12]],
}

## —— 姿态旋钮 ——
const OFFSET_MAX := 0.6   ## tile 中心抖动半径（米）；tile 半宽 1m、崖顶 bevel 0.12，0.6 稳在平顶内
const SCALE_MIN := 0.85
const SCALE_MAX := 1.25

## 渲染键（chunk_manager._scatter_kind 按 "deco_" 前缀走程序化分支，不进 PackRegistry）
const KEYS: Array[String] = ["deco_tuft_a", "deco_tuft_b", "deco_flower",
	"deco_seaweed_a", "deco_seaweed_b", "deco_coral", "deco_fern",
	"deco_stones", "deco_ice_crystal", "deco_frost_tuft", "deco_stubble"]

## —— 落点决策（纯函数：只看 TerrainMap + hash，确定性，重刷不闪）——
## 返回 {} = 本 tile 不长；否则 { key, off: Vector2(米), yaw: float(度), scale: float }。
## hash 盐与物品外观抖动 hash(gt) 区分，避免「有石头的 tile 永远同款草」的相关性。
static func pick(gt: Vector2i) -> Dictionary:
	var tt := TerrainMap.tile_type(gt)
	var hk := hash(Vector3i(gt.x, gt.y, 0xDEC0))
	var roll := float(posmod(hk, 1000)) / 1000.0
	var key := ""
	if tt == TerrainMap.T_GRASS:
		if _in_flower_patch(gt) and roll < FLOWER_FRACTION:
			key = "deco_flower"
		elif roll < TUFT_BIG_FRACTION:
			key = "deco_tuft_a"
		elif roll < TUFT_BIG_FRACTION + TUFT_SMALL_FRACTION:
			key = "deco_tuft_b"
		else:
			return {}
	elif THEME_GROUPS.has(tt):
		for entry in THEME_GROUPS[tt]:
			if roll < entry[1]:
				key = entry[0]
				break
		if key == "":
			return {}
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
		"deco_seaweed_a":
			# 高海草：窄长近直立（水草向上飘），亮青绿——海草地表是浊橄榄，
			# 同色系隐身坑（P6 实证）靠提亮+提饱和拉开
			m = _build_tuft(5, 0.72, 0.26, 30.0, 1, 0.80, 0.22, 10.0,
				Color(0.10, 0.42, 0.36), Color(0.46, 0.88, 0.62))
		"deco_seaweed_b":
			# 矮海草：3 叶贴地款
			m = _build_tuft(3, 0.55, 0.22, 34.0, 0, 0.0, 0.0, 0.0,
				Color(0.09, 0.36, 0.32), Color(0.36, 0.74, 0.55))
		"deco_coral":
			# 珊瑚簇：短宽外倾「枝片」扇形张开，暖珊瑚粉——珊瑚砂地是浅粉，
			# 靠深一档的枝色+奶油尖立住
			m = _build_tuft(5, 0.55, 0.36, 38.0, 1, 0.58, 0.30, 12.0,
				Color(0.78, 0.34, 0.30), Color(0.99, 0.70, 0.52))
		"deco_fern":
			# 蕨叶丛：多叶长弧外拱（tilt 大=蕨的下垂弧），深绿——蕨地表读土黄，
			# 深绿负责把「这是植被」喊出来
			m = _build_tuft(7, 0.72, 0.26, 55.0, 2, 0.58, 0.22, 28.0,
				Color(0.13, 0.36, 0.18), Color(0.44, 0.70, 0.34))
		"deco_stubble":
			# 麦茬束：短直立窄叶，秸秆黄（农田垄「种过东西」的证据）
			m = _build_tuft(4, 0.50, 0.18, 16.0, 0, 0.0, 0.0, 0.0,
				Color(0.52, 0.40, 0.16), Color(0.90, 0.79, 0.46))
		"deco_frost_tuft":
			# 霜枯草簇：雪里钻出来的枯草，深秸秆基+霜白蓝尖——白雪上白色几何隐身
			# （雪堆方案实测阵亡），深基负责剪影、霜尖负责「结着霜」
			m = _build_tuft(5, 0.46, 0.16, 40.0, 1, 0.52, 0.13, 12.0,
				Color(0.42, 0.38, 0.26), Color(0.88, 0.92, 0.96))
		"deco_stones":
			m = _build_stones()
		"deco_ice_crystal":
			m = _build_ice_crystals()
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

## 石子堆：3 颗矮四面体小石（3 底点 + 1 偏心顶点，只发 3 侧面，底面埋地不发）。
## 火山岩/碎石共用：石色取中灰偏暖，比火山岩地表（暗炭）亮、比碎石地表（浅砾）暗，
## 两边都有对比。逐面 flat shading 自带明暗差。
static func _build_stones() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var spots := [
		[Vector3(-0.16, 0.0, -0.10), 0.42, 0.34],   # [中心, 底半径, 高]
		[Vector3(0.24, 0.0, 0.06), 0.30, 0.24],
		[Vector3(-0.02, 0.0, 0.28), 0.22, 0.16],
	]
	for si in range(spots.size()):
		var at: Vector3 = spots[si][0]
		var r: float = spots[si][1]
		var h: float = spots[si][2]
		var col := Color(0.52, 0.50, 0.47).lerp(Color(0.38, 0.36, 0.34), 0.5 + _jig(si) * 0.5).srgb_to_linear()
		var base: Array[Vector3] = []
		for k in range(3):
			var a := deg_to_rad(float(k) * 120.0 + float(si) * 47.0 + _jig(si * 3 + k) * 22.0)
			base.append(at + Vector3(cos(a) * r * (1.0 + _jig(si + k) * 0.2), 0.0, sin(a) * r * (1.0 + _jig(si + k + 5) * 0.2)))
		var apex := at + Vector3(_jig(si + 9) * r * 0.3, h, _jig(si + 13) * r * 0.3)
		for k in range(3):
			# 顶点序对齐 _tri 的绕序约定：底边 b→a、再到 apex，法线朝外
			_tri(v, n, c, base[(k + 1) % 3], base[k], apex, col, col, col.lightened(0.12))
	return _commit(v, n, c)

## 冰晶簇：3 根四棱锥冰柱（方底 + 上尖），底深青尖近白——雪地/冰面同为浅色，
## 靠底部深青把剪影踩住（同色系隐身坑的反制），微倾姿态像天然晶簇。
static func _build_ice_crystals() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var base_col := Color(0.42, 0.72, 0.82).srgb_to_linear()
	var tip_col := Color(0.94, 0.99, 1.0).srgb_to_linear()
	var spots := [
		[Vector3(-0.06, 0.0, -0.05), 0.14, 0.75, 8.0],   # [底心, 底半宽, 高, 倾角]
		[Vector3(0.18, 0.0, 0.12), 0.11, 0.50, -14.0],
		[Vector3(-0.20, 0.0, 0.15), 0.08, 0.34, 20.0],
	]
	for si in range(spots.size()):
		var at: Vector3 = spots[si][0]
		var r: float = spots[si][1]
		var h: float = spots[si][2]
		var rot := Basis(Vector3(0.0, 0.0, 1.0), deg_to_rad(spots[si][3])) # 绕 Z 微倾
		var yaw := Basis(Vector3.UP, deg_to_rad(float(si) * 50.0))
		var corners: Array[Vector3] = []
		for k in range(4):
			var a := deg_to_rad(float(k) * 90.0 + 45.0)
			corners.append(at + yaw * (rot * Vector3(cos(a) * r, 0.0, sin(a) * r)))
		var apex := at + yaw * (rot * Vector3(0.0, h, 0.0))
		for k in range(4):
			_tri(v, n, c, corners[(k + 1) % 4], corners[k], apex, base_col, base_col, tip_col)
	return _commit(v, n, c)

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
