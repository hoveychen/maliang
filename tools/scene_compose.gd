extends RefCounted
## 场景静态布置组装库（scene-items P2，设计见 docs/scene-item-refactor-design.md §3.6）。
## 把「哪个 tile 上有什么物品」算成地形矩阵 v2 的物品层：地标/SDF 物件常量表 +
## 分区散布规则都在这里——这是布置规则的唯一权威（chunk_manager 的运行时散布/
## 常量表在 P4 删除，改吃矩阵）。
##
## 组装语义与运行时 _skin 对齐：地标先占地（锚点被占沿螺旋外扩）、SDF 物件次之、
## 散布最后逐 tile 判定（草丛不占位）；占地判定复用 OccupancyMap.prop_area_ok
## （类型/高度一致/占用互斥），保证与今日线上布局一致。
## 前置：调用前 TerrainMap 必须已载入目标场景的地貌（村庄 = 本地 _paint()，
## 森林 = export_forest 的字节先 load_from_bytes）。

const MLTR_HEADER := 11

## 手工地标（迁自 chunk_manager.LANDMARKS）：item id + 全局 tile 锚点 + 手调朝向。
## reserve/path_ok 语义已进物品实体定义（server items.ts BUILTIN_ITEMS），
## 这里只留 search（锚点被占时沿环外扩找位的圈数）。
## 泉石两块原表有手调缩放 2.4/1.7——矩阵不存缩放，改用散布同款 hash 抖动
## （rock 档位 1.6/2.0/2.4），观感差异可忽略。
const LANDMARKS := [
	{ "item": "well", "tile": Vector2i(37, 37), "yaw": 0.0, "search": 0 },
	{ "item": "windmill", "tile": Vector2i(59, 54), "yaw": 180.0, "search": 1 },
	{ "item": "house_0", "tile": Vector2i(31, 31), "yaw": 90.0, "search": 2 },
	{ "item": "house_1", "tile": Vector2i(44, 31), "yaw": 180.0, "search": 2 },
	{ "item": "house_2", "tile": Vector2i(31, 44), "yaw": 90.0, "search": 2 },
	{ "item": "house_3", "tile": Vector2i(44, 44), "yaw": 270.0, "search": 2 },
	{ "item": "house_1", "tile": Vector2i(27, 40), "yaw": 0.0, "search": 2 },
	{ "item": "house_0", "tile": Vector2i(47, 35), "yaw": 180.0, "search": 2 },
	{ "item": "house_2", "tile": Vector2i(34, 58), "yaw": 90.0, "search": 2 },
	{ "item": "house_3", "tile": Vector2i(33, 23), "yaw": 270.0, "search": 2 },
	{ "item": "rock_2", "tile": Vector2i(30, 12), "yaw": 40.0, "search": 0 },
	{ "item": "rock_0", "tile": Vector2i(28, 12), "yaw": 210.0, "search": 0 },
]

## SDF 可动物件（迁自 chunk_manager.SDF_PROPS）；wander 已进实体定义。
const SDF_PROPS := [
	{ "item": "walking_hut", "tile": Vector2i(24, 47), "yaw": 150.0, "search": 2 },
	{ "item": "hop_mailbox", "tile": Vector2i(41, 34), "yaw": 200.0, "search": 2 },
	{ "item": "nodding_flower", "tile": Vector2i(3, 4), "yaw": 160.0, "search": 2 },
	{ "item": "pinwheel", "tile": Vector2i(40, 40), "yaw": 200.0, "search": 2 },
	{ "item": "paper_note", "tile": Vector2i(33, 34), "yaw": 30.0, "search": 2 },
	{ "item": "crayon", "tile": Vector2i(34, 34), "yaw": 300.0, "search": 2 },
	{ "item": "village_sign", "tile": Vector2i(36, 24), "yaw": 190.0, "search": 2 },
]

## 合并大场景（village_forest，100 格）的手工地标：村庄核心近原点带的农舍 + 水井，
## 外婆家小屋在穿林小径尽头（(66,64) 空地南口，面朝孩子来路）。坐标见
## docs/s1-merged-scene-layout.md；森林布景/树木由散布层出，此处只放「人造建筑」锚点。
## ⚠️ 三只小猪的房子/POI 迁入（B 全量合并）在 s1-hood P3-P4 再补，本表先只放村庄骨架 + 外婆家占位屋。
const LANDMARKS_VF := [
	{ "item": "well", "tile": Vector2i(20, 16), "yaw": 0.0, "search": 0 },   # 广场水井
	{ "item": "house_0", "tile": Vector2i(11, 10), "yaw": 90.0, "search": 2 },
	{ "item": "house_1", "tile": Vector2i(29, 11), "yaw": 180.0, "search": 2 },
	{ "item": "house_2", "tile": Vector2i(10, 24), "yaw": 90.0, "search": 2 },
	{ "item": "house_3", "tile": Vector2i(31, 22), "yaw": 270.0, "search": 2 },
	{ "item": "house_2", "tile": Vector2i(66, 60), "yaw": 0.0, "search": 2 },  # 外婆家小屋（占位，P4 填实篱笆/门）
]

