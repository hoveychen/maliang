extends SceneTree
## 把客户端 TerrainMap 确定性生成的地形导出成 .mltr 二进制，供 POST /admin/scenes 入库。
##
## 用法：
##   godot --headless --path . --script res://tools/export_terrain.gd -- --out village.mltr
##
## 导出的字节与 TerrainMap 内存里的三个数组逐字节相同——这是「地形搬到服务端」那一步的
## 验收标准：上线当天玩家看到的地图与今天完全一致，纯粹换了数据来源。
##
## 格式见 server/src/terrain.ts（两边必须同步改）：
##   magic "MLTR" 4B | version u8 | gridW u8 | gridH u8 | tileSize f32(LE) | types | heights | depths

const MAGIC := "MLTR"
const VERSION := 1
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

## 村庄侧传送点：西南小树林边缘（18,52）的平坦草地，走进半径就穿到森林的林间空地（20,18）。
## radius 单位是世界坐标（TILE_SIZE=2.0），3.0 ≈ 1.5 格：玩家还没踩到中心就已触发。
## 与 export_forest.gd 的 build_portal_json() 必须互指（test_portal.gd 对拍两边）。
static func build_portal_json() -> Array:
	return [
		{ "tile": [18, 52], "radius": 3.0, "toScene": "forest", "toTile": [20, 18] },
	]

## 构建 .mltr 字节流。抽成静态函数供回测直接调用（test_terrain_export.gd）。
static func build_terrain_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var buf := PackedByteArray()
	buf.resize(HEADER_BYTES + 3 * count)

	for i in range(4):
		buf[i] = MAGIC.unicode_at(i)
	buf[4] = VERSION
	buf[5] = n
	buf[6] = n
	buf.encode_float(7, WorldGrid.TILE_SIZE) # 小端，与 DataView.setFloat32(.., true) 一致

	# 行主序（y 外层、x 内层），与服务端 _idx = y*W + x 一致
	for y in range(n):
		for x in range(n):
			var t := Vector2i(x, y)
			var i := y * n + x
			buf[HEADER_BYTES + i] = TerrainMap.tile_type(t)
			buf[HEADER_BYTES + count + i] = TerrainMap.tile_height(t)
			buf[HEADER_BYTES + 2 * count + i] = TerrainMap.tile_depth(t)
	return buf

static func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback
