class_name TerrainAtlas
extends RefCounted
## 运行时程序生成的地形「控制图」atlas（themed-terrain P1 收敛版）。
## 只烘 autotile 几何 + 明暗，不烘颜色——颜色由 terrain_ground.gdshader 按 mesh 顶点
## COLOR 层索引从 Texture2DArray 采样（见 scripts/terrain_textures.gd）。逐像素输出：
##   R = 主体域掩码（1 = 路面/湖床/崖唇/崖壁/地表主体，0 = 草地基底）
##   G = 描边掩码（路亮边 / 崖缘深草；湖床无描边——岸沫归水面 shader）
##   B = 渲染角色 / 8（ROLE_*；整 cell 恒定，线性过滤安全）——仅供 shader 在描边区选 rim 色
##   A = 明暗纹样 ×0.5（动森式三角草纹/棋盘 parity/沙土斑点/崖壁地层带，shader ×2 还原）
##
## 【收敛】autotile 几何全地形共享：沙/雪/瓷砖/所有主题地表都走同一组「无描边 body」cell
## （CELL_BODY），差异全由 mesh 顶点 COLOR 层索引承载 → 加主题零 atlas 改动。
## 布局：5 列（Autotile 变体）× 21 行，cell 内容 32px + 四周 4px gutter（防 mipmap 跨 cell 渗色）：
##   row 0        草地（col 0/1 = 棋盘 parity 两种明暗）
##   row 1..4     路  （行 = Autotile 角 NW/NE/SW/SE，列 = 变体；带亮描边）
##   row 5..8     水（R/B/A 湖床主体；G = 沿岸圆角泡沫带，水面 mesh 采样）
##   row 9..12    悬崖边草皮（崖唇 + 崖缘亮草；水岸同用）
##   row 13..16   崖壁（墙格 8 邻掩码选变体）
##   row 17..20   body（草底上无描边地表：沙/雪/瓷砖/主题面共用，几何同路、无亮边）
## 过渡 cell 统一按 NW 角绘制再镜像。

const CELL := 32          ## cell 内容像素（半 tile = 1m → 32px/m）
const GUTTER := 4
const PITCH := CELL + GUTTER * 2
const COLS := 5           ## Autotile.VARIANT_COUNT
const ROWS := 21          ## 草1 + 路4 + 水4 + 崖唇4 + 崖壁4 + body4
const W := COLS * PITCH   ## 200
const H := ROWS * PITCH   ## 840

## uv_rect 的 cell 种类码（= autotile 几何行组；顶三值与 TerrainMap.T_* 巧合对齐，历史遗留）。
const CELL_GRASS := 0
const CELL_PATH := 1
const CELL_WATER := 2
const CELL_CLIFF_RIM := 3
const CELL_CLIFF_WALL := 4
const CELL_BODY := 8       ## 收敛后所有「草底上无描边地表」共用（值避开 T_SAND/SNOW/TILE 5/6/7）
## 兼容旧引用名（chunk_manager / tests 曾用这两个）。
const CLIFF_RIM := CELL_CLIFF_RIM
const CLIFF_WALL := CELL_CLIFF_WALL

## 控制图 B 通道渲染角色（B*8）。「哪种贴图」已移到 mesh COLOR 层索引，此处只区分渲染角色，
## 供 shader 在描边区（G>0）选 rim 色：路(1) → path_rim，崖缘(3) → cliff_rim。其余不被读。
const ROLE_GRASS := 0
const ROLE_PATH := 1
const ROLE_WATER := 2
const ROLE_CLIFF_RIM := 3
const ROLE_CLIFF_WALL := 4
const ROLE_BODY := 5

## 过渡几何（px，cell 内容坐标系）：草边距 / 凸圆角半径 / 凹角半径 / 描边宽
const MARGIN := 3.0
const R_OUT := 24.0     ## 凸圆角近乎整个半 tile —— 动森式大圆角，斜向边界不出阶梯感
const R_IN := MARGIN    ## 凹角草圆必须 = MARGIN 才与相邻 cell 的直边草条连续（更大会出豁口）
const RIM := 3.0
const RIM_CLIFF := 5.0  ## 崖缘亮草包边宽度：比路描边宽一档，俯视时草皮垂沿可读（Pokopia 式）
const R_OUT_CLIFF := 10.0  ## 悬崖凸角用小圆角：大圆角会在崖角剥出一大片土唇
const R_OUT_WALL := 6.0    ## 崖壁棱角 bevel 更小：墙面转角只要一条窄棱
const FOAM_FULL := 4.0     ## 泡沫带：距岸线 ≤4px(~12cm) 全白
const FOAM_FADE := 10.0    ## 泡沫带：至 10px(~31cm) 渐隐到 0

