class_name OccSnapshot
extends RefCounted
## OccupancyMap 的不可变快照——寻路发起帧在主线程拍下 _occ（物件层位图）与
## _chars（角色层 cell→id），交给 worker 线程跑 A* 只读，绝不碰主线程仍在写的活占用图。
## is_free_rect / char_area_free 与 OccupancyMap 同名方法逐字一致（含环面 wrap 的 _idx），
## 保证「带快照的 find_path」与「同一时刻纯静态 find_path」返回完全相同的路径。
## 由 OccupancyMap.snapshot() 构造（那里做 duplicate()）；本类只读自己的副本，
## 不引用任何全局可变态——worker 线程可安全并发读多个不同快照。

const CELLS := WorldGrid.GRID_TILES * 2  ## 150，与 OccupancyMap.CELLS 一致

var _occ: PackedByteArray
var _chars: Dictionary

func _init(occ: PackedByteArray, chars: Dictionary) -> void:
	_occ = occ
	_chars = chars

func _idx(c: Vector2i) -> int:
	return posmod(c.y, CELLS) * CELLS + posmod(c.x, CELLS)

## origin 起 w×h 半格矩形全空闲（物件层）。与 OccupancyMap.is_free_rect 逐条一致。
func is_free_rect(origin: Vector2i, w: int, h: int) -> bool:
	for dz in range(h):
		for dx in range(w):
			if _occ[_idx(origin + Vector2i(dx, dz))] != 0:
				return false
	return true

## origin 起 w×h 半格内无他人角色脚印（exclude_id 排除自己）。与 OccupancyMap.char_area_free 逐条一致。
func char_area_free(origin: Vector2i, w: int, h: int, exclude_id := "") -> bool:
	if _chars.is_empty():
		return true
	for dz in range(h):
		for dx in range(w):
			var id: String = _chars.get(_idx(origin + Vector2i(dx, dz)), "")
			if id != "" and id != exclude_id:
				return false
	return true