## village_forest 的 SDF 可动物件：村北林口一块路牌，指向森林。
const SDF_PROPS_VF := [
	{ "item": "village_sign", "tile": Vector2i(23, 38), "yaw": 200.0, "search": 2 },
]

## 第一季册 5《绿野仙踪》独立场景（oz，75 格）的手工地标：翡翠城 = 黄砖路尽头几座房子聚成一座「城」
## （铁皮人 56,54 广场旁的草地上，house 不能落路面故摆广场外围）。坐标见 docs/season-1-outline.md §4。
## 说明：暂用现有 house/村牌/风车 prop 近似「城/路牌/农田」——专属奥兹 prop（玉米秆/翡翠城堡）留后续主题包。
const LANDMARKS_OZ := [
	{ "item": "house_2", "tile": Vector2i(51, 56), "yaw": 90.0, "search": 2 },   # 翡翠城·西
	{ "item": "house_0", "tile": Vector2i(64, 54), "yaw": 270.0, "search": 2 },  # 翡翠城·东
	{ "item": "house_1", "tile": Vector2i(58, 64), "yaw": 0.0, "search": 2 },    # 翡翠城·南门
]

## oz 的 SDF 可动物件：黄砖路两处路牌（入口 + 玉米地岔口，呼应「找回家的路」）+ 玉米地一支风车点缀。
const SDF_PROPS_OZ := [
	{ "item": "village_sign", "tile": Vector2i(22, 18), "yaw": 200.0, "search": 2 },
	{ "item": "village_sign", "tile": Vector2i(44, 38), "yaw": 150.0, "search": 2 },
	{ "item": "pinwheel", "tile": Vector2i(33, 30), "yaw": 200.0, "search": 2 },
]

## 内置物品的占地/压路语义（与 server items.ts BUILTIN_ITEMS 必须同步；
## P4 起客户端渲染层也从这里取 footprint——单一副本，别在别处再抄）。
const ITEM_SPAN := {
	"well": 3, "windmill": 3,
	"house_0": 3, "house_1": 3, "house_2": 3, "house_3": 3,
	"walking_hut": 3, "hop_mailbox": 3,
}
const ITEM_PATH_OK := { "well": true }

## 散布判定结果 → 物品 id（变体由外观 hash 选，与运行时 _skin 同款算式）。
const DECO_NONE := 0
const DECO_TREE := 1
const DECO_BUSH := 2
const DECO_ROCK := 3
const DECO_TUFT := 4
const TREE_IDS := ["tree_puff_a", "tree_puff_b", "tree_puff_c"]
const ROCK_IDS := ["rock_0", "rock_1", "rock_2"]
const TUFT_IDS := ["tuft_0", "tuft_1"]

