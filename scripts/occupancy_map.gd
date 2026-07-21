class_name OccupancyMap
extends RefCounted
## 占用/碰撞数据层：0.5 tile（1m）分辨率的环面占用图（150×150 半格）。
## 层次设计：地形（类型/高度，1 tile 分辨率）在 TerrainMap，静态；
## 物件位图按位分两层防所有权污染——
##   bit0（值1）动态层：运行时摆放登记/释放（语音造物、组装器占地推演）
##   bit1（值2）静态层：从地形矩阵物品层派生（ItemCatalog.apply_static_occupancy
##   整层替换；矩阵是唯一权威，静态物摆放时不再登记）
## 另有角色层（cell → 角色 id 字典，随移动迁移，查询可排除自己）。
## 尺寸离散化约定：角色边长 1..4 tile @0.5 步进（半格 2..8）；
## 物件边长 1..16 tile @1 步进（半格 2..32）。

## 半格边长 = GRID_TILES × 2（75→150 / 100→200）。随场景网格运行时变（曾是编译期 const）；
## 由 sync_grid()/_ensure() 维护。外部（Pathfinder/ItemCatalog）直读此静态变量，故名字保留 CELLS。
static var CELLS := WorldGrid.GRID_TILES * 2
const CELL_SIZE := WorldGrid.TILE_SIZE * 0.5  ## 1m（TILE_SIZE 恒定）
const BIT_DYNAMIC := 1  ## 运行时摆放登记（occupy_rect/free_rect 只动这一位）
const BIT_STATIC := 2   ## 地形矩阵派生（load_static 整层替换）

static var _occ := PackedByteArray()
static var _chars := {}       ## cell_idx → 角色 id（String）
static var _char_rects := {}  ## 角色 id → [origin: Vector2i, w: int, h: int]（登记回执，迁移/释放用）

## 把 CELLS 与占用图重同步到当前 WorldGrid.GRID_TILES。换到不同尺寸场景后，旧的
## 角色/静态登记都是按旧 CELLS 索引的，全失效必须清空（场景加载序列随后重派生静态层、重登记角色）。
## 幂等：网格没变（且已分配）时零成本。ItemCatalog.apply_static_occupancy 读 CELLS 前必先调它。
static func sync_grid() -> void:
	var want := WorldGrid.GRID_TILES * 2
	if CELLS != want:
		CELLS = want
		_occ = PackedByteArray()
		_chars = {}
		_char_rects = {}
	if _occ.size() != CELLS * CELLS:
		_occ = PackedByteArray()
		_occ.resize(CELLS * CELLS)

static func _ensure() -> void:
	if _occ.is_empty() or CELLS != WorldGrid.GRID_TILES * 2:
		sync_grid()

## 清空全图（世界重建/测试用）。
static func clear() -> void:
	_occ = PackedByteArray()
	_chars = {}
	_char_rects = {}

## 静态层整层替换：cells 为 150×150 的 0/1 位图（ItemCatalog 从矩阵派生）。
## 动态层保持不动——地形 patch 重派生时不能把语音造物的占地冲掉。
static func load_static(cells: PackedByteArray) -> void:
	_ensure()
	for i in range(_occ.size()):
		var st := BIT_STATIC if i < cells.size() and cells[i] != 0 else 0
		_occ[i] = (_occ[i] & BIT_DYNAMIC) | st

## 拍一份不可变快照交给 worker 线程跑寻路（见 OccSnapshot）。主线程调用，
## 仅两次 duplicate（_occ 22500 字节 + _chars 小字典），微秒级；worker 从此
## 只读快照、不碰主线程仍在 char_register 写的活 _occ/_chars，无数据竞争。
static func snapshot() -> OccSnapshot:
	_ensure()
	return OccSnapshot.new(_occ.duplicate(), _chars.duplicate())

static func _idx(c: Vector2i) -> int:
	return posmod(c.y, CELLS) * CELLS + posmod(c.x, CELLS)

## 逻辑世界坐标（米）→ 半格索引。
static func to_cell(p: Vector2) -> Vector2i:
	var w := WorldGrid.wrap_pos(p)
	return Vector2i(int(w.x / CELL_SIZE), int(w.y / CELL_SIZE))

## 该世界坐标是否落在静态占用（地形矩阵派生的建筑/树/石 footprint）里。
## interaction-feedback B 档：点这类不可通行布景时，点点飞过去解释而非让玩家走去卡门口。
static func static_at(p: Vector2) -> bool:
	_ensure()
	return (_occ[_idx(to_cell(p))] & BIT_STATIC) != 0

