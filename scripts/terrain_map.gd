class_name TerrainMap
extends RefCounted
## 世界地形数据模型——纯静态，首次访问时确定性生成，无随机状态。
## 地貌每 tile 三字节：类型（草/路/水）+ 高度（0..N 级台阶）+ 水深（湖床下挖级数）。
## 高度 = 地表/水面所在台阶级（山湖水面可为正）；深度只对水 tile 非零，
## 表示湖床相对水面向下挖几级——渲染用（湖床下沉/水色深浅），移动规则不看它。
## 逻辑网格沿用 WorldGrid（75×75 tile，环面 wrap）；本类只是数据，渲染在 chunk_manager。
##
## v2 起矩阵还带物品层（万物皆物品，见 docs/scene-item-refactor-design.md）：
## item_ref/item_arg 平面（tile 正上方挂的物品，palette 索引 + 朝向参数）与
## 四张边缘平面（墙/篱笆类薄片物数据位，一期恒 0）；palette 尾段把 u8 索引
## 翻成物品实体 id（实体定义见 server items 表/内置 seed）。
##
## 默认地形布局（手绘式确定性生成，坐标单位 = tile 索引 0..74）：
## - 北部主峰：(37.5, 6.5) 八级同心台地（西山脊缓坡可逐级爬到峰顶，南面陡崖）
## - 东北肩丘：(56.5, 8.5) 三级矮丘，与主峰之间留一条山口谷地
## - 东南瞭望丘：(59.5, 54.5) 三级缓坡（每环 +1 级可直接走上去），顶上是风车平台
## - 水系：主峰南麓涌泉 → 溪流汇入池塘 (24.5, 24.5) → 南出水口蜿蜒 → 西南沼泽小潭；
##   水面全部高度 0、岸边平地；西辐路压过出水口形成涉水石滩（先画水后画路）；
##   水深：溪流/沼泽全浅水(1 级)，池塘中心一圈深水(2 级)——湖床同心下挖
## - 路网：中央广场 + 四条辐路（北→登山口接上山小径、西→池塘观景、东→拐向风车丘
##   再有支径爬上丘顶、南→集市小广场），另有一条草甸小径从集市穿过环面接缝回到
##   西北出生林间空地——环面世界「一直往南走会从山背后回来」的示范

const T_GRASS := 0
const T_PATH := 1
const T_WATER := 2
## 扩展可行走地表（world-themes P1）：3/4 是 TerrainAtlas 崖唇/崖壁 B 码，不作 tile 类型，故从 5 起。
## 与 server terrain.ts T_SAND/SNOW/TILE 及 shader body-type ty 5/6/7 一一对应。
const T_SAND := 5   ## 沙地（海底：细沙）
const T_SNOW := 6   ## 雪地
const T_TILE := 7   ## 瓷砖地板
## 海底主题地表（themed-terrain P2）：与 server terrain.ts 及 TerrainTextures 层映射一一对应。
const T_COARSE_SAND := 8  ## 粗沙
const T_CORAL_SAND := 9   ## 珊瑚砂
const T_REEF := 10        ## 礁岩（可抬高，礁岩侧壁）
const T_SEAGRASS := 11    ## 海草地
const T_DEEP_BED := 12    ## 深水床（暗）
## 冰雪世界主题地表（themed-terrain P3）：与 server terrain.ts 及 TerrainTextures 层映射一一对应。
const T_PACKED_SNOW := 13 ## 压实雪
const T_ICE := 14         ## 冰面（结冰水共用此面）
const T_SLUSH := 15       ## 雪泥/融雪
const T_ROCK_SNOW := 16   ## 裸岩积雪（可抬高，岩壁）
## 侏罗纪主题地表（themed-terrain P3）：与 server terrain.ts 及 TerrainTextures 层映射一一对应。
const T_CRACKED_EARTH := 17 ## 干裂土（中国夯土/罗马斗兽场沙土共用）
const T_VOLCANIC := 18      ## 火山岩（可抬高）
const T_MUD_BOG := 19       ## 泥沼
const T_FERN := 20          ## 蕨类草地
const T_RUBBLE := 21        ## 碎石（罗马碎石共用）
## 中世纪主题地表（themed-terrain P3）：与 server terrain.ts 及 TerrainTextures 层映射一一对应。
const T_COBBLE := 22        ## 鹅卵石（中国卵石庭共用）
const T_STONE_SLAB := 23    ## 石板（中国青石板/罗马石板共用，可抬高）
const T_FARM_FURROW := 24   ## 农田垄
## 罗马主题地表（themed-terrain P3）：罗马石板复用 T_STONE_SLAB、碎石复用 T_RUBBLE、斗兽场沙土复用 T_CRACKED_EARTH。
const T_MARBLE := 25        ## 大理石（可抬高）
const T_MOSAIC := 26        ## 马赛克地
## 中国古代主题地表（themed-terrain P3）：青石板复用 T_STONE_SLAB、夯土复用 T_CRACKED_EARTH、卵石庭复用 T_COBBLE。
const T_WOOD_FLOOR := 27    ## 木地板（廊；玩具/厨房共用，可抬高）
## 现代城市主题地表（themed-terrain P3）：与 server terrain.ts 及 TerrainTextures 层映射一一对应。
const T_ASPHALT := 28       ## 沥青
const T_PAVER_BRICK := 29   ## 人行道砖（可抬高）
const T_CROSSWALK := 30     ## 斑马线
const T_CONCRETE := 31      ## 水泥（未来混凝土/医院手术室共用，可抬高）
const T_LAWN_GRID := 32     ## 草坪格
## 玩具房间主题地表（themed-terrain P3）：木地板/瓷砖复用现有类型。
const T_CARPET_RED := 33    ## 地毯红
const T_CARPET_BLUE := 34   ## 地毯蓝
const T_PUZZLE_MAT := 35    ## 拼图垫
## 厨房主题地表（themed-terrain P3）：白瓷砖/木地板复用现有类型。
const T_CHECKER_TILE := 36  ## 格纹地砖
const T_ANTISLIP := 37      ## 防滑垫（医院防滑走廊共用）
## 医院主题地表（themed-terrain P3）：白瓷砖复用 T_TILE、手术室地复用 T_CONCRETE、防滑走廊复用 T_ANTISLIP。
const T_MED_VINYL_GREEN := 38 ## 医用地胶浅绿
const T_MED_VINYL_BLUE := 39  ## 医用地胶浅蓝
## 未来机器人主题地表（themed-terrain P3）：混凝土复用 T_CONCRETE。
const T_METAL_PLATE := 40   ## 金属板（可抬高）
const T_GRATING := 41       ## 格栅
const T_GLOW_TILE := 42     ## 发光地砖
const T_HAZARD := 43        ## 警戒条纹地
const T_TOY_WALL := 44      ## 玩具房间墙面（室内房间围墙，抬高成四壁）
const T_KITCHEN_WALL := 45  ## 厨房墙面（室内房间围墙，抬高成四壁）
const T_HOSPITAL_WALL := 46 ## 医院墙面（室内房间围墙，抬高成四壁）
const T_FUTURE_WALL := 47   ## 未来舱壁墙面（室内房间围墙，抬高成四壁）
const T_YELLOW_BRICK := 48  ## 黄砖路（绿野仙踪专属；paver_brick 纹理 + 金黄 tint，无描边 body）
## 合法存储 tile 类型（校验/autotile 分组用）。
const VALID_TYPES := [T_GRASS, T_PATH, T_WATER, T_SAND, T_SNOW, T_TILE,
	T_COARSE_SAND, T_CORAL_SAND, T_REEF, T_SEAGRASS, T_DEEP_BED,
	T_PACKED_SNOW, T_ICE, T_SLUSH, T_ROCK_SNOW,
	T_CRACKED_EARTH, T_VOLCANIC, T_MUD_BOG, T_FERN, T_RUBBLE,
	T_COBBLE, T_STONE_SLAB, T_FARM_FURROW, T_MARBLE, T_MOSAIC, T_WOOD_FLOOR,
	T_ASPHALT, T_PAVER_BRICK, T_CROSSWALK, T_CONCRETE, T_LAWN_GRID,
	T_CARPET_RED, T_CARPET_BLUE, T_PUZZLE_MAT,
	T_CHECKER_TILE, T_ANTISLIP, T_MED_VINYL_GREEN, T_MED_VINYL_BLUE,
	T_METAL_PLATE, T_GRATING, T_GLOW_TILE, T_HAZARD, T_TOY_WALL,
	T_KITCHEN_WALL, T_HOSPITAL_WALL, T_FUTURE_WALL, T_YELLOW_BRICK]
