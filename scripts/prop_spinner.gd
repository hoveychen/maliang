class_name PropSpinner
extends Node
## 程序化匀速自转驱动器（models-play-animation P2）。
## 作为目标 Node3D 的子节点挂载，每帧绕目标自身局部轴旋转它——用于风车扇叶这类
## glb 本身不带动画轨、却应当匀速转动的部件（KayKit 六边形集把扇叶做成独立命名
## 子节点 building_windmill_top_fan_*，故可直接旋转该节点而不动塔身）。
## 纯客户端、零服务端改动；无 AnimationPlayer/骨骼开销，只是一次 rotate_object_local。

## 绕目标局部空间的哪根轴转（风车扇叶盘面法线方向）。_spawn_fan_spinner 按模型朝向传入。
@export var axis: Vector3 = Vector3(0.0, 0.0, 1.0)
## 角速度（弧度/秒）。风车取悠缓的观感速度，不喧宾夺主。
@export var speed: float = 0.6

func _process(delta: float) -> void:
	var target := get_parent() as Node3D
	if target == null:
		return
	target.rotate_object_local(axis, speed * delta)
