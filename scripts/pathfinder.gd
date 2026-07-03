class_name Pathfinder
extends RefCounted
## 0.5 格（半格）A* 寻路——纯静态函数，无状态。
## 节点 = OccupancyMap 半格索引（150×150 环面 wrap）。
## 通行判定与 Mover._passable 完全一致：footprint（span×span 半格）不压占用
## + 跨 tile 时 TerrainMap.can_step（升 ≤1 级/落差 >4 空气墙/水禁入）——
## 保证返回的相邻 waypoint 逐步喂给 Mover.attempt 必然原样通过。
## 对角步要求两正交邻居均可通行（防穿角）；启发式用环面 octile 距离（可采纳）。

const STRAIGHT := 10  ## 正交一步代价
const DIAGONAL := 14  ## 对角一步代价（≈10√2）

const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## 从逻辑坐标 from_pos 寻路到 to_pos（米）。返回 waypoint 序列（半格中心的逻辑坐标，
## 不含起点格，含终点格）；无路/已在原格返回空数组（调用方回退直线滑动）。
## 目标格不可通行时（如目标是角色/物件所在），螺旋搜索最近可通行格替代；
## simplify=false 保留逐格路径（测试用），true 时合并同向直线段。
static func find_path(from_pos: Vector2, to_pos: Vector2, span := 2, simplify := true, max_iter := 8000) -> PackedVector2Array:
	var start := OccupancyMap.to_cell(from_pos)
	var goal := _resolve_goal(to_pos, span)
	if goal == Vector2i(-1, -1) or _wrap(start) == goal:
		return PackedVector2Array()

	var start_i := _idx(start)
	var goal_i := _idx(goal)
	var open: Array = []  ## 二叉堆，元素 [f, 序号, cell_idx]（序号作稳定 tiebreak）
	var g := {start_i: 0}
	var came := {}
	var closed := {}
	var push_seq := 0
	_heap_push(open, [_heuristic(start, goal), push_seq, start_i])

	var iter := 0
	while not open.is_empty() and iter < max_iter:
		iter += 1
		var cur_i: int = _heap_pop(open)[2]
		if cur_i == goal_i:
			return _reconstruct(came, cur_i, start_i, simplify)
		if closed.has(cur_i):
			continue
		closed[cur_i] = true
		var cur := _from_idx(cur_i)
		for dir in DIRS:
			var nxt := _wrap(cur + dir)
			var nxt_i := _idx(nxt)
			if closed.has(nxt_i) or not _step_ok(cur, nxt, span):
				continue
			if dir.x != 0 and dir.y != 0:
				# 防穿角：对角步要求两正交邻居也可通行
				if not _step_ok(cur, _wrap(cur + Vector2i(dir.x, 0)), span) \
						or not _step_ok(cur, _wrap(cur + Vector2i(0, dir.y)), span):
					continue
			var cost := DIAGONAL if (dir.x != 0 and dir.y != 0) else STRAIGHT
			var ng: int = g[cur_i] + cost
			if g.has(nxt_i) and ng >= g[nxt_i]:
				continue
			g[nxt_i] = ng
			came[nxt_i] = cur_i
			push_seq += 1
			_heap_push(open, [ng + _heuristic(nxt, goal), push_seq, nxt_i])
	return PackedVector2Array()

## 半格索引 → 该半格中心的逻辑坐标（米）。
static func cell_center(c: Vector2i) -> Vector2:
	var w := _wrap(c)
	return Vector2((float(w.x) + 0.5) * OccupancyMap.CELL_SIZE, (float(w.y) + 0.5) * OccupancyMap.CELL_SIZE)

## 单步通行判定（from 半格 → 相邻 to 半格），规则与 Mover._passable 逐条对应。
static func step_ok(from_c: Vector2i, to_c: Vector2i, span := 2) -> bool:
	return _step_ok(_wrap(from_c), _wrap(to_c), span)

## 站位判定：角色中心在半格 c 中心时 footprint 是否全空闲（不含地形，地形在 step_ok）。
static func cell_free(c: Vector2i, span := 2) -> bool:
	var pos := cell_center(c)
	var half := float(span) * OccupancyMap.CELL_SIZE * 0.5
	var origin := OccupancyMap.to_cell(pos - Vector2(half, half))
	return OccupancyMap.is_free_rect(origin, span, span)

