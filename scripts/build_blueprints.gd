class_name BuildBlueprints
extends RefCounted
## 积木式造物（B1，docs/kids-thinking-build-from-parts.md）整体蓝图的**客户端镜像**。
##
## 为什么客户端要有一份：组合物落库只存 `{blueprintId, parts:[{slotId,partId,partRenderRef}]}`
## （server/src/build_blueprints.ts 的 ComposedSpec），**槽位姿来自蓝图**、不进 spec。渲染
## 组合物（chunk 重铺，无服务端会话）与拼装台实时预览（build_prompt 一次只下发一个 slotId，
## 客户端要把整副骨架拼起来）都需要「按 blueprintId 拿到全部槽的归一化位姿」——所以这份表
## 必须常驻客户端，和 placeholder_specs.gd / pack_registry.gd 同类（作者预置的静态数据）。
##
## ⚠️ 这是 server/src/build_blueprints.ts 里 BUILD_BLUEPRINTS 的镜像，**槽 id / 归一化 pose
## 必须与服务端逐字一致**（服务端是真源）。改了服务端蓝图，这里要跟着改，否则组合物会画歪。
## 归一化 pose 约定同角色锚点（_position_sticker）：原点左上，x∈[0,1] 从左到右，y∈[0,1] 从上到下。