## 调色板（供 TerrainTextures 组 shader 逐层 tint；Pokopia 感：黄绿亮草 + 暖沙崖壁 + 湖蓝）
const GRASS_TINT := Color(0.57, 0.80, 0.40)
const PATH_TINT := Color(0.91, 0.81, 0.58)
const PATH_RIM := Color(0.97, 0.92, 0.74)
const BED_TINT := Color(0.82, 0.74, 0.57)    ## 湖床沙底（透过水色看到）
const CLIFF_LIP_TINT := Color(0.83, 0.68, 0.46)   ## 崖顶沙唇（与崖壁同族、略深）
const CLIFF_RIM_GRASS := Color(0.63, 0.86, 0.42)  ## 崖缘亮草包边（比草地亮一档，Pokopia 式草皮垂沿）
const WALL_TINT := Color(0.80, 0.65, 0.44)   ## 崖壁暖沙
## 水面 shader 调色（water_surface.gdshader）
const WATER_SHALLOW := Color(0.42, 0.72, 0.88)
const WATER_DEEP := Color(0.13, 0.35, 0.62)
const WATER_FOAM := Color(0.92, 0.975, 1.0)

## 明暗纹样常量（A 通道，shader ×2 还原为乘数）
const LUM_GRASS_A := 1.0      ## 棋盘亮格
const LUM_GRASS_B := 0.965    ## 棋盘暗格
const LUM_GRASS_MID := 0.985  ## 过渡 cell 的草（介于棋盘两档之间，接缝不可见）

static var _tex: ImageTexture = null

static func texture() -> ImageTexture:
	if _tex == null:
		var img := build_image()
		img.generate_mipmaps()
		_tex = ImageTexture.create_from_image(img)
	return _tex

## (cell 种类, 角, 变体, 棋盘 parity) → atlas UV 矩形（cell 内容区，不含 gutter）。
## kind 取 CELL_*（CELL_GRASS/PATH/WATER/CLIFF_RIM/CLIFF_WALL/BODY）。
static func uv_rect(kind: int, corner: int, variant: int, parity: int) -> Rect2:
	var col: int
	var row: int
	if kind == CELL_GRASS:
		col = parity
		row = 0
	elif kind == CELL_PATH:
		col = variant
		row = 1 + corner
	elif kind == CELL_WATER:
		col = variant
		row = 5 + corner
	elif kind == CELL_CLIFF_RIM:
		col = variant
		row = 9 + corner
	elif kind == CELL_BODY:
		col = variant
		row = 17 + corner
	else:  # CELL_CLIFF_WALL 及兜底
		col = variant
		row = 13 + corner
	return Rect2(
		float(col * PITCH + GUTTER) / float(W),
		float(row * PITCH + GUTTER) / float(H),
		float(CELL) / float(W),
		float(CELL) / float(H))

## 生成整张控制图 Image（headless 可测，不碰 RenderingServer）。
static func build_image() -> Image:
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	_fill_cell(img, 0, 0, func(x: float, y: float) -> Color: return _grass_ctl(x, y, LUM_GRASS_A))
	_fill_cell(img, 1, 0, func(x: float, y: float) -> Color: return _grass_ctl(x, y, LUM_GRASS_B))
	for corner in range(4):
		for variant in range(Autotile.VARIANT_COUNT):
			_fill_cell(img, variant, 1 + corner, _transition_fn(corner, variant))
			_fill_cell(img, variant, 5 + corner, _water_fn(corner, variant))
			_fill_cell(img, variant, 9 + corner, _cliff_fn(corner, variant))
			_fill_cell(img, variant, 13 + corner, _wall_fn(corner, variant))
			_fill_cell(img, variant, 17 + corner, _body_fn(corner, variant))
	return img