## 组装一个场景的物品层。返回 { palette: PackedStringArray,
## item_ref: PackedByteArray, item_arg: PackedByteArray }。
## 确定性纯函数（hash 抖动 + 固定遍历序），连续两次调用逐字节一致。
static func compose(scene_id: String) -> Dictionary:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var item_ref := PackedByteArray()
	item_ref.resize(count)
	var item_arg := PackedByteArray()
	item_arg.resize(count)
	var palette := PackedStringArray()

	OccupancyMap.clear()

	# ── 手工锚点（各场景专属）：地标先占地，SDF 物件次之——与 _skin 顺序一致 ──
	if scene_id == "village":
		for lm in LANDMARKS:
			_place_anchor(item_ref, item_arg, palette, lm)
		for sp in SDF_PROPS:
			_place_anchor(item_ref, item_arg, palette, sp)
	elif scene_id == "village_forest":
		for lm in LANDMARKS_VF:
			_place_anchor(item_ref, item_arg, palette, lm)
		for sp in SDF_PROPS_VF:
			_place_anchor(item_ref, item_arg, palette, sp)
	elif scene_id == "oz":
		for lm in LANDMARKS_OZ:
			_place_anchor(item_ref, item_arg, palette, lm)
		for sp in SDF_PROPS_OZ:
			_place_anchor(item_ref, item_arg, palette, sp)

	# ── 分区散布：全图行主序逐 tile 判定（草丛不占位，其余 1×1 占地）──
	for y in range(n):
		for x in range(n):
			var gt := Vector2i(x, y)
			var i := y * n + x
			if item_ref[i] != 0:
				continue # 锚点 tile 不覆写
			var kind := _deco_kind(scene_id, gt)
			if kind == DECO_NONE:
				continue
			var hk := hash(gt) # 外观 hash：变体与朝向抖动（与运行时同款）
			var id: String
			match kind:
				DECO_TREE:
					id = TREE_IDS[posmod(hk, TREE_IDS.size())]
				DECO_BUSH:
					id = "bush_puff"
				DECO_ROCK:
					id = ROCK_IDS[posmod(hk, ROCK_IDS.size())]
				_:
					id = TUFT_IDS[posmod(hk, TUFT_IDS.size())]
			if kind != DECO_TUFT:
				if not OccupancyMap.prop_area_ok(gt, 1, 1, false, false):
					continue
				OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(gt), 2, 2)
			item_ref[i] = _pal_ref(palette, id)
			item_arg[i] = yaw_to_arg(float(posmod(hk, 360)))

	OccupancyMap.clear() # 不给同进程后续使用者留脏占用
	return { "palette": palette, "item_ref": item_ref, "item_arg": item_arg }

## 把地貌三平面 + 组装好的物品层拼成 .mltr v2 字节流（格式见 server/src/terrain.ts）。
static func build_v2_bytes(types: PackedByteArray, heights: PackedByteArray, depths: PackedByteArray, composed: Dictionary) -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var buf := PackedByteArray()
	buf.resize(MLTR_HEADER)
	for i in range(4):
		buf[i] = TerrainMap.MLTR_MAGIC.unicode_at(i)
	buf[4] = TerrainMap.MLTR_VERSION
	buf[5] = n
	buf[6] = n
	buf.encode_float(7, WorldGrid.TILE_SIZE) # 小端，与 DataView.setFloat32(.., true) 一致
	buf.append_array(types)
	buf.append_array(heights)
	buf.append_array(depths)
	buf.append_array(composed["item_ref"])
	buf.append_array(composed["item_arg"])
	var zeros := PackedByteArray()
	zeros.resize(4 * count) # 四张边缘平面：一期恒 0（数据位）
	buf.append_array(zeros)
	var palette: PackedStringArray = composed["palette"]
	buf.append(palette.size())
	for id in palette:
		var b := id.to_utf8_buffer()
		buf.append(b.size())
		buf.append_array(b)
	return buf

## 朝向角 → arg 字节（256 档就近，与 server yawToArg 一致）。
static func yaw_to_arg(deg: float) -> int:
	var norm := fposmod(deg, 360.0)
	return roundi(norm / (360.0 / 256.0)) % 256

## 手工锚点落位：锚点被占沿螺旋外扩 search 圈（与 _spawn_on_tile 同语义）；
## 找不到空位就放弃（确定性，不摆歪）。
static func _place_anchor(item_ref: PackedByteArray, item_arg: PackedByteArray, palette: PackedStringArray, entry: Dictionary) -> void:
	var id: String = entry["item"]
	var span: int = ITEM_SPAN.get(id, 1)
	var reserve := (span - 1) / 2
	var path_ok: bool = ITEM_PATH_OK.get(id, false)
	var n := WorldGrid.GRID_TILES
	for r in range(int(entry["search"]) + 1):
		for t in _ring(entry["tile"], r):
			var origin: Vector2i = t - Vector2i(reserve, reserve)
			if not OccupancyMap.prop_area_ok(origin, span, span, path_ok, false):
				continue
			OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(origin), span * 2, span * 2)
			var i := posmod(t.y, n) * n + posmod(t.x, n)
			item_ref[i] = _pal_ref(palette, id)
			item_arg[i] = yaw_to_arg(float(entry["yaw"]))
			return

## palette 引用：首用即登记，返回 1 起的索引。
static func _pal_ref(palette: PackedStringArray, id: String) -> int:
	var i := palette.find(id)
	if i < 0:
		palette.append(id)
		i = palette.size() - 1
	return i + 1

