extends SceneTree
## 换场景地形重铺（scene-portal P3）：ChunkManager.rebuild() 的验收。
## 区块外观是首次 _skin 时按当时 TerrainMap 烘的、永久缓存的 ArrayMesh——地形数组换了
## 之后必须能整图重铺，否则新场景仍显示旧地形。覆盖三件事：
##   1. rebuild() 清空地面/水面 mesh 缓存（下一批铺设按新地形重建）。
##   2. rebuild() 把所有槽位复位成未铺（update() 据此重铺）。
##   3. 重铺后按新地形重建的网格确实反映新地形：村庄有水的区块换成平坦草地后无水面、
##      地面顶点更少（湖床崖壁消失）。
## _skin 只是把 _chunk_mesh/_water_mesh 的产物挂到槽位 MeshInstance（update()→_skin 的
## 布线由 test_visual_water / test_visual_landmark_rebuild 在首屏覆盖），故此处直接测
## 网格构建器 + 缓存/标志契约，裸实例即可，无需入树 / 铺设散布。
## 运行: godot --headless --script res://test/test_terrain_rebuild.gd

const HEADER := 11

var fails := 0

func _init() -> void:
	# 池塘 (24,24) 落在 wrapped 区块 (0,0)（24/25=0）——村庄地形该区块有水面。
	var pond := Vector2i(0, 0)

	# ── 基线：村庄地形（本地 _paint()），烘该区块的地面/水面网格 ──────────────
	TerrainMap.reset()
	var cm := ChunkManager.new() # 裸实例：_chunk_mesh/_water_mesh 不依赖入树或材质
	var v_ground: ArrayMesh = cm._chunk_mesh(pond)
	var v_water = cm._water_mesh(pond)
	var v_verts := (v_ground.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_check("村庄池塘区块有水面网格", v_water != null, true)
	_check("烘完地面缓存非空", cm._chunk_meshes.is_empty(), false)
	_check("烘完水面缓存非空", cm._water_meshes.is_empty(), false)

	# 模拟首屏已全铺（rebuild 应把它们全复位）：手搭与 _ready 同形的槽位标志。
	cm._slots = []
	for _i in range(9):
		cm._slots.append({ "skinned": true })
	_check("模拟全铺后 all_skinned=true", cm.all_skinned(), true)

	# ── 换成平坦全草地形并 rebuild ─────────────────────────────────────────
	TerrainMap.reset()
	var lr: Dictionary = TerrainMap.load_from_bytes(_flat_grass_bytes())
	_check("平坦地形载入 ok", lr["ok"], true)
	_check("平坦地形与村庄不同 → changed=true", lr["changed"], true)

	cm.rebuild()
	_check("rebuild 清空地面缓存", cm._chunk_meshes.is_empty(), true)
	_check("rebuild 清空水面缓存", cm._water_meshes.is_empty(), true)
	var all_reset := true
	for s in cm._slots:
		if s["skinned"]:
			all_reset = false
	_check("rebuild 复位所有 skin 标志", all_reset, true)
	_check("rebuild 后 all_skinned=false", cm.all_skinned(), false)

	# ── 按新地形重建网格：反映平坦草地（无水、崖壁消失）───────────────────────
	var g_water = cm._water_mesh(pond)
	_check("平坦地形池塘区块无水面（重铺反映新地形）", g_water == null, true)
	var g_ground: ArrayMesh = cm._chunk_mesh(pond)
	var g_verts := (g_ground.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_check("平坦地面顶点数 < 村庄（无湖床崖壁）", g_verts < v_verts, true)
	# 重建出的是新对象（缓存已清），不是复用旧的村庄网格
	_check("重建地面网格是新对象", g_ground != v_ground, true)

	cm.free()
	TerrainMap.reset() # 收尾：恢复本地生成，免得污染同进程后续

	print("test_terrain_rebuild: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

## 构造一张合法但全草地、全高度 0、无水深的平坦 .mltr（头部同 export_terrain.gd）。
func _flat_grass_bytes() -> PackedByteArray:
	var n := WorldGrid.GRID_TILES
	var count := n * n
	var buf := PackedByteArray()
	buf.resize(HEADER + 3 * count) # resize 清零 = 全草(0)/高度0/深度0
	for i in range(4):
		buf[i] = "MLTR".unicode_at(i)
	buf[4] = 1        # version
	buf[5] = n
	buf[6] = n
	buf.encode_float(7, WorldGrid.TILE_SIZE)
	return buf

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  ✗ %s: got %s, want %s" % [what, str(got), str(want)])
		fails += 1
