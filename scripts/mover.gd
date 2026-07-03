class_name Mover
extends RefCounted
## 角色移动统一入口——NPC 行为执行器与未来玩家操控都走 attempt()，
## 保证同一套地形规则（升 1 格/落差 4 格空气墙/水禁入，见 TerrainMap.step_allowed）
## 与占用检查（物件脚印 + 角色层，见 OccupancyMap；exclude_id 排除自己）。

## 尝试从 cur 平移 delta_v（逻辑坐标，米）。整步不行就退化为 X/Z 单轴滑动；
## 全被挡返回原位置。span = 角色占地边长（半格数，OccupancyMap.char_span）；
## exclude_id = 移动者自己的角色 id（已登记角色层时必传，否则被自己的脚印挡死）。
static func attempt(cur: Vector2, delta_v: Vector2, span := 2, exclude_id := "") -> Vector2:
	for cand in [delta_v, Vector2(delta_v.x, 0.0), Vector2(0.0, delta_v.y)]:
		if cand.is_zero_approx():
			continue
		var nxt := WorldGrid.wrap_pos(cur + cand)
		if _passable(cur, nxt, span, exclude_id):
			return nxt
	return cur

static func _passable(cur: Vector2, nxt: Vector2, span: int, exclude_id: String) -> bool:
	var ft := WorldGrid.to_tile(cur)
	var tt := WorldGrid.to_tile(nxt)
	if ft != tt and not TerrainMap.can_step(ft, tt):
		return false
	# 脚印（以 nxt 为中心的 span×span 半格）不得压到物件占地或他人站位
	var origin := OccupancyMap.footprint_origin(nxt, span)
	return OccupancyMap.is_free_rect(origin, span, span) \
		and OccupancyMap.char_area_free(origin, span, span, exclude_id)
