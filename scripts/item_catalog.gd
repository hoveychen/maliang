class_name ItemCatalog
extends RefCounted
## 物品实体目录（万物皆物品，docs/scene-item-refactor-design.md §2.1）。
## 地形矩阵 palette 引用的实体定义都从这里解析：语义（footprint/blocking/wander）
## 与渲染引用 renderRef 都来自实体行——内置定义打包在
## assets/terrain/builtin_items.json（服务端 BUILTIN_ITEMS 的对拍副本，
## server/test/terrain_assets.test.ts 锁死一致性），在线时被服务端下发的
## items[]（内置+该世界造物）整体覆盖。
##
## 还负责从 TerrainMap 物品层派生静态占用（footprint 展开），灌给
## OccupancyMap.load_static——摆放语义反转后「矩阵说了算」，客户端不再摆放时登记。

const BUILTIN_PATH := "res://assets/terrain/builtin_items.json"

## id → 实体定义 Dictionary（字段同服务端 ItemDef：renderRef/footprintW/H/blocking/pathOk/wander/spec…）
static var _defs: Dictionary = {}

static func reset() -> void:
	_defs = {}

## 打包内置定义兜底（离线/服务端未下发时）。幂等；文件缺失静默（世界秃但能跑）。
static func ensure_builtin() -> void:
	if not _defs.is_empty():
		return
	var f := FileAccess.open(BUILTIN_PATH, FileAccess.READ)
	if f == null:
		push_warning("[items] 打包内置实体缺失：%s" % BUILTIN_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_ARRAY:
		push_warning("[items] 打包内置实体 JSON 非法")
		return
	set_defs(parsed)

## 服务端下发的实体清单（world_info / scene_entered / terrain_patch 的 items[]）。
## merge 语义：同 id 覆盖、新 id 追加——patch 只带新实体，不能把已有的冲掉。
static func set_defs(items: Variant) -> void:
	if typeof(items) != TYPE_ARRAY:
		return
	for it in items:
		if typeof(it) == TYPE_DICTIONARY and (it as Dictionary).has("id"):
			_defs[String((it as Dictionary)["id"])] = it

static func get_def(id: String) -> Dictionary:
	return _defs.get(id, {})

static func has_def(id: String) -> bool:
	return _defs.has(id)

## 内置贴纸实体 id 清单（mount=='edge'）：贴纸小铺货架数据源（phone_ui）。
static func sticker_ids() -> Array:
	ensure_builtin()
	var out := []
	for id in _defs:
		if String((_defs[id] as Dictionary).get("mount", "tile")) == "edge":
			out.append(String(id))
	out.sort()
	return out

## footprint 尺寸（含朝向就近象限旋转；与服务端 rotatedFootprint 一致）。未知实体按 1×1。
static func footprint(id: String, arg: int) -> Vector2i:
	var def := get_def(id)
	var w := int(def.get("footprintW", 1))
	var h := int(def.get("footprintH", 1))
	var quadrant := roundi(float(arg) * 360.0 / 256.0 / 90.0) % 4
	return Vector2i(h, w) if quadrant == 1 or quadrant == 3 else Vector2i(w, h)

## 从 TerrainMap 物品层派生静态占用并灌给 OccupancyMap（半格分辨率）。
## 与服务端 buildStaticOccupancy 同构：blocking footprint 锚点居中展开、环面 wrap、
## 草丛等非 blocking 不占位。地形载入/patch 应用后调用。
static func apply_static_occupancy() -> void:
	var n := WorldGrid.GRID_TILES
	var cells := PackedByteArray()
	cells.resize(OccupancyMap.CELLS * OccupancyMap.CELLS)
	for y in range(n):
		for x in range(n):
			var t := Vector2i(x, y)
			var id := TerrainMap.tile_item_id(t)
			if id.is_empty():
				continue
			var def := get_def(id)
			if not bool(def.get("blocking", true)):
				continue # 未知实体按 blocking 保守占位；草丛类明确不占
			var span := footprint(id, TerrainMap.tile_item_arg(t))
			var origin := Vector2i(x - (span.x - 1) / 2, y - (span.y - 1) / 2)
			var cell_o := OccupancyMap.tile_to_cell(origin)
			for dz in range(span.y * 2):
				for dx in range(span.x * 2):
					var c := Vector2i(posmod(cell_o.x + dx, OccupancyMap.CELLS), posmod(cell_o.y + dz, OccupancyMap.CELLS))
					cells[c.y * OccupancyMap.CELLS + c.x] = 1
	OccupancyMap.load_static(cells)
