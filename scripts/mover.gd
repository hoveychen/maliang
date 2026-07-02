class_name Mover
extends RefCounted
## 角色移动统一入口——NPC 行为执行器与未来玩家操控都走 attempt()，
## 保证同一套地形规则（升 1 格/落差 4 格空气墙/水禁入，见 TerrainMap.step_allowed）
## 与占用检查（物件脚印，见 OccupancyMap）。
## 角色暂不写入占用图（无寻路的 NPC 互相登记会彼此卡死；等寻路计划再开）。

## 尝试从 cur 平移 delta_v（逻辑坐标，米）。整步不行就退化为 X/Z 单轴滑动；
## 全被挡返回原位置。span = 角色占地边长（半格数，OccupancyMap.char_span）。
static func attempt(cur: Vector2, delta_v: Vector2, span := 2) -> Vector2:
	for cand in [delta_v, Vector2(delta_v.x, 0.0), Vector2(0.0, delta_v.y)]:
		if cand.is_zero_approx():
			continue
		var nxt := WorldGrid.wrap_pos(cur + cand)
		if _passable(cur, nxt, span):
			return nxt
	return cur

static func _passable(cur: Vector2, nxt: Vector2, span: int) -> bool:
	var ft := WorldGrid.to_tile(cur)
	var tt := WorldGrid.to_tile(nxt)
	if ft != tt and not TerrainMap.can_step(ft, tt):
		return false
	# 脚印（以 nxt 为中心的 span×span 半格）不得压到物件占地
	var half := float(span) * OccupancyMap.CELL_SIZE * 0.5
	var origin := OccupancyMap.to_cell(nxt - Vector2(half, half))
	return OccupancyMap.is_free_rect(origin, span, span)
