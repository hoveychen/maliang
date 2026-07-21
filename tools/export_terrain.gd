extends SceneTree
## 把场景导出成 .mltr v2 二进制（地貌 + 物品层 + palette），供 POST /admin/scenes 入库。
##
## 用法：
##   godot --headless --path . --script res://tools/export_terrain.gd -- --out village.mltr
##   godot --headless --path . --script res://tools/export_terrain.gd -- --scene village_forest --out village_forest.mltr
##
## --scene village（默认，75 格）/ village_forest（第一季合并大场景，100 格，见
## docs/s1-merged-scene-layout.md）。地貌三平面与 TerrainMap 逐字节相同（上线地图与本地一致）；
## 物品层由 tools/scene_compose.gd 组装。格式见 server/src/terrain.ts（两边必须同步改）。

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11

## 各场景网格边长（tile 数）——须与 server/src/terrain.ts PRESET_GRIDS 一致。
const SCENE_GRIDS := { "village": 75, "village_forest": 100 }

func _init() -> void:
	var scene_id := _arg("--scene", "village")
	if not SCENE_GRIDS.has(scene_id):
		printerr("未知场景 ", scene_id, "，支持：", SCENE_GRIDS.keys())
		quit(1)
		return
	var out_path := _arg("--out", scene_id + ".mltr")
	var buf := build_terrain_bytes(scene_id)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("无法写入 ", out_path, "：", error_string(FileAccess.get_open_error()))
		quit(1)
		return
	f.store_buffer(buf)
	f.close()

	var gz := buf.compress(FileAccess.COMPRESSION_GZIP)
	print("导出 %s：%d B（gzip %d B）grid=%d×%d" % [
		out_path, buf.size(), gz.size(), WorldGrid.GRID_TILES, WorldGrid.GRID_TILES])

	# POI 一并导出（POST /admin/scenes 的 pois 字段直接吃它）
	var poi_path := _arg("--poi-out", out_path.get_basename() + ".pois.json")
	var pf := FileAccess.open(poi_path, FileAccess.WRITE)
	if pf == null:
		printerr("无法写入 ", poi_path)
		quit(1)
		return
	pf.store_string(JSON.stringify(build_poi_json(scene_id), "  "))
	pf.close()
	print("导出 %s：%d 个 POI" % [poi_path, build_poi_json(scene_id).size()])

	# 传送点一并导出（POST /admin/scenes 的 portals 字段直接吃它）
	var portal_path := _arg("--portal-out", out_path.get_basename() + ".portals.json")
	var qf := FileAccess.open(portal_path, FileAccess.WRITE)
	if qf == null:
		printerr("无法写入 ", portal_path)
		quit(1)
		return
	qf.store_string(JSON.stringify(build_portal_json(scene_id), "  "))
	qf.close()
	print("导出 %s：%d 个传送点" % [portal_path, build_portal_json(scene_id).size()])
	quit(0)

## 合并大场景（village_forest）的 POI（POST /admin/scenes 的 pois 载荷）。
## 与 world.gd POIS（village 专属）分开维护——B 全量合并后客户端离线 POIS 常量的迁移
## 在 s1-hood P3-P4 补；服务端下发的就是这份。poi_grandma 的仙子台词 P4 填。
const POIS_VF := [
	{ "tile": [34, 9], "radius": 18.0, "trigger": "poi_pond", "name": "池塘", "aliases": ["湖", "水边", "河边"] },
	{ "tile": [66, 63], "radius": 14.0, "trigger": "poi_grandma", "name": "外婆家", "aliases": ["外婆", "奶奶家", "小屋"] },
	{ "tile": [30, 86], "radius": 16.0, "trigger": "poi_forest_deep", "name": "森林深处", "aliases": ["深林", "大森林", "林子深处"] },
]

## POI 载荷 → POST /admin/scenes 的 pois（tile 已是 [x,y]）。
static func build_poi_json(scene_id: String) -> Array:
	if scene_id == "village_forest":
		return POIS_VF.duplicate(true)
	return build_poi_json_village()

## world.gd 的 POIS 常量 → POST /admin/scenes 的 pois 载荷（tile 由 Vector2i 摊平成 [x,y]）。
static func build_poi_json_village() -> Array:
	var world_script: GDScript = load("res://scripts/world.gd")
	var out: Array = []
	for poi in world_script.POIS:
		var t: Vector2i = poi["tile"]
		out.append({
			"tile": [t.x, t.y],
			"radius": float(poi["radius"]),
			"trigger": String(poi["trigger"]),
			"name": String(poi["name"]),
			"aliases": poi["aliases"],
		})
	return out

## 传送点：village 与 village_forest 均暂无。B 全量合并（世界主场景不切场景）不设 portal；
## 将来若有跨场景需求在此加回，并与对向场景 build_portal_json() 互指（scene-portal-graph）。
static func build_portal_json(_scene_id: String) -> Array:
	return []

## 构建指定场景的 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_export.gd）。
## 前置副作用：configure(WorldGrid) 到该场景网格 + reset_scene 让 TerrainMap 画对应地貌
## （组装规则要读它判水/高度）。同进程可能残留别的场景，故每次都重配重画。
static func build_terrain_bytes(scene_id: String = "village") -> PackedByteArray:
	WorldGrid.configure(SCENE_GRIDS.get(scene_id, WorldGrid.DEFAULT_GRID_TILES))
	TerrainMap.reset_scene(scene_id)
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var types := PackedByteArray()
	types.resize(count)
	var heights := PackedByteArray()
	heights.resize(count)
	var depths := PackedByteArray()
	depths.resize(count)
	# 行主序（y 外层、x 内层），与服务端 _idx = y*W + x 一致
	for y in range(n):
		for x in range(n):
			var t := Vector2i(x, y)
			var i := y * n + x
			types[i] = TerrainMap.tile_type(t)
			heights[i] = TerrainMap.tile_height(t)
			depths[i] = TerrainMap.tile_depth(t)
	var composed: Dictionary = COMPOSE.compose(scene_id)
	return COMPOSE.build_v2_bytes(types, heights, depths, composed)

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