## 「画在草底上的 body」类型（autotile 与邻居同类过渡）：路 + 新增地表；水另走整格湖床。
const BODY_TYPES := [T_PATH, T_SAND, T_SNOW, T_TILE,
	T_COARSE_SAND, T_CORAL_SAND, T_REEF, T_SEAGRASS, T_DEEP_BED,
	T_PACKED_SNOW, T_ICE, T_SLUSH, T_ROCK_SNOW,
	T_CRACKED_EARTH, T_VOLCANIC, T_MUD_BOG, T_FERN, T_RUBBLE,
	T_COBBLE, T_STONE_SLAB, T_FARM_FURROW, T_MARBLE, T_MOSAIC, T_WOOD_FLOOR,
	T_ASPHALT, T_PAVER_BRICK, T_CROSSWALK, T_CONCRETE, T_LAWN_GRID,
	T_CARPET_RED, T_CARPET_BLUE, T_PUZZLE_MAT,
	T_CHECKER_TILE, T_ANTISLIP, T_MED_VINYL_GREEN, T_MED_VINYL_BLUE,
	T_METAL_PLATE, T_GRATING, T_GLOW_TILE, T_HAZARD, T_TOY_WALL,
	T_KITCHEN_WALL, T_HOSPITAL_WALL, T_FUTURE_WALL, T_YELLOW_BRICK]
const MAX_HEIGHT := 255   ## 数据上限（存储为 byte）；默认地形主峰只到 8 级
const STEP_HEIGHT := 2.0  ## 每级台阶的世界高度（米）= 1 格（tile 边长）；相邻 tile 跳变可超 1 级（陡崖）
const MAX_DEPTH := 2      ## 默认地形的最大水深级数（1=浅水 2=深水；湖床 = 高度 - 深度）

static var _types := PackedByteArray()
static var _heights := PackedByteArray()
static var _depths := PackedByteArray()
## v2 物品层：tile 正上方物品（palette 索引/参数）与四面边缘（N/E/S/W 顺序）。
## item_ref/edges 用 Int32（Godot 无 Int16）容纳 v3 的 u16 palette 索引（>255）；item_arg 恒 u8。
static var _item_ref := PackedInt32Array()
static var _item_arg := PackedByteArray()
static var _edges: Array[PackedInt32Array] = []
## palette：索引-1 → 物品实体 id；本地 _paint() 地形无物品，palette 为空。
static var _palette := PackedStringArray()
## true = 数组来自服务端下发的 .mltr，而非本地 _paint()。离线/回测时恒为 false。
static var _from_server := false
## 本地 _ensure_built() 该画哪张地图。默认 "village"（既有唯一场景）；
## "village_forest" 走 100 格合并大场景（第一季，docs/s1-merged-scene-layout.md）。
## 导出工具 / 回测用 reset_scene() 切；服务端下发地形时此值不参与（load_from_bytes 覆盖）。
static var _paint_scene := "village"