## 半径 r 的方形环（r=0 只有中心），确定性顺序——与 chunk_manager._ring 同构。
static func _ring(c: Vector2i, r: int) -> Array:
	if r == 0:
		return [c]
	var out: Array = []
	for d in range(-r, r + 1):
		out.append(c + Vector2i(d, -r))
		out.append(c + Vector2i(d, r))
	for d in range(-r + 1, r):
		out.append(c + Vector2i(-r, d))
		out.append(c + Vector2i(r, d))
	return out

# ── 分区散布规则（迁自 chunk_manager._deco_kind_*，逐行对齐；P4 删除那份）──

static func _deco_kind(scene_id: String, gt: Vector2i) -> int:
	# village 是唯一存活的旧场景；其余主题场景已退役（scene-retire）。
	# 新场景各自定义散布规则时在此加分支。
	if scene_id == "village":
		return _deco_kind_village(gt)
	if scene_id == "village_forest":
		return _deco_kind_village_forest(gt)
	if scene_id == "oz":
		return _deco_kind_oz(gt)
	return DECO_NONE

## 奥兹黄砖路散布：入口/翡翠城两广场开阔；玉米地（稻草人一带）成片规则灌木当玉米；
## 其余是「远方旷野」——比森林疏朗的疏树+灌木+草丛。黄砖路/广场走 T_PATH 自动排除保持明路。
static func _deco_kind_oz(gt: Vector2i) -> int:
	if TerrainMap.tile_type(gt) != TerrainMap.T_GRASS:
		return DECO_NONE
	var roll := posmod(hash(Vector2i(gt.x * 3 + 11, gt.y * 7 + 5)), 100)
	# 入口小广场周边（portal 落点 14,14 半径 8）：开阔好落脚
	if _tor_dist(gt, Vector2i(14, 14)) <= 8.0:
		return DECO_TUFT if roll < 12 else DECO_NONE
	# 玉米地（稻草人 36,34 半径 8）：隔位规则灌木成「田」
	if _tor_dist(gt, Vector2i(36, 34)) <= 8.0:
		if posmod(gt.x + gt.y, 2) == 0 and roll < 55:
			return DECO_BUSH
		return DECO_TUFT if roll < 30 else DECO_NONE
	# 翡翠城广场周边（56,54 半径 8）：整洁疏树
	if _tor_dist(gt, Vector2i(56, 54)) <= 8.0:
		if roll < 6:
			return DECO_TREE
		return DECO_TUFT if roll < 16 else DECO_NONE
	# 其余旷野：疏树 + 灌木 + 石 + 草丛（疏朗，是「远方」的开阔感）
	if roll < 8:
		return DECO_TREE
	if roll < 13:
		return DECO_BUSH
	if roll < 16:
		return DECO_ROCK
	return DECO_TUFT if roll < 30 else DECO_NONE

## 合并大场景散布：村庄核心（近端）整洁疏树，往森林深处（z 大）越走越密；
## 穿林小径/跑道走 T_PATH → 自动排除（保持明路）；外婆家/七矮人两处林间空地留空。
## 见 docs/s1-merged-scene-layout.md。
static func _deco_kind_village_forest(gt: Vector2i) -> int:
	if TerrainMap.tile_type(gt) != TerrainMap.T_GRASS:
		return DECO_NONE  # 路面（广场/小径/跑道）与水面自动排除，保持明路
	var roll := posmod(hash(Vector2i(gt.x * 3 + 11, gt.y * 7 + 5)), 100)  # 与外观 hash 解耦
	# 出生林间空地（环面距原点 8 tile 内）：开阔便于新手起步
	if _tor_dist(gt, Vector2i.ZERO) <= 8.0:
		return DECO_TUFT if roll < 10 else DECO_NONE
	# 岸边一圈芦苇灌木
	if _near_water(gt):
		if roll < 24:
			return DECO_BUSH
		return DECO_TUFT if roll < 50 else DECO_NONE
	# 村庄核心（近端 z<38）：整洁，只零星疏树/灌木
	if gt.y < 38:
		if roll < 4:
			return DECO_TREE
		if roll < 8:
			return DECO_BUSH
		return DECO_TUFT if roll < 18 else DECO_NONE
	# 外婆家林间空地（(66,64) 半径 6）：开阔院子
	if _tor_dist(gt, Vector2i(66, 64)) <= 6.0:
		return DECO_TUFT if roll < 12 else DECO_NONE
	# 森林深处·七矮人空地（(30,86) 半径 8，白雪预留）：开阔
	if _tor_dist(gt, Vector2i(30, 86)) <= 8.0:
		return DECO_TUFT if roll < 12 else DECO_NONE
	# 跑道两侧缓冲（x>=84）：稀疏，别糊住跑道
	if gt.x >= 84:
		return DECO_TUFT if roll < 15 else DECO_NONE
	# 其余森林带（z>=38）：密林——隔位下种防挤团，密度远高于村庄
	if posmod(gt.x + gt.y, 2) == 0 and roll < 46:
		return DECO_TREE
	if roll < 12:
		return DECO_TREE
	if roll < 18:
		return DECO_BUSH
	if roll < 22:
		return DECO_ROCK
	return DECO_TUFT if roll < 40 else DECO_NONE

