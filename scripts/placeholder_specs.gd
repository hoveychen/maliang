class_name PlaceholderSpecs
extends RefCounted
## 异步施法占位符的手写 SDF spec（schema 见 scripts/sdf_spec.gd，与服务端 SDF_PROP_SYSTEM 对齐）。
##
## 造角色/造物要等服务端跑完 LLM 设计 + 生图，几秒到十几秒。此前孩子被钉在近身对话里干等，
## 只有一行「施法中…」。改成：一开工就退出对话、就地立起一个占位符，孩子可以绕着它跑、
## 等东西从里面出来。降生蛋 = 要来一个新伙伴；魔法熔炉 = 要造出一个新物件。
##
## 写成 GDScript 常量而不是 assets/sdf_props/*.json：那些 json 只喂给烘焙工具，导出到 APK 时
## 不一定带上；常量跟着脚本走，必然在包里。约束（test_placeholder_specs 逐条断言）：
##   - 所有部件最低点 ≥ 0（不埋进地面），最低的那件要贴地（不悬空）
##   - 旋转件的轨道最低点也 ≥ 0（转一圈不会沉进地里）
##   - 装饰件（斑点/光点）中心必须在宿主表面之外，否则被引擎收进皮下、看不见
##   - color_k 要压到 0.08（默认 0.18 会把小装饰件的颜色洗成宿主色）
##
## 注意：新伙伴占位符不许做成矩形拱门——portal_arch.json 已被 world.gd 用作场景传送门，
## 撞脸会让孩子以为走进去能换地图。所以这里是「蛋」不是「门」。