## 逐像素填 cell；gutter 用 clamp 到内容区采样 = 边缘外扩。
static func _fill_cell(img: Image, col: int, row: int, px_fn: Callable) -> void:
	var ox := col * PITCH
	var oy := row * PITCH
	for py in range(PITCH):
		for px in range(PITCH):
			var cx := clampf(float(px - GUTTER) + 0.5, 0.5, CELL - 0.5)
			var cy := clampf(float(py - GUTTER) + 0.5, 0.5, CELL - 0.5)
			img.set_pixel(ox + px, oy + py, px_fn.call(cx, cy))

## 路过渡 cell：镜像到 NW 规范角（外缘 = x0/y0 两边），按变体算有符号距离 d
## （正 = 路域内），分 草 / 描边 / 路面 三段输出控制值。B 整 cell 恒为 ROLE_PATH。
static func _transition_fn(corner: int, variant: int) -> Callable:
	return func(x: float, y: float) -> Color:
		var cx := x if (corner == Autotile.C_NW or corner == Autotile.C_SW) else CELL - x
		var cy := y if (corner == Autotile.C_NW or corner == Autotile.C_NE) else CELL - y
		var d := _signed_dist(cx, cy, variant)
		var b := float(ROLE_PATH) / 8.0
		if d < 0.0:
			return _grass_ctl(x, y, LUM_GRASS_MID, b)
		if d < RIM:
			return Color(0.0, 1.0, b, 0.5)
		return Color(1.0, 0.0, b, _speckle_lum(x, y) * 0.5)

## body cell（沙/雪/瓷砖/所有主题地表共用）：几何同路过渡（草底上圆角 autotile），
## 但无描边（G=0）——地表与草的边界柔和过渡，不像路那样有亮边。B 恒为 ROLE_BODY。
## 真正「哪种地表贴图」由 mesh 顶点 COLOR 层索引决定（本 cell 与地表类型无关）。
static func _body_fn(corner: int, variant: int) -> Callable:
	return func(x: float, y: float) -> Color:
		var cx := x if (corner == Autotile.C_NW or corner == Autotile.C_SW) else CELL - x
		var cy := y if (corner == Autotile.C_NW or corner == Autotile.C_NE) else CELL - y
		var d := _signed_dist(cx, cy, variant)
		var b := float(ROLE_BODY) / 8.0
		if d < 0.0:
			return _grass_ctl(x, y, LUM_GRASS_MID, b)  # 草底（带 body 角色 B，线性过滤下恒定）
		return Color(1.0, 0.0, b, _speckle_lum(x, y) * 0.5)  # 地表主体，无描边

## 水 cell：R/B/A = 湖床主体（沙底斑点；地面只用 V_FULL cell，泡沫区不会上地）；
## G = 水面泡沫带——按旧水岸 autotile 几何（大圆角）在岸线两侧烘渐隐带，
## 水面 mesh 按角变体采样：宽水只有贴岸 cell 有带，窄溪也不会整条变白。
static func _water_fn(corner: int, variant: int) -> Callable:
	return func(x: float, y: float) -> Color:
		var cx := x if (corner == Autotile.C_NW or corner == Autotile.C_SW) else CELL - x
		var cy := y if (corner == Autotile.C_NW or corner == Autotile.C_NE) else CELL - y
		var d := _signed_dist(cx, cy, variant)
		var foam := 1.0 if d <= FOAM_FULL else clampf((FOAM_FADE - d) / (FOAM_FADE - FOAM_FULL), 0.0, 1.0)
		return Color(1.0, foam, float(ROLE_WATER) / 8.0, _speckle_lum(x, y) * 0.5)

## 悬崖边草皮 cell：域内 = 高地草面，域外（朝更低邻居一侧）= 崖唇土色，
## 边界带 = 深色草缘。几何与路过渡同构，凸角用小半径。B 恒为 ROLE_CLIFF_RIM。
static func _cliff_fn(corner: int, variant: int) -> Callable:
	return func(x: float, y: float) -> Color:
		var cx := x if (corner == Autotile.C_NW or corner == Autotile.C_SW) else CELL - x
		var cy := y if (corner == Autotile.C_NW or corner == Autotile.C_NE) else CELL - y
		var d := _signed_dist(cx, cy, variant, R_OUT_CLIFF)
		var b := float(ROLE_CLIFF_RIM) / 8.0
		if d < 0.0:
			return Color(1.0, 0.0, b, 0.5)  # 崖唇（沙色主体，平光）
		if d < RIM_CLIFF:
			return Color(0.0, 1.0, b, 0.5)  # 亮草包边（rim 色查表）
		return _grass_ctl(x, y, LUM_GRASS_MID, b)