## village 分区散布：从北往南——山地（松树/岩石随海拔变稀）、西南密林（隔位下种的高密度树）、
## 果园（规则行距的浆果灌木）、瞭望丘坡面、村核心（整洁）、出生空地（开阔）、
## 岸边一圈芦苇灌木、其余草甸疏树。
static func _deco_kind_village(gt: Vector2i) -> int:
	if TerrainMap.tile_type(gt) != TerrainMap.T_GRASS:
		return DECO_NONE
	var h := TerrainMap.tile_height(gt)
	var roll := posmod(hash(Vector2i(gt.x * 3 + 11, gt.y * 7 + 5)), 100)  # 与外观 hash 解耦
	# 岸边芦苇灌木：紧邻水面一圈
	if _near_water(gt):
		if roll < 26:
			return DECO_BUSH
		return DECO_TUFT if roll < 52 else DECO_NONE
	# 出生林间空地（环面距原点 8 tile 内）：保持开阔便于新手起步
	if _tor_dist(gt, Vector2i.ZERO) <= 8.0:
		return DECO_TUFT if roll < 10 else DECO_NONE
	# 北部山地（主峰 + 东肩丘一带）：低台地松树、中台地岩石、峰顶零星立石
	if gt.y <= 14 and gt.x >= 22:
		if h == 0:
			if roll < 7:
				return DECO_TREE
			if roll < 11:
				return DECO_ROCK
			return DECO_TUFT if roll < 18 else DECO_NONE
		if h <= 2:
			if roll < 11:
				return DECO_TREE
			if roll < 17:
				return DECO_ROCK
			return DECO_NONE
		if h <= 6:
			return DECO_ROCK if roll < 8 else DECO_NONE
		return DECO_ROCK if roll < 4 else DECO_NONE
	# 西南密林（沼泽小潭周边）：隔位下种防挤团，密度仍显著高于草甸
	if gt.x >= 4 and gt.x <= 16 and gt.y >= 36 and gt.y <= 66:
		if posmod(gt.x + gt.y, 2) == 0 and roll < 42:
			return DECO_TREE
		if roll < 10:
			return DECO_BUSH
		return DECO_TUFT if roll < 20 else DECO_NONE
	# 果园：集市东侧规则行距的浆果灌木（一眼看出是人种的）
	if gt.x >= 43 and gt.x <= 50 and gt.y >= 55 and gt.y <= 62:
		if posmod(gt.x, 3) == 1 and posmod(gt.y, 3) == 1:
			return DECO_BUSH
		return DECO_TUFT if roll < 8 else DECO_NONE
	# 瞭望丘等缓坡草面：草丛 + 零星岩石
	if h > 0:
		if roll < 5:
			return DECO_ROCK
		return DECO_TUFT if roll < 16 else DECO_NONE
	# 村核心（切比雪夫距广场 12 tile 内）：保持整洁
	if maxi(absi(gt.x - 37), absi(gt.y - 37)) <= 12:
		if roll < 3:
			return DECO_BUSH
		return DECO_TUFT if roll < 7 else DECO_NONE
	# 其余草甸：疏树 + 灌木 + 石 + 草丛
	if roll < 5:
		return DECO_TREE
	if roll < 9:
		return DECO_BUSH
	if roll < 11:
		return DECO_ROCK
	return DECO_TUFT if roll < 21 else DECO_NONE

## 8 邻里有水（环面 wrap 由 TerrainMap._idx 兜底）。
static func _near_water(gt: Vector2i) -> bool:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			if TerrainMap.tile_type(gt + Vector2i(dx, dz)) == TerrainMap.T_WATER:
				return true
	return false

## tile 间环面距离（tile 单位）。
static func _tor_dist(a: Vector2i, b: Vector2i) -> float:
	var n := WorldGrid.GRID_TILES
	var dx := absi(a.x - b.x)
	var dz := absi(a.y - b.y)
	return Vector2(float(mini(dx, n - dx)), float(mini(dz, n - dz))).length()