## tile 索引 → 该 tile 的 NW 半格索引。
static func tile_to_cell(t: Vector2i) -> Vector2i:
	return Vector2i(posmod(t.x, WorldGrid.GRID_TILES) * 2, posmod(t.y, WorldGrid.GRID_TILES) * 2)

## 角色边长（tile，0.5 步进）→ 半格数（离散化 + 上下限 1..4 tile）。
static func char_span(tiles: float) -> int:
	return clampi(roundi(tiles * 2.0), 2, 8)

## 物件边长（tile，1 步进）→ 半格数（上下限 1..16 tile）。
static func prop_span(tiles: int) -> int:
	return clampi(tiles, 1, 16) * 2

## 角色中心 pos（米）+ 边长 span（半格）→ 脚印 NW 半格索引。
## Mover/Pathfinder 共用此离散化，保证寻路结果与移动判定一致。
static func footprint_origin(pos: Vector2, span: int) -> Vector2i:
	var half := float(span) * CELL_SIZE * 0.5
	return to_cell(pos - Vector2(half, half))

## 登记角色脚印；同 id 再次调用即迁移（先释放旧脚印再登记新位置）。
static func char_register(id: String, pos: Vector2, span := 2) -> void:
	char_unregister(id)
	var origin := footprint_origin(pos, span)
	_char_rects[id] = [origin, span, span]
	for dz in range(span):
		for dx in range(span):
			_chars[_idx(origin + Vector2i(dx, dz))] = id

## 释放角色脚印（角色离场/删除）。只清仍属于自己的 cell，防误擦重叠登记的他人。
static func char_unregister(id: String) -> void:
	if not _char_rects.has(id):
		return
	var r: Array = _char_rects[id]
	var origin: Vector2i = r[0]
	for dz in range(int(r[2])):
		for dx in range(int(r[1])):
			var i := _idx(origin + Vector2i(dx, dz))
			if _chars.get(i, "") == id:
				_chars.erase(i)
	_char_rects.erase(id)

## origin 起 w×h 半格内无角色脚印（exclude_id 排除自己）。
static func char_area_free(origin: Vector2i, w: int, h: int, exclude_id := "") -> bool:
	if _chars.is_empty():
		return true
	for dz in range(h):
		for dx in range(w):
			var id: String = _chars.get(_idx(origin + Vector2i(dx, dz)), "")
			if id != "" and id != exclude_id:
				return false
	return true

## origin 起 w×h 半格矩形全空闲（环面 wrap）。
static func is_free_rect(origin: Vector2i, w: int, h: int) -> bool:
	_ensure()
	for dz in range(h):
		for dx in range(w):
			if _occ[_idx(origin + Vector2i(dx, dz))] != 0:
				return false
	return true

static func occupy_rect(origin: Vector2i, w: int, h: int) -> void:
	_ensure()
	for dz in range(h):
		for dx in range(w):
			var i := _idx(origin + Vector2i(dx, dz))
			_occ[i] = _occ[i] | BIT_DYNAMIC

## 只释放动态位——静态层来自矩阵，唯有 load_static 能整层换掉它。
static func free_rect(origin: Vector2i, w: int, h: int) -> void:
	_ensure()
	for dz in range(h):
		for dx in range(w):
			var i := _idx(origin + Vector2i(dx, dz))
			_occ[i] = _occ[i] & ~BIT_DYNAMIC

## 物件可放置判定（摆放器/未来编辑器共用）：
## w×h tile 内 无水、（除非 allow_path）无路、高度与原点一致（不跨崖悬空）、
## 无已有物件占用、无角色站位（不许把物件扣在角色头上）。
## check_chars=false 供区块**确定性重摆**（LANDMARKS/散布/SDF 表按固定锚点重建）：
## 角色是暂态，站在占地里不该吞掉本就存在的地标——否则玩家走近风车丘触发重刷，
## 风车消失、散布石补位（修复前实测）。运行时新摆放（语音造物/拖拽）保持默认查角色。
static func prop_area_ok(tile_origin: Vector2i, w_tiles: int, h_tiles: int, allow_path := false, check_chars := true) -> bool:
	var h0 := TerrainMap.tile_height(tile_origin)
	for dz in range(h_tiles):
		for dx in range(w_tiles):
			var t := tile_origin + Vector2i(dx, dz)
			var ty := TerrainMap.tile_type(t)
			if ty == TerrainMap.T_WATER or (ty == TerrainMap.T_PATH and not allow_path):
				return false
			if TerrainMap.tile_height(t) != h0:
				return false
	var origin := tile_to_cell(tile_origin)
	if not is_free_rect(origin, w_tiles * 2, h_tiles * 2):
		return false
	return not check_chars or char_area_free(origin, w_tiles * 2, h_tiles * 2)
