extends SceneTree
## 把村庄场景导出成 .mltr v2 二进制（地貌 + 物品层 + palette），供 POST /admin/scenes 入库。
##
## 用法：
##   godot --headless --path . --script res://tools/export_terrain.gd -- --out village.mltr
##
## 地貌三平面与 TerrainMap._paint() 逐字节相同（上线地图与本地一致）；物品层由
## tools/scene_compose.gd 组装（地标/SDF 物件常量表 + 分区散布规则的唯一权威）。
## 格式见 server/src/terrain.ts（两边必须同步改）。

const COMPOSE := preload("res://tools/scene_compose.gd")
const HEADER_BYTES := 11

func _init() -> void:
	var out_path := _arg("--out", "village.mltr")
	var buf := build_terrain_bytes()
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
	pf.store_string(JSON.stringify(build_poi_json(), "  "))
	pf.close()
	print("导出 %s：%d 个 POI" % [poi_path, build_poi_json().size()])

	# 传送点一并导出（POST /admin/scenes 的 portals 字段直接吃它）
	var portal_path := _arg("--portal-out", out_path.get_basename() + ".portals.json")
	var qf := FileAccess.open(portal_path, FileAccess.WRITE)
	if qf == null:
		printerr("无法写入 ", portal_path)
		quit(1)
		return
	qf.store_string(JSON.stringify(build_portal_json(), "  "))
	qf.close()
	print("导出 %s：%d 个传送点" % [portal_path, build_portal_json().size()])
	quit(0)

## world.gd 的 POIS 常量 → POST /admin/scenes 的 pois 载荷（tile 由 Vector2i 摊平成 [x,y]）。
static func build_poi_json() -> Array:
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

## 村庄传送点：暂无。原先通往 forest/medieval/modern_city 的三对 portal 随那些场景退役
## 一并移除（scene-retire）——village 现为独立单场景。新场景上线时在此加回对应 portal，
## 并与对向场景的 build_portal_json() 互指（scene-portal-graph）。
static func build_portal_json() -> Array:
	return []

## 构建 .mltr v2 字节流。抽成静态函数供回测直接调用（test_terrain_export.gd）。
## 前置副作用：把 TerrainMap 复位成本地村庄地貌（组装规则要读它判水/高度）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	# 组装规则读 TerrainMap，先确保是干净的村庄 _paint()（同进程可能残留别的场景）
	TerrainMap.reset()
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
	var composed: Dictionary = COMPOSE.compose("village")
	return COMPOSE.build_v2_bytes(types, heights, depths, composed)

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
