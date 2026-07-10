class_name PlaceholderSpecs
extends RefCounted
## 异步施法占位符的手写 SDF spec（schema 见 scripts/sdf_spec.gd，与服务端 SDF_PROP_SYSTEM 对齐）。
##
## 造角色/造物要等服务端跑完 LLM 设计 + 生图，几秒到十几秒。此前孩子被钉在近身对话里干等，
## 只有一行「施法中…」。改成：一开工就退出对话、就地立起一个占位符，孩子可以绕着它跑、
## 等东西从里面出来。传送门 = 要来一个新伙伴；魔法熔炉 = 要造出一个新物件。
##
## 写成 GDScript 常量而不是 assets/sdf_props/*.json：那些 json 只喂给烘焙工具，导出到 APK 时
## 不一定带上；常量跟着脚本走，必然在包里。约束（test_placeholder_specs 逐条断言）：
##   - 所有部件最低点 ≥ 0（不埋进地面），最低的那件要贴地（不悬空）
##   - 旋转件的轨道最低点也 ≥ 0（转一圈不会沉进地里）
##   - 装饰件（发光小球）中心必须在宿主表面之外，否则被引擎收进皮下、看不见

## 传送门：两根竖柱 + 门楣 + 一面发光门板，两颗小星绕着门板转。
## blend 压到 0.10——再大门板就被两根柱子吸成一坨圆疙瘩，看不出「门」。
## 门楣压到 y=1.30 与柱顶齐平（原来 1.36 会在肩部留一道台阶）。
const PORTAL := {
	"name": "magic_portal",
	"palette": ["#6a4bd6", "#b49bff", "#ffe082"],
	"blend": 0.10,
	"outline": 0.04,
	"parts": [
		{"shape": "capsule", "pos": [-0.42, 0.72, 0.0], "r": 0.11, "len": 1.16, "color": 0, "blend": 0.06},
		{"shape": "capsule", "pos": [0.42, 0.72, 0.0], "r": 0.11, "len": 1.16, "color": 0, "blend": 0.06},
		{"shape": "capsule", "pos": [0.0, 1.30, 0.0], "r": 0.11, "len": 0.86, "rot": [0, 0, 90], "color": 0, "blend": 0.06},
		{"shape": "box", "pos": [0.0, 0.74, 0.0], "size": [0.70, 1.02, 0.09], "color": 1, "blend": 0.04},
		# 门板表面在 z=±0.045，小星中心放到 z=0.08 才露在外面（埋进去就被引擎收进皮下）
		{"shape": "sphere", "pos": [0.0, 1.04, 0.08], "r": 0.075, "color": 2, "blend": 0.05,
			"spin": {"pivot": [0.0, 0.74, 0.08], "axis": [0, 0, 1], "rate": 0.6}},
		{"shape": "sphere", "pos": [0.0, 0.44, 0.08], "r": 0.075, "color": 2, "blend": 0.05,
			"spin": {"pivot": [0.0, 0.74, 0.08], "axis": [0, 0, 1], "rate": 0.6}},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}

## 魔法熔炉：底座 + 炉体 + 深色炉口边沿 + 鼓出来的火球，两颗火星绕着炉口水平转。
## 深色边沿是关键：没有它，炉体被 blend 磨圆后活像一块墓碑。全局 blend 压到 0.09 保住方正感。
const FORGE := {
	"name": "magic_forge",
	"palette": ["#7d6552", "#ff7a3c", "#ffd66b", "#4a3d33"],
	"blend": 0.09,
	"outline": 0.04,
	"parts": [
		{"shape": "box", "pos": [0.0, 0.07, 0.0], "size": [0.90, 0.14, 0.90], "color": 0, "blend": 0.05},
		{"shape": "box", "pos": [0.0, 0.40, 0.0], "size": [0.62, 0.56, 0.62], "color": 0, "blend": 0.05},
		{"shape": "box", "pos": [0.0, 0.70, 0.0], "size": [0.74, 0.10, 0.74], "color": 3, "blend": 0.04},
		# 炉口边沿顶面在 y=0.75，火球球心抬到 0.76 才鼓出来
		{"shape": "sphere", "pos": [0.0, 0.76, 0.0], "r": 0.24, "color": 1, "blend": 0.13},
		{"shape": "sphere", "pos": [0.30, 1.02, 0.0], "r": 0.07, "color": 2, "blend": 0.05,
			"spin": {"pivot": [0.0, 1.02, 0.0], "axis": [0, 1, 0], "rate": 0.8}},
		{"shape": "sphere", "pos": [-0.30, 1.02, 0.0], "r": 0.07, "color": 2, "blend": 0.05,
			"spin": {"pivot": [0.0, 1.02, 0.0], "axis": [0, 1, 0], "rate": 0.8}},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}