## 崖壁 cell：域内 = 岩壁主体（地层带明暗），无邻墙一侧出凹缝暗边（d<0）
## + 亮棱线（边界带）——凹缝/棱线全走 A 明暗，不占 rim 色。B 恒为 ROLE_CLIFF_WALL。
static func _wall_fn(corner: int, variant: int) -> Callable:
	return func(x: float, y: float) -> Color:
		var cx := x if (corner == Autotile.C_NW or corner == Autotile.C_SW) else CELL - x
		var cy := y if (corner == Autotile.C_NW or corner == Autotile.C_NE) else CELL - y
		var d := _signed_dist(cx, cy, variant, R_OUT_WALL)
		var b := float(ROLE_CLIFF_WALL) / 8.0
		if d < 0.0:
			return Color(1.0, 0.0, b, 0.325)  # 凹缝阴影（~0.65×）
		if d < RIM:
			return Color(1.0, 0.0, b, 0.575)  # 亮棱线（~1.15×）
		return Color(1.0, 0.0, b, _wall_lum(x, y) * 0.5)

## NW 规范角坐标下，到域边界的有符号距离（正 = 在路/高地内）。
static func _signed_dist(cx: float, cy: float, variant: int, r_out := R_OUT) -> float:
	match variant:
		Autotile.V_FULL:
			return 1e9
		Autotile.V_EDGE_H:
			return cy - MARGIN      # 边界线水平，草在外缘 y 侧
		Autotile.V_EDGE_V:
			return cx - MARGIN
		Autotile.V_OUTER:
			var c := MARGIN + r_out # 凸圆角：圆心 (c,c)，两直边 + 四分之一圆
			if cx < c and cy < c:
				return r_out - Vector2(cx - c, cy - c).length()
			return minf(cx - MARGIN, cy - MARGIN)
		_:
			return Vector2(cx, cy).length() - R_IN  # V_INNER：外角点一小片草圆

## 草地控制值：动森式三角草纹（16px 方块内上/下三角交替，三角内微暗）+ 零星草尖亮点。
## body_b：过渡 cell 里草区也要带上整 cell 的角色 B，保证线性过滤下 B 恒定。
static func _grass_ctl(x: float, y: float, base_lum: float, body_b := 0.0) -> Color:
	var bx := fmod(x, 16.0)
	var by := fmod(y, 16.0)
	var up := posmod(int(x / 16.0) + int(y / 16.0), 2) == 0
	var ty := by if up else 16.0 - by
	var inside := (ty - 2.0) * 8.0 >= absf(bx - 8.0) * 12.0
	var lum := base_lum * 0.94 if inside else base_lum
	if _hash2(int(x), int(y)) % 29 == 0:
		lum = base_lum * 1.05  # 零星亮点（草尖）
	return Color(0.0, 0.0, body_b, lum * 0.5)

## 沙土斑点明暗（路面/湖床共用）。
static func _speckle_lum(x: float, y: float) -> float:
	var h := _hash2(int(x), int(y))
	if h % 17 == 0:
		return 0.92
	if h % 23 == 1:
		return 1.05
	return 1.0

## 崖壁主体明暗：沉积岩式宽层理（层带更宽、对比更柔，暖沙色下的 Pokopia 观感）+ 零星亮点。
static func _wall_lum(x: float, y: float) -> float:
	var band := fmod(y + sin(x * 0.4) * 1.5, 14.0) < 5.0
	var lum := 0.90 if band else 1.0
	if _hash2(int(x), int(y)) % 19 == 0:
		lum = 1.07
	return lum

static func _hash2(x: int, y: int) -> int:
	var h := x * 73856093 ^ y * 19349663
	h = (h ^ (h >> 13)) * 1274126177
	return absi(h ^ (h >> 16))