static func _step_ok(from_c: Vector2i, to_c: Vector2i, span: int) -> bool:
	if not cell_free(to_c, span):
		return false
	var ft := WorldGrid.to_tile(cell_center(from_c))
	var tt := WorldGrid.to_tile(cell_center(to_c))
	return ft == tt or TerrainMap.can_step(ft, tt)

## 目标格可通行则原样返回；否则螺旋（chebyshev 环 r=1..8）找离 to_pos 最近的
## 可通行格；全无返回 (-1,-1)。
static func _resolve_goal(to_pos: Vector2, span: int) -> Vector2i:
	var goal := _wrap(OccupancyMap.to_cell(to_pos))
	if cell_free(goal, span):
		return goal
	for r in range(1, 9):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var c := _wrap(goal + Vector2i(dx, dz))
				if not cell_free(c, span):
					continue
				var d := WorldGrid.shortest_delta(to_pos, cell_center(c)).length_squared()
				if d < best_d:
					best_d = d
					best = c
		if best != Vector2i(-1, -1):
			return best
	return Vector2i(-1, -1)

## 环面 octile 启发：每轴取最短 wrap 距离。
static func _heuristic(a: Vector2i, b: Vector2i) -> int:
	var dx := absi(a.x - b.x)
	dx = mini(dx, OccupancyMap.CELLS - dx)
	var dz := absi(a.y - b.y)
	dz = mini(dz, OccupancyMap.CELLS - dz)
	return DIAGONAL * mini(dx, dz) + STRAIGHT * absi(dx - dz)

static func _reconstruct(came: Dictionary, goal_i: int, start_i: int, simplify: bool) -> PackedVector2Array:
	var cells: Array[Vector2i] = []
	var cur := goal_i
	while cur != start_i:
		cells.push_front(_from_idx(cur))
		cur = came[cur]
	if simplify:
		cells = _merge_collinear(cells, _from_idx(start_i))
	var out := PackedVector2Array()
	for c in cells:
		out.append(cell_center(c))
	return out

## 合并同向直线段：只保留方向变化处与终点的 waypoint。
static func _merge_collinear(cells: Array[Vector2i], start: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var prev := start
	var prev_dir := Vector2i.ZERO
	for i in range(cells.size()):
		var d := WorldGrid.shortest_delta(cell_center(prev), cell_center(cells[i]))
		var dir := Vector2i(signi(roundi(d.x * 2.0)), signi(roundi(d.y * 2.0)))
		if i > 0 and dir != prev_dir:
			out.append(cells[i - 1])
		prev_dir = dir
		prev = cells[i]
	out.append(cells[cells.size() - 1])
	return out

static func _wrap(c: Vector2i) -> Vector2i:
	return Vector2i(posmod(c.x, OccupancyMap.CELLS), posmod(c.y, OccupancyMap.CELLS))

static func _idx(c: Vector2i) -> int:
	return c.y * OccupancyMap.CELLS + c.x

static func _from_idx(i: int) -> Vector2i:
	@warning_ignore("integer_division")
	return Vector2i(i % OccupancyMap.CELLS, i / OccupancyMap.CELLS)

# --- 最小二叉堆（元素 [f, 序号, cell_idx]，按 f 再按序号升序） ---

static func _heap_less(a: Array, b: Array) -> bool:
	return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1])

static func _heap_push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		@warning_ignore("integer_division")
		var p := (i - 1) / 2
		if _heap_less(heap[i], heap[p]):
			var tmp: Array = heap[i]
			heap[i] = heap[p]
			heap[p] = tmp
			i = p
		else:
			break

static func _heap_pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var m := i
			if l < heap.size() and _heap_less(heap[l], heap[m]):
				m = l
			if r < heap.size() and _heap_less(heap[r], heap[m]):
				m = r
			if m == i:
				break
			var tmp: Array = heap[i]
			heap[i] = heap[m]
			heap[m] = tmp
			i = m
	return top
