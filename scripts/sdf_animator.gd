class_name SdfAnimator
extends RefCounted
## SDF 物件的程序化动画驱动（占位骨架，P4 实现步态/跳跃/悬停/物理绳）。

var prop: SdfProp
var time := 0.0

func _init(p: SdfProp) -> void:
	prop = p

func advance(delta: float) -> void:
	time += delta