## 降生蛋：淡紫魔法圆台 + 奶油色大蛋（两球融出蛋形）+ 薄荷斑点 + 蛋顶小绿芽，
## 两颗金色光点绕蛋公转。蛋 = 孩子都懂的「里面有新朋友要孵出来」。
## 斑点中心离蛋心 ≥0.41 > 蛋半径 0.36，光点轨道半径 0.55，都露在表面之外。
const PORTAL := {
	"name": "hatching_egg",
	"palette": ["#b49bff", "#fff3dc", "#79d0b8", "#7a9e4f", "#ffc63a"],
	"blend": 0.12,
	"outline": 0.04,
	"color_k": 0.08,
	"parts": [
		{"shape": "box", "pos": [0.0, 0.09, 0.0], "size": [0.78, 0.18, 0.78], "color": 0, "blend": 0.08},
		{"shape": "sphere", "pos": [0.0, 0.52, 0.0], "r": 0.36, "color": 1, "blend": 0.14},
		{"shape": "sphere", "pos": [0.0, 0.78, 0.0], "r": 0.27, "color": 1, "blend": 0.14},
		{"shape": "sphere", "pos": [0.24, 0.64, 0.31], "r": 0.10, "color": 2, "blend": 0.04},
		{"shape": "sphere", "pos": [-0.26, 0.50, 0.32], "r": 0.09, "color": 2, "blend": 0.04},
		{"shape": "sphere", "pos": [0.10, 0.90, 0.26], "r": 0.07, "color": 2, "blend": 0.04},
		{"shape": "cone", "pos": [0.0, 1.13, 0.0], "r1": 0.035, "r2": 0.12, "h": 0.18, "color": 3, "blend": 0.06},
		{"shape": "sphere", "pos": [0.55, 0.88, 0.0], "r": 0.065, "color": 4, "blend": 0.03,
			"spin": {"pivot": [0.0, 0.88, 0.0], "axis": [0, 1, 0], "rate": 0.5}},
		{"shape": "sphere", "pos": [-0.55, 0.62, 0.0], "r": 0.065, "color": 4, "blend": 0.03,
			"spin": {"pivot": [0.0, 0.62, 0.0], "axis": [0, 1, 0], "rate": 0.5}},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}

## 魔法熔炉：奶油底座 + 砖红方炉身 + 奶油台面板（两段式轮廓，像砌出来的）+ 正面深色炉口、
## 口里鼓出橙色火球 + 深色方烟囱、囱顶大火苗和两颗金色火星绕转。烟囱冒火 = 一眼「炉子烧着呢」。
## 炉口箱与火球逐层外推（箱心 z=0.38 > 炉身半深 0.35，火球再出箱面 0.06），不会被融进皮下。
const FORGE := {
	"name": "magic_forge",
	"palette": ["#f4ead4", "#96432f", "#3e332b", "#ff8a3d", "#ffc63a"],
	"blend": 0.12,
	"outline": 0.04,
	"color_k": 0.08,
	"parts": [
		{"shape": "box", "pos": [0.0, 0.07, 0.0], "size": [1.0, 0.14, 0.9], "color": 0, "blend": 0.06},
		{"shape": "box", "pos": [0.0, 0.45, 0.0], "size": [0.88, 0.62, 0.70], "color": 1, "blend": 0.05},
		{"shape": "box", "pos": [0.0, 0.80, 0.0], "size": [0.96, 0.10, 0.78], "color": 0, "blend": 0.05},
		{"shape": "box", "pos": [0.0, 0.33, 0.38], "size": [0.36, 0.34, 0.16], "color": 2, "blend": 0.04},
		{"shape": "sphere", "pos": [0.0, 0.29, 0.52], "r": 0.13, "color": 3, "blend": 0.06},
		{"shape": "box", "pos": [0.26, 1.04, -0.14], "size": [0.20, 0.42, 0.20], "color": 2, "blend": 0.05},
		{"shape": "cone", "pos": [0.26, 1.44, -0.14], "r1": 0.16, "r2": 0.05, "h": 0.28, "color": 3, "blend": 0.04},
		{"shape": "sphere", "pos": [0.52, 1.48, -0.14], "r": 0.05, "color": 4, "blend": 0.03,
			"spin": {"pivot": [0.26, 1.48, -0.14], "axis": [0, 1, 0], "rate": 1.2}},
		{"shape": "sphere", "pos": [0.0, 1.48, -0.14], "r": 0.05, "color": 4, "blend": 0.03,
			"spin": {"pivot": [0.26, 1.48, -0.14], "axis": [0, 1, 0], "rate": 1.2}},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}

## 魔法画板（造贴纸占位符）：木色底座横木（贴地）+ 后竖支腿 + 奶油画布立面 + 画布正面两团
## 粉/蓝颜料 + 两颗金光点绕画布公转。画架+颜料 = 一眼「这儿在画/做一张贴纸」。
## 颜料团中心 z=0.14 > 画布正面 z=0.08，露在画布外；光点轨道半径 0.60 > 画布半宽 0.43，绕在板外。
## P2 会在此基础上加「答案泼颜料」的动感（每轮答案化作一团颜料飞上画布）。
const EASEL := {
	"name": "magic_easel",
	"palette": ["#c9a06a", "#fff8ec", "#ff5b7f", "#48c0e8", "#ffc63a"],
	"blend": 0.12,
	"outline": 0.04,
	"color_k": 0.08,
	"parts": [
		{"shape": "box", "pos": [0.0, 0.07, 0.0], "size": [0.9, 0.14, 0.34], "color": 0, "blend": 0.06},
		{"shape": "box", "pos": [0.0, 0.62, -0.14], "size": [0.14, 1.1, 0.12], "color": 0, "blend": 0.05},
		{"shape": "box", "pos": [0.0, 0.82, 0.02], "size": [0.86, 0.92, 0.12], "color": 1, "blend": 0.05},
		{"shape": "sphere", "pos": [0.22, 0.95, 0.14], "r": 0.12, "color": 2, "blend": 0.05},
		{"shape": "sphere", "pos": [-0.20, 0.68, 0.14], "r": 0.10, "color": 3, "blend": 0.05},
		{"shape": "sphere", "pos": [0.60, 0.95, 0.02], "r": 0.06, "color": 4, "blend": 0.03,
			"spin": {"pivot": [0.0, 0.95, 0.02], "axis": [0, 1, 0], "rate": 0.7}},
		{"shape": "sphere", "pos": [-0.60, 0.70, 0.02], "r": 0.06, "color": 4, "blend": 0.03,
			"spin": {"pivot": [0.0, 0.70, 0.02], "axis": [0, 1, 0], "rate": 0.7}},
	],
	"locomotion": {"type": "none"},
	"ropes": [],
}