## blueprintId → { name, baseRef, slots: [ {slotId, accept, pose:{x,y,scale,rot}, required} ] }
const BLUEPRINTS := {
	"car": {
		"name": "小车", "baseRef": "blueprint:car",
		"slots": [
			{ "slotId": "body", "accept": "car.body", "required": true, "pose": { "x": 0.5, "y": 0.45, "scale": 1.0, "rot": 0.0 } },
			{ "slotId": "wheel_back", "accept": "car.wheel", "required": true, "pose": { "x": 0.32, "y": 0.78, "scale": 0.5, "rot": 0.0 } },
			{ "slotId": "wheel_front", "accept": "car.wheel", "required": true, "pose": { "x": 0.68, "y": 0.78, "scale": 0.5, "rot": 0.0 } },
			{ "slotId": "handle", "accept": "car.handle", "required": true, "pose": { "x": 0.85, "y": 0.32, "scale": 0.6, "rot": 0.0 } },
		],
	},
	"house": {
		"name": "小房子", "baseRef": "blueprint:house",
		"slots": [
			{ "slotId": "wall", "accept": "house.wall", "required": true, "pose": { "x": 0.5, "y": 0.62, "scale": 1.0, "rot": 0.0 } },
			{ "slotId": "roof", "accept": "house.roof", "required": true, "pose": { "x": 0.5, "y": 0.28, "scale": 1.0, "rot": 0.0 } },
			{ "slotId": "door", "accept": "house.door", "required": true, "pose": { "x": 0.5, "y": 0.72, "scale": 0.5, "rot": 0.0 } },
			{ "slotId": "window", "accept": "house.window", "required": false, "pose": { "x": 0.72, "y": 0.55, "scale": 0.35, "rot": 0.0 } },
			{ "slotId": "chimney", "accept": "house.chimney", "required": false, "pose": { "x": 0.7, "y": 0.18, "scale": 0.4, "rot": 0.0 } },
		],
	},
	"train": {
		"name": "小火车", "baseRef": "blueprint:train",
		"slots": [
			{ "slotId": "engine", "accept": "train.engine", "required": true, "pose": { "x": 0.24, "y": 0.45, "scale": 1.0, "rot": 0.0 } },
			{ "slotId": "carriage", "accept": "train.car", "required": true, "pose": { "x": 0.66, "y": 0.48, "scale": 1.0, "rot": 0.0 } },
			{ "slotId": "wheel_a", "accept": "train.wheel", "required": true, "pose": { "x": 0.24, "y": 0.82, "scale": 0.4, "rot": 0.0 } },
			{ "slotId": "wheel_b", "accept": "train.wheel", "required": true, "pose": { "x": 0.66, "y": 0.82, "scale": 0.4, "rot": 0.0 } },
			{ "slotId": "funnel", "accept": "train.chimney", "required": false, "pose": { "x": 0.24, "y": 0.18, "scale": 0.4, "rot": 0.0 } },
		],
	},
	"snowman": {
		"name": "雪人", "baseRef": "blueprint:snowman",
		"slots": [
			{ "slotId": "base", "accept": "snow.big", "required": true, "pose": { "x": 0.5, "y": 0.72, "scale": 1.0, "rot": 0.0 } },
			{ "slotId": "torso", "accept": "snow.small", "required": true, "pose": { "x": 0.5, "y": 0.4, "scale": 0.7, "rot": 0.0 } },
			{ "slotId": "hat", "accept": "snow.hat", "required": false, "pose": { "x": 0.5, "y": 0.16, "scale": 0.6, "rot": 0.0 } },
			{ "slotId": "nose", "accept": "snow.nose", "required": false, "pose": { "x": 0.5, "y": 0.4, "scale": 0.25, "rot": 0.0 } },
		],
	},
	"cake": {
		"name": "蛋糕", "baseRef": "blueprint:cake",
		"slots": [
			{ "slotId": "base", "accept": "cake.base", "required": true, "pose": { "x": 0.5, "y": 0.7, "scale": 1.0, "rot": 0.0 } },
			{ "slotId": "cream", "accept": "cake.cream", "required": true, "pose": { "x": 0.5, "y": 0.52, "scale": 0.95, "rot": 0.0 } },
			{ "slotId": "topping", "accept": "cake.topping", "required": true, "pose": { "x": 0.5, "y": 0.34, "scale": 0.5, "rot": 0.0 } },
			{ "slotId": "candle", "accept": "cake.candle", "required": false, "pose": { "x": 0.5, "y": 0.18, "scale": 0.4, "rot": 0.0 } },
		],
	},
	"flower": {
		"name": "小花", "baseRef": "blueprint:flower",
		"slots": [
			{ "slotId": "petals", "accept": "flower.petals", "required": true, "pose": { "x": 0.5, "y": 0.4, "scale": 1.0, "rot": 0.0 } },
			{ "slotId": "center", "accept": "flower.center", "required": true, "pose": { "x": 0.5, "y": 0.4, "scale": 0.4, "rot": 0.0 } },
			{ "slotId": "stem", "accept": "flower.stem", "required": true, "pose": { "x": 0.5, "y": 0.74, "scale": 0.9, "rot": 0.0 } },
			{ "slotId": "leaf", "accept": "flower.leaf", "required": false, "pose": { "x": 0.64, "y": 0.64, "scale": 0.5, "rot": 0.0 } },
		],
	},
	"icecream": {
		"name": "冰淇淋", "baseRef": "blueprint:icecream",
		"slots": [
			{ "slotId": "cone", "accept": "ice.cone", "required": true, "pose": { "x": 0.5, "y": 0.74, "scale": 0.8, "rot": 0.0 } },
			{ "slotId": "scoop", "accept": "ice.scoop", "required": true, "pose": { "x": 0.5, "y": 0.42, "scale": 0.9, "rot": 0.0 } },
			{ "slotId": "topping", "accept": "ice.topping", "required": false, "pose": { "x": 0.5, "y": 0.24, "scale": 0.4, "rot": 0.0 } },
		],
	},
}

## 按 id 取蓝图（未知返回空字典）。
static func get_blueprint(id: String) -> Dictionary:
	return BLUEPRINTS.get(id, {})

## 蓝图的槽数组（未知返回空数组）。
static func slots(id: String) -> Array:
	var bp: Dictionary = BLUEPRINTS.get(id, {})
	return bp.get("slots", [])

## 取某蓝图某槽的位姿（{x,y,scale,rot}）；未知返回空字典。
static func slot_pose(blueprint_id: String, slot_id: String) -> Dictionary:
	for s in slots(blueprint_id):
		if String((s as Dictionary).get("slotId", "")) == slot_id:
			return (s as Dictionary).get("pose", {})
	return {}

## 蓝图中文名（拼装台标题用）；未知回退 id。
static func display_name(id: String) -> String:
	var bp: Dictionary = BLUEPRINTS.get(id, {})
	return String(bp.get("name", id))