const MLTR_MAGIC := "MLTR"
const MLTR_VERSION_1 := 1
const MLTR_VERSION := 2
const MLTR_VERSION_3 := 3  ## palette >255：itemRef+4 边缘 + count 升 u16 小端
const MLTR_HEADER := 11
const MLTR_PLANES := 9  ## 平面数（v1 是前 3 张；v3 平面数同 9，仅 5 张变宽）

## 边缘平面顺序，与 server/src/terrain.ts EDGE_* 一一对应。
const EDGE_N := 0
const EDGE_E := 1
const EDGE_S := 2
const EDGE_W := 3

static func is_server_loaded() -> bool:
	return _from_server

## 回测用：清空地形，让下一次访问重新 _paint()。
static func reset() -> void:
	_types = PackedByteArray()
	_heights = PackedByteArray()
	_depths = PackedByteArray()
	_item_ref = PackedInt32Array()
	_item_arg = PackedByteArray()
	_edges = []
	_palette = PackedStringArray()
	_from_server = false
	_paint_scene = "village"

## 清空并指定下一次本地重建画哪张地图（"village" / "village_forest"）。
## 调用方须自行确保 WorldGrid.configure() 已按该场景网格边长（village=75 / village_forest=100）生效。
static func reset_scene(scene_id: String) -> void:
	reset()
	_paint_scene = scene_id

## 载入服务端下发的 .mltr 地形（格式见 server/src/terrain.ts 与 tools/export_terrain.gd）。
## 兼容 v1（三平面，物品层补零）与 v2（九平面 + palette）。
## 返回 { ok: bool, changed: bool, error: String }：
##   ok=false     → 载荷不合法，调用方应保留本地 _paint() 的地形；
##   changed=true → 服务端地形与本地已有的不同（含物品层与 palette）。
## changed 很关键：chunk_manager 没有「地形变了重铺全图」的被动入口，已铺好的区块会留旧样子，
## 调用方按 changed 主动 rebuild()；地形必须在 chunk 重铺、角色落位之前就位
## （见 docs/multi-scene-design.md 步骤⑤）。
static func load_from_bytes(buf: PackedByteArray) -> Dictionary:
	if buf.size() < MLTR_HEADER:
		return _load_err("too short: %d B" % buf.size())
	for i in range(4):
		if buf[i] != MLTR_MAGIC.unicode_at(i):
			return _load_err("bad magic")
	var version := buf[4]
	if version != MLTR_VERSION_1 and version != MLTR_VERSION and version != MLTR_VERSION_3:
		return _load_err("version %d" % version)
	# 网格尺寸自描述：从地形头读边长并 configure 全局 WorldGrid（地形二进制是唯一权威，
	# 服务端 Scene.gridTiles 与此同源）。须方形、CHUNK_TILES(25) 整除（预设 50/75/100）。
	var gw := int(buf[5])
	var gh := int(buf[6])
	if gw != gh or gw <= 0 or gw > 200 or gw % 25 != 0:
		return _load_err("grid %dx%d, 须方形且 25 整除（预设 50/75/100）" % [gw, gh])
	WorldGrid.configure(gw)
	var n := gw
	var count := n * n

	var types: PackedByteArray
	var heights: PackedByteArray
	var depths: PackedByteArray
	var item_ref := PackedInt32Array()
	var item_arg := PackedByteArray()
	var edges: Array[PackedInt32Array] = []
	var palette := PackedStringArray()

	if version == MLTR_VERSION_1:
		if buf.size() != MLTR_HEADER + 3 * count:
			return _load_err("length %d" % buf.size())
		types = buf.slice(MLTR_HEADER, MLTR_HEADER + count)
		heights = buf.slice(MLTR_HEADER + count, MLTR_HEADER + 2 * count)
		depths = buf.slice(MLTR_HEADER + 2 * count, buf.size())
		item_ref.resize(count)
		item_arg.resize(count)
		for e in range(4):
			var z := PackedInt32Array()
			z.resize(count)
			edges.append(z)
	else:
		# v2：九平面全 u8；v3：itemRef+4 边缘 + palette count 升 u16 小端
		var wide := version == MLTR_VERSION_3
		var ref_w := 2 if wide else 1
		var count_w := 2 if wide else 1
		# 平面字节：types/heights/depths/itemArg 各 1B，itemRef+4 边缘各 ref_w
		var plane_bytes := 4 * count + 5 * ref_w * count
		if buf.size() < MLTR_HEADER + plane_bytes + count_w:
			return _load_err("length %d" % buf.size())
		var off := MLTR_HEADER
		types = buf.slice(off, off + count); off += count
		heights = buf.slice(off, off + count); off += count
		depths = buf.slice(off, off + count); off += count
		item_ref = _read_ref_plane(buf, off, count, wide); off += ref_w * count
		item_arg = buf.slice(off, off + count); off += count
		for e in range(4):
			edges.append(_read_ref_plane(buf, off, count, wide)); off += ref_w * count
		var pal_n := buf.decode_u16(off) if wide else buf[off]
		off += count_w
		for i in range(pal_n):
			if off >= buf.size():
				return _load_err("palette truncated at %d" % i)
			var plen := buf[off]
			off += 1
			if plen < 1 or off + plen > buf.size():
				return _load_err("palette entry %d bad length" % i)
			var id := buf.slice(off, off + plen).get_string_from_utf8()
			if id.is_empty() or palette.has(id):
				return _load_err("palette entry %d empty/duplicate" % i)
			palette.append(id)
			off += plen
		if off != buf.size():
			return _load_err("length %d, expect %d" % [buf.size(), off])
		# 引用平面的索引必须落在 palette 内
		for plane in [item_ref, edges[0], edges[1], edges[2], edges[3]]:
			for i in range(count):
				if plane[i] > pal_n:
					return _load_err("item ref %d out of palette %d" % [plane[i], pal_n])

	_ensure_built() # 先让本地地形就位，才能比对出 changed
	var changed: bool = types != _types or heights != _heights or depths != _depths \
		or item_ref != _item_ref or item_arg != _item_arg or palette != _palette
	if not changed:
		for e in range(4):
			if edges[e] != _edges[e]:
				changed = true
				break
	_types = types
	_heights = heights
	_depths = depths
	_item_ref = item_ref
	_item_arg = item_arg
	_edges = edges
	_palette = palette
	_from_server = true
	return { "ok": true, "changed": changed, "error": "" }

