extends SceneTree
## 玩家跨图长走的寻路上限回归（house-interiors 真机 snow 走不到的真因）。
##
## 背景：BehaviorExecutor._run_plan 的 A* 上限对 NPC 是 1500（近程够用、远目标早认输走直线）。
## 但玩家点远处/走进远传送门/跟点点引路是【合法长路】。100 格 village_forest 上从村核 (24,31)
## 到七矮人小屋门口 (30,92) 是条 ~60 tile 的森林长路，A* 要探 ~2000 节点——1500 认输返空 →
## 玩家退化直线滑动、撞第一个障碍就不动（真机实测 snow 走不到即此）。玩家 executor 用
## world.gd PLAYER_PATH_MAX_ITER 抬高上限修复。
##
## 断言：同一条真实长路，NPC 上限 1500 返空（复现病）、玩家上限找得到路（修复）。
## 运行: godot --headless --script res://test/test_player_pathfind_range.gd
const EX := preload("res://tools/export_terrain.gd")
const World := preload("res://scripts/world.gd")
# 阻挡物 span（tuft/well/bowl pathOk 不挡）——与 chunk_manager 静态占用一致。
const SPAN := {"house_0":3,"house_1":3,"house_2":3,"house_3":3,"windmill":3,"walking_hut":3,"hop_mailbox":3,
	"emerald_castle":3,"dwarf_cottage":3,"toy_bed_single":3,"toy_table":3,"toy_sofa":3}
const PATHOK := {"well":true,"dwarf_bowl":true,"tuft_0":true,"tuft_1":true}

func _init() -> void:
	var fails := 0
	# 载入真实 village_forest 地形 + 复刻静态占用（阻挡物按 footprint 占格）。
	TerrainMap.reset()
	TerrainMap.load_from_bytes(EX.build_terrain_bytes("village_forest"))
	var n := WorldGrid.GRID_TILES
	OccupancyMap.clear()
	for y in range(n):
		for x in range(n):
			var id := TerrainMap.tile_item_id(Vector2i(x, y))
			if id.is_empty() or PATHOK.has(id):
				continue
			var s: int = SPAN.get(id, 1)
			var r := (s - 1) / 2
			OccupancyMap.occupy_rect(OccupancyMap.tile_to_cell(Vector2i(x - r, y - r)), s * 2, s * 2)
	var snap := OccupancyMap.snapshot()

	# 真机复现坐标：村核家门返回落点 (24,31) → 七矮人小屋进门 (30,92)。
	var from := WorldGrid.from_tile_center(Vector2i(24, 31))
	var to := WorldGrid.from_tile_center(Vector2i(30, 92))

	# NPC 默认上限 1500：这条长路认输返空（正是「snow 走不到」的病态）。
	var npc_path := Pathfinder.find_path(from, to, 2, "", true, 1500, false, snap)
	fails += _check("NPC 上限 1500 对这条长路返空（复现病）", npc_path.is_empty(), true)

	# 玩家上限：同一条路找得到（修复）。
	var player_path := Pathfinder.find_path(from, to, 2, "", true, World.PLAYER_PATH_MAX_ITER, false, snap)
	fails += _check("玩家上限 PLAYER_PATH_MAX_ITER 找得到这条长路（修复）", not player_path.is_empty(), true)
	fails += _check("玩家上限 ≥ 2000（覆盖 snow 长路所需 ~2000 节点）", World.PLAYER_PATH_MAX_ITER >= 2000, true)

	OccupancyMap.clear()
	TerrainMap.reset()
	print("test_player_pathfind_range: ", "PASS" if fails == 0 else "FAIL(%d)" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  ✗ %s: got %s, want %s" % [name, got, want])
	return 1