static func _load_err(msg: String) -> Dictionary:
	return { "ok": false, "changed": false, "error": msg }

## 读一张引用平面（itemRef/edge）到 Int32 数组：wide=v3 每格 u16 小端，否则 u8。
## 与 server/src/terrain.ts 的 putU16/readU16Plane 逐字节对齐（小端）。
static func _read_ref_plane(buf: PackedByteArray, from: int, count: int, wide: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(count)
	if wide:
		for i in range(count):
			out[i] = buf.decode_u16(from + 2 * i)
	else:
		for i in range(count):
			out[i] = buf[from + i]
	return out

## 应用服务端 terrain_patch 的增量编辑（服务端已做语义校验，这里只做边界防御）。
## patch: { paletteAppend?: [{index,itemId}], edits: [{x,y,t?,h?,d?,item?:[ref,arg]|null,edge?:[side,ref]}] }
## 返回 { ok, tiles: Array[Vector2i]（受影响 tile）, error }。先整体校验后应用——
## 失败不半改（乱序/坏载荷时调用方全量重拉，本地矩阵必须保持一致）。
static func apply_patch(patch: Dictionary) -> Dictionary:
	_ensure_built()
	var n := WorldGrid.GRID_TILES
	var pal_add: Array = patch.get("paletteAppend", []) if typeof(patch.get("paletteAppend")) == TYPE_ARRAY else []
	var edits: Array = patch.get("edits", []) if typeof(patch.get("edits")) == TYPE_ARRAY else []
	if edits.is_empty():
		return { "ok": false, "tiles": [], "error": "edits 为空" }

	# ── 校验（palette 顺序衔接 / 坐标与取值域 / 引用不越界）────────────────
	var pal_size := _palette.size()
	for p in pal_add:
		if typeof(p) != TYPE_DICTIONARY or int((p as Dictionary).get("index", -1)) != pal_size + 1 \
				or String((p as Dictionary).get("itemId", "")).is_empty():
			return { "ok": false, "tiles": [], "error": "paletteAppend 不衔接" }
		pal_size += 1
	for e in edits:
		if typeof(e) != TYPE_DICTIONARY:
			return { "ok": false, "tiles": [], "error": "坏 edit 条目" }
		var d := e as Dictionary
		var x := int(d.get("x", -1))
		var y := int(d.get("y", -1))
		if x < 0 or x >= n or y < 0 or y >= n:
			return { "ok": false, "tiles": [], "error": "tile (%d,%d) 越界" % [x, y] }
		if d.has("t") and not VALID_TYPES.has(int(d["t"])):
			return { "ok": false, "tiles": [], "error": "类型 %s 非法" % str(d["t"]) }
		for k in ["h", "d"]:
			if d.has(k) and (int(d[k]) < 0 or int(d[k]) > 255):
				return { "ok": false, "tiles": [], "error": "%s=%s 非法" % [k, str(d[k])] }
		var item: Variant = d.get("item", false) # false=缺省哨兵（null 是合法值=移除）
		if typeof(item) == TYPE_ARRAY:
			var a := item as Array
			if a.size() != 2 or int(a[0]) < 1 or int(a[0]) > pal_size or int(a[1]) < 0 or int(a[1]) > 255:
				return { "ok": false, "tiles": [], "error": "item 引用非法" }
		if d.has("edge"): # [side, ref]，ref=0 表示清空该边（与服务端 AppliedEdit 对齐）
			if typeof(d["edge"]) != TYPE_ARRAY:
				return { "ok": false, "tiles": [], "error": "edge 非法" }
			var eg := d["edge"] as Array
			if eg.size() != 2 or int(eg[0]) < 0 or int(eg[0]) > 3 or int(eg[1]) < 0 or int(eg[1]) > pal_size:
				return { "ok": false, "tiles": [], "error": "edge 引用非法" }

	# ── 应用 ───────────────────────────────────────────────────────────────
	for p in pal_add:
		_palette.append(String((p as Dictionary)["itemId"]))
	var tiles: Array = []
	for e in edits:
		var d := e as Dictionary
		var i := int(d["y"]) * n + int(d["x"])
		if d.has("t"):
			_types[i] = int(d["t"])
		if d.has("h"):
			_heights[i] = int(d["h"])
		if d.has("d"):
			_depths[i] = int(d["d"])
		var item: Variant = d.get("item", false)
		if typeof(item) == TYPE_ARRAY:
			_item_ref[i] = int((item as Array)[0])
			_item_arg[i] = int((item as Array)[1])
		elif item == null: # 显式 null = 移除物品
			_item_ref[i] = 0
			_item_arg[i] = 0
		if d.has("edge"):
			var eg := d["edge"] as Array
			_edges[int(eg[0])][i] = int(eg[1])
		tiles.append(Vector2i(int(d["x"]), int(d["y"])))
	return { "ok": true, "tiles": tiles, "error": "" }

## 世界坐标（XZ，米）→ tile 类型；直接用 tile 索引请走 tile_type。
static func type_at(p: Vector2) -> int:
	return tile_type(WorldGrid.to_tile(p))

static func tile_type(t: Vector2i) -> int:
	_ensure_built()
	return _types[_idx(t)]

static func tile_height(t: Vector2i) -> int:
	_ensure_built()
	return _heights[_idx(t)]

## 水深级数（湖床相对水面向下挖几级）；陆地恒 0。渲染专用，移动规则不看它。
static func tile_depth(t: Vector2i) -> int:
	_ensure_built()
	return _depths[_idx(t)]

## tile 正上方挂的物品实体 id；无物品返回 ""（palette 索引 0 = 无）。
## 多 tile 物品只在锚点 tile 有值，footprint 由实体定义展开。
static func tile_item_id(t: Vector2i) -> String:
	_ensure_built()
	var ref := _item_ref[_idx(t)]
	return "" if ref == 0 else _palette[ref - 1]

## 物品参数字节（朝向全字节 256 档，与 server yawToArg 对应）。
static func tile_item_arg(t: Vector2i) -> int:
	_ensure_built()
	return _item_arg[_idx(t)]

## 物品朝向（256 档 ≈1.4°/档，保住地标/SDF 物件的手调角度）。
## 缩放类视觉抖动另由 tile hash 派生，不在此。
static func tile_item_yaw_deg(t: Vector2i) -> float:
	return float(tile_item_arg(t)) * 360.0 / 256.0

## tile 某面边缘挂的物品实体 id（EDGE_N/E/S/W）；空边返回 ""。
static func edge_item_id(t: Vector2i, side: int) -> String:
	_ensure_built()
	var ref := _edges[side][_idx(t)]
	return "" if ref == 0 else _palette[ref - 1]

## 场景 palette（索引-1 → 实体 id 的只读副本），供渲染层预取实体定义。
static func palette() -> PackedStringArray:
	_ensure_built()
	return _palette.duplicate()

## 渲染用「有效地面级」：湖床所在级 = 高度 - 深度（陆地就是高度）。
## chunk_manager 按它发地面 quad 与崖壁/水下岸壁，可为负（高度 0 的水域湖床）。
static func tile_floor_level(t: Vector2i) -> int:
	return tile_height(t) - tile_depth(t)

## 移动规则（纯函数，供 can_step 与测试）：目标是水不可进；
## 一次最多升 1 级；下落超过 4 级视为空气墙。
static func step_allowed(from_h: int, to_h: int, to_type: int) -> bool:
	if to_type == T_WATER:
		return false
	var rise := to_h - from_h
	return rise <= 1 and rise >= -4

## 移动规则的 tile 版：from_t → to_t 是否允许（角色一步跨 tile 时调用）。
static func can_step(from_t: Vector2i, to_t: Vector2i) -> bool:
	return step_allowed(tile_height(from_t), tile_height(to_t), tile_type(to_t))

## tile 中心的逻辑世界坐标（米），供摆放吸附用。
static func tile_center(t: Vector2i) -> Vector2:
	var x := posmod(t.x, WorldGrid.GRID_TILES)
	var z := posmod(t.y, WorldGrid.GRID_TILES)
	return Vector2((float(x) + 0.5) * WorldGrid.TILE_SIZE, (float(z) + 0.5) * WorldGrid.TILE_SIZE)

static func _idx(t: Vector2i) -> int:
	var x := posmod(t.x, WorldGrid.GRID_TILES)
	var z := posmod(t.y, WorldGrid.GRID_TILES)
	return z * WorldGrid.GRID_TILES + x

static func _ensure_built() -> void:
	if not _types.is_empty():
		return
	var n := WorldGrid.GRID_TILES
	_types.resize(n * n)   # 清零 = 全草地
	_heights.resize(n * n) # 清零 = 高度 0
	_depths.resize(n * n)  # 清零 = 无水深
	_item_ref.resize(n * n) # 清零 = 无物品（本地 _paint() 只画地貌）
	_item_arg.resize(n * n)
	_edges = []
	for e in range(4):
		var z := PackedInt32Array()
		z.resize(n * n)
		_edges.append(z)
	_palette = PackedStringArray()
	if _paint_scene == "village_forest":
		_paint_village_forest()
	elif _paint_scene == "oz":
		_paint_oz()
	elif _paint_scene.ends_with("_interior"):
		_paint_home_interior()  # 所有室内（home_interior/snow_interior/…）= 同一张纯平木地板
	else:
		_paint()

static func _paint() -> void:
	# ---- 高地 ----
	# 北部主峰：8 级同心椭圆台地（每级 x 缩 1.3、z 缩 0.75 tile；测试/POI/爬坡路线锚定，勿动）
	for lvl in range(1, 9):
		_paint_ellipse_height(37.5, 6.5, 12.0 - 1.3 * float(lvl), 6.8 - 0.75 * float(lvl), lvl)
	# 东北肩丘：主峰东侧 1..3 级矮丘，与主峰之间在 x≈49 留出山口谷地
	for lvl in range(1, 4):
		_paint_ellipse_height(56.5, 8.5, 6.0 - 1.6 * float(lvl - 1), 4.8 - 1.2 * float(lvl - 1), lvl)
	# 东南瞭望丘：3 级缓坡（同心每环 +1，任意方向都能走上去），顶面留 3×3 平台放风车
	for lvl in range(1, 4):
		_paint_ellipse_height(59.5, 54.5, 7.5 - 2.25 * float(lvl - 1), 6.0 - 1.8 * float(lvl - 1), lvl)

	# ---- 水系（全部处于高度 0 平地；折线顶点取 tile 中心保证顶点 tile 必为水）----
	# 涌泉溪：主峰南麓 (29,13) 涌出，向西南汇入池塘北岸
	_paint_polyline_type([Vector2(29.5, 13.5), Vector2(27.5, 17.5), Vector2(25.5, 20.5)], 0.7, T_WATER)
	# 池塘（原位保持——poi_pond 与岸线测试锚定于此）
	_paint_ellipse_type(24.5, 24.5, 5.5, 4.2, T_WATER)
	# 出水口：池塘南岸向南蜿蜒（其中 (21,37) 一带稍后被西辐路盖成涉水石滩）
	_paint_polyline_type([
		Vector2(23.5, 29.5), Vector2(22.5, 33.5), Vector2(21.5, 37.5),
		Vector2(19.5, 42.5), Vector2(16.5, 46.5), Vector2(14.5, 49.5)], 0.7, T_WATER)
	# 西南沼泽小潭：溪流归宿
	_paint_ellipse_type(13.5, 50.5, 3.0, 2.5, T_WATER)

	# ---- 路网（后画：与水交叉处路面自然盖过水 = 涉水石滩）----
	_paint_rect_type(34, 34, 41, 41, T_PATH)   # 中央广场（水井所在）
	_paint_rect_type(37, 14, 38, 33, T_PATH)   # 北辐路：广场 → 主峰登山口
	_paint_rect_type(37, 42, 38, 60, T_PATH)   # 南辐路：广场 → 集市小广场
	_paint_rect_type(14, 37, 33, 38, T_PATH)   # 西辐路：广场 → 西郊（压过出水口成石滩）
	_paint_rect_type(42, 37, 51, 38, T_PATH)   # 东辐路：广场 → 东郊
	_paint_rect_type(35, 61, 40, 63, T_PATH)   # 集市小广场（南辐路尽头）
	# 西辐路支径：拐向池塘南岸观景处
	_paint_polyline_type([Vector2(15.5, 37.5), Vector2(17.5, 33.5), Vector2(20.5, 30.5)], 1.0, T_PATH)
	# 东辐路支径：拐向东南，接瞭望丘西麓
	_paint_polyline_type([Vector2(51.5, 38.5), Vector2(54.5, 43.5), Vector2(53.5, 47.5)], 1.0, T_PATH)
	# 瞭望丘登顶小径：沿缓坡爬到 h2 环便收——顶面 3×3 平台留纯草放风车
	_paint_polyline_type([Vector2(53.5, 47.5), Vector2(56.5, 50.5), Vector2(57.5, 51.5)], 0.7, T_PATH)
	# 上山小径：登山口沿山脚绕到西山脊，再沿脊线（z=6 行，逐级 +1）登顶
	_paint_polyline_type([
		Vector2(37.5, 14.5), Vector2(32.5, 11.5), Vector2(28.5, 8.5),
		Vector2(26.5, 6.5), Vector2(33.5, 6.5), Vector2(37.5, 6.5)], 0.7, T_PATH)
	# 草甸小径：集市向西南穿过环面接缝（z 越过 74 wrap 回 0），回到西北出生林间空地
	_paint_polyline_type([
		Vector2(37.5, 63.5), Vector2(30.5, 67.5), Vector2(22.5, 70.5),
		Vector2(14.5, 73.5), Vector2(9.5, 77.5), Vector2(4.5, 80.5), Vector2(2.5, 82.5)], 0.7, T_PATH)

	# ---- 水深（最后画：路盖过水的涉水石滩已成路，天然深度 0）----
	# 所有存留水面基础浅水 1 级；池塘中心一圈同心加深到 2 级
	for i in range(_types.size()):
		if _types[i] == T_WATER:
			_depths[i] = 1
	_paint_ellipse_depth(24.5, 24.5, 3.6, 2.7, 2)

## 第一季合并大场景（100 格 village+forest；docs/s1-merged-scene-layout.md）。
## 约定：z 小 = 村庄近端（家，玩家出生在原点角），z 大 = 森林深处（远）。
## 只画「形状本身讲故事」的地貌骨架——广场、蜿蜒穿林小径、村东池塘、右缘直跑道；
## 外婆家/七矮人两处「林间空地」= 草地留空，密林与布景由 scene_compose.compose("village_forest") 出。
## 前置：调用方须先 WorldGrid.configure(100)（本函数按 GRID_TILES 派生尺寸）。
static func _paint_village_forest() -> void:
	# ---- 村庄核心（近原点带 z<40）----
	_paint_rect_type(16, 12, 24, 20, T_PATH)   # 中央广场（水井所在）
	# 出生角 → 广场的引路小径（玩家 spawn 在原点附近，给条明路进村）
	_paint_polyline_type([Vector2(3.5, 3.5), Vector2(10.5, 8.5), Vector2(16.5, 14.5)], 0.8, T_PATH)
	_paint_rect_type(19, 20, 21, 40, T_PATH)   # 广场 → 村北林口（接穿林小径）
	_paint_rect_type(24, 15, 34, 17, T_PATH)   # 广场东巷（农舍）
	_paint_rect_type(8, 15, 15, 17, T_PATH)    # 广场西巷（农舍）
	_paint_ellipse_type(34.5, 9.5, 5.0, 4.0, T_WATER)  # 村东池塘

	# ---- 穿林小径（村北林口 → 外婆家），一条要走完的蜿蜒路 ----
	_paint_polyline_type([
		Vector2(20.5, 40.5), Vector2(28.5, 46.5), Vector2(40.5, 50.5),
		Vector2(52.5, 56.5), Vector2(60.5, 60.5), Vector2(66.5, 64.5)], 1.0, T_PATH)

	# ---- 右缘跑道（龟兔预留）：南北向直跑道，清一条明路 ----
	_paint_rect_type(87, 8, 89, 92, T_PATH)
	# ---- 通往跑道的大道（龟兔 s1-race P4）：从广场东巷（x34）一路向东接上跑道，
	#      让点点 guide_to poi_race 有条明路可走（否则东缘跑道被密林隔断、visit 到不了）----
	_paint_rect_type(34, 16, 88, 18, T_PATH)

	# ---- 水深：水面基础浅水 1 级，池塘中心加深 2 级 ----
	for i in range(_types.size()):
		if _types[i] == T_WATER:
			_depths[i] = 1
	_paint_ellipse_depth(34.5, 9.5, 3.2, 2.4, 2)

	# ==== 地势：开阔森林连绵缓丘（同 _paint() 主峰的同心台地手法，环宽 2~3 tile/级 →
	#      相邻高差 ≤1，穿林小径穿过丘身也逐级可爬）。关键区刻意留平——丘的外环止步于其外，
	#      靠自然 h1→h0 过渡衔接，不强行压平（压平会在边界造 >1 陡崖）：
	#      村核(x<40,z<40 的广场/农舍/风车/池塘)、大道(z16~18)、跑道(x≥86)、七矮人操场(x22~38,z82~93)。====
	# 外婆家小山：小红帽「翻过小山去外婆家」，外婆家(66,60)垫 2 级，穿林小径末段爬上去。
	for lvl in range(1, 3):
		_paint_ellipse_height(66.0, 60.0, 8.0 - 3.0 * float(lvl), 8.0 - 3.0 * float(lvl), lvl)
	# 森丘 A：村庄与外婆家之间的北中林，3 级。
	for lvl in range(1, 4):
		_paint_ellipse_height(52.0, 48.0, 11.0 - 2.0 * float(lvl), 10.0 - 2.0 * float(lvl), lvl)
	# 森丘 B：小径与跑道之间的东林，3 级；外环止于 x≈84，不碰跑道(x≥86)。
	for lvl in range(1, 4):
		_paint_ellipse_height(76.0, 54.0, 10.0 - 2.0 * float(lvl), 10.0 - 2.0 * float(lvl), lvl)
	# 西森缓丘 C：2 级。
	for lvl in range(1, 3):
		_paint_ellipse_height(14.0, 64.0, 8.0 - 3.0 * float(lvl), 9.0 - 3.0 * float(lvl), lvl)
	# 南森缓丘 D：小径下方、七矮人操场以北(止于 z≈76 不碰操场 z≥82)，2 级。
	for lvl in range(1, 3):
		_paint_ellipse_height(48.0, 72.0, 7.0 - 3.0 * float(lvl), 7.0 - 3.0 * float(lvl), lvl)

## 第一季册 5《绿野仙踪》独立场景（75 格，docs/season-1-outline.md §4）。
## 只画「形状本身讲故事」的地貌骨架——一条从入口蜿蜒到翡翠城的黄砖路（远方之旅），
## 加入口小广场（portal 落脚）、玉米地空地（稻草人）、翡翠城广场（铁皮人）。
## 「黄」由专属 T_YELLOW_BRICK 地块着色（paver_brick 纹理 + 金黄 tint），塑「一条金黄的、要走到远方的路」。
## 布景（路牌/房子聚成城/玉米）由 scene_compose.compose("oz") 出。前置：调用方须先 WorldGrid.configure(75)。
static func _paint_oz() -> void:
	# ---- 黄砖路：入口(14,14) 蜿蜒到翡翠城(58,56) ----
	_paint_polyline_type([
		Vector2(10.5, 10.5), Vector2(16.5, 16.5), Vector2(24.5, 22.5),
		Vector2(30.5, 30.5), Vector2(36.5, 34.5), Vector2(44.5, 42.5),
		Vector2(52.5, 50.5), Vector2(58.5, 56.5)], 1.2, T_YELLOW_BRICK)
	# ---- 入口小广场（portal 落点 14,14 附近，好落脚）----
	_paint_rect_type(10, 10, 18, 18, T_YELLOW_BRICK)
	# ---- 翡翠城广场（黄砖路尽头，铁皮人 56,54 与「城」所在）----
	_paint_rect_type(54, 52, 62, 60, T_YELLOW_BRICK)

	# ==== 地势（同 village 主峰的同心台地手法；黄砖路末段逐级爬上城，远远就望得见翡翠城）====
	# 翡翠城高台：心 (58,55) 垫 3 级台地。顶级平台覆盖城堡(58,50)+铁皮人(56,54)+广场(54~62,52~60)，
	# 城「立在高处」。环宽 2 tile/级 → 相邻 tile 高差 ≤1，四面皆可逐级爬（不留陡崖空气墙）。
	# 黄砖路 (52,50)→(58,56) 段自 lvl1 逐环进 lvl3，每步 ≤1 级，孩子走得上去。
	for lvl in range(1, 4):
		_paint_ellipse_height(58.0, 55.0, 11.0 - 2.0 * float(lvl), 12.5 - 2.0 * float(lvl), lvl)
	# 路中缓丘：心 (44,42)（黄砖路岔口，稻草人玉米地东侧）垫 2 级小丘，让路有一次上下起伏。
	# 环宽 3 tile/级 → 坡更缓；路自西南爬上丘顶(44,42)再下到东北，两侧各 ≤1 级/步。
	for lvl in range(1, 3):
		_paint_ellipse_height(44.0, 42.0, 8.0 - 3.0 * float(lvl), 8.0 - 3.0 * float(lvl), lvl)
	# 入口小广场(10~18,10~18,含 portal 落点 14,14)与玉米地(36,34)刻意留平——两处离两丘均 >半径，天然 h0。

## 室内系统（home-interior）：玩家自己的家（50 格预设，房间只占其中一小块，见 world.gd ROOM_*）。
## 家具由玩家用既有布置模式（world.gd _begin_placement → item_place）自己摆；本函数只出空房地板，
## 不放锚点/散布（scene_compose 对 home_interior 无分支 = 空物品层）。「无天空+暖光」封闭观感见 world.gd。
## 室内重做：地貌简化成纯平地板（全格木地板、高度 0）——房间的墙/地几何由客户端 RoomStage
## 真几何渲染（scripts/room_stage.gd），不再靠抬地形块假装墙、掏实心躲露地（旧 hack 已否决）。
## 地形字节此处只承载「放置/占用坐标系」：全平地板 = 处处可走、可摆，房间边界由 RoomStage 楼板网格
## 与室内收束相机（world.gd）共同框定，玩家看不到也走不到房间外。
static func _paint_home_interior() -> void:
	var n := WorldGrid.GRID_TILES
	_paint_rect_type(0, 0, n - 1, n - 1, T_WOOD_FLOOR)  # 纯平木地板（高度/水深已在 reset 清零）

## 矩形 tile 区域 [x0..x1]×[z0..z1] 涂类型（含端点）。
static func _paint_rect_type(x0: int, z0: int, x1: int, z1: int, t: int) -> void:
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			_types[_idx(Vector2i(x, z))] = t

## 椭圆内（tile 中心判定）涂类型。
static func _paint_ellipse_type(cx: float, cz: float, rx: float, rz: float, t: int) -> void:
	for z in range(int(cz - rz), int(cz + rz) + 1):
		for x in range(int(cx - rx), int(cx + rx) + 1):
			if _in_ellipse(x, z, cx, cz, rx, rz):
				_types[_idx(Vector2i(x, z))] = t

## 椭圆内（tile 中心判定）且已是水面的 tile 涂水深——深水只在水域内加深，不越岸。
static func _paint_ellipse_depth(cx: float, cz: float, rx: float, rz: float, d: int) -> void:
	for z in range(int(cz - rz), int(cz + rz) + 1):
		for x in range(int(cx - rx), int(cx + rx) + 1):
			if _in_ellipse(x, z, cx, cz, rx, rz) and _types[_idx(Vector2i(x, z))] == T_WATER:
				_depths[_idx(Vector2i(x, z))] = d

## 椭圆内（tile 中心判定）涂高度。
static func _paint_ellipse_height(cx: float, cz: float, rx: float, rz: float, h: int) -> void:
	for z in range(int(cz - rz), int(cz + rz) + 1):
		for x in range(int(cx - rx), int(cx + rx) + 1):
			if _in_ellipse(x, z, cx, cz, rx, rz):
				_heights[_idx(Vector2i(x, z))] = h

## 矩形 tile 区域 [x0..x1]×[z0..z1] 涂高度（含端点）。
static func _paint_rect_height(x0: int, z0: int, x1: int, z1: int, h: int) -> void:
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			_heights[_idx(Vector2i(x, z))] = h

## 沿折线涂类型：tile 中心到任一线段距离 ≤ radius（tile 单位）者涂 t。
## 顶点坐标可越出 [0,75)，_idx 会环面 wrap——用于画穿过接缝的小径。
static func _paint_polyline_type(pts: Array, radius: float, t: int) -> void:
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		for z in range(int(minf(a.y, b.y) - radius) - 1, int(maxf(a.y, b.y) + radius) + 2):
			for x in range(int(minf(a.x, b.x) - radius) - 1, int(maxf(a.x, b.x) + radius) + 2):
				var c := Vector2(float(x) + 0.5, float(z) + 0.5)
				var q := Geometry2D.get_closest_point_to_segment(c, a, b)
				if c.distance_to(q) <= radius:
					_types[_idx(Vector2i(x, z))] = t

static func _in_ellipse(x: int, z: int, cx: float, cz: float, rx: float, rz: float) -> bool:
	var dx := (float(x) + 0.5 - cx) / rx
	var dz := (float(z) + 0.5 - cz) / rz
	return dx * dx + dz * dz <= 1.0
