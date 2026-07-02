class_name TerrainAtlas
extends RefCounted
## 运行时程序生成的地形 atlas（延续 grass_tile.png 的"手绘三角草纹"思路，
## 但不再落二进制资产）。颜色全部烘焙进纹理，地面材质 albedo 用纯白。
##
## 布局：5 列（Autotile 变体）× 9 行，cell 内容 32px + 四周 4px 边缘外扩 gutter
## （防 mipmap/双线性跨 cell 渗色），行分配：
##   row 0        草地（col 0/1 = 棋盘 parity 两种色深，与变体无关）
##   row 1..4     路  （行 = Autotile 角 NW/NE/SW/SE，列 = 变体）
##   row 5..8     水  （同上）
## 过渡 cell 统一按 NW 角绘制再镜像；grass 背景用中间色深（棋盘对比极低，接缝不可见）。

const CELL := 32          ## cell 内容像素（半 tile = 1m → 32px/m）
const GUTTER := 4
const PITCH := CELL + GUTTER * 2
const COLS := 5           ## Autotile.VARIANT_COUNT
const ROWS := 9
const W := COLS * PITCH   ## 200
const H := ROWS * PITCH   ## 360

## 过渡几何（px，cell 内容坐标系）：草边距 / 凸圆角半径 / 凹角半径 / 描边宽
const MARGIN := 3.0
const R_OUT := 10.0
const R_IN := 6.0
const RIM := 3.0

## 调色板（烘焙色；动森感：亮草绿 + 沙土路 + 湖蓝）
const GRASS_A := Color(0.545, 0.78, 0.47)
const GRASS_B := Color(0.52, 0.755, 0.44)
const GRASS_MID := Color(0.532, 0.768, 0.455)
const PATH_BODY := Color(0.87, 0.77, 0.55)
const PATH_RIM := Color(0.95, 0.885, 0.68)
const WATER_BODY := Color(0.36, 0.63, 0.86)
const WATER_RIM := Color(0.92, 0.975, 1.0)

static var _tex: ImageTexture = null

static func texture() -> ImageTexture:
	if _tex == null:
		var img := build_image()
		img.generate_mipmaps()
		_tex = ImageTexture.create_from_image(img)
	return _tex

## (类型, 角, 变体, 棋盘 parity) → atlas UV 矩形（cell 内容区，不含 gutter）。
static func uv_rect(type: int, corner: int, variant: int, parity: int) -> Rect2:
	var col: int
	var row: int
	if type == TerrainMap.T_GRASS:
		col = parity
		row = 0
	elif type == TerrainMap.T_PATH:
		col = variant
		row = 1 + corner
	else:
		col = variant
		row = 5 + corner
	return Rect2(
		float(col * PITCH + GUTTER) / float(W),
		float(row * PITCH + GUTTER) / float(H),
		float(CELL) / float(W),
		float(CELL) / float(H))

## 生成整张 atlas Image（headless 可测，不碰 RenderingServer）。
static func build_image() -> Image:
	var img := Image.create(W, H, false, Image.FORMAT_RGB8)
	_fill_cell(img, 0, 0, func(x: float, y: float) -> Color: return _grass_px(x, y, GRASS_A))
	_fill_cell(img, 1, 0, func(x: float, y: float) -> Color: return _grass_px(x, y, GRASS_B))
	for corner in range(4):
		for variant in range(Autotile.VARIANT_COUNT):
			_fill_cell(img, variant, 1 + corner, _transition_fn(corner, variant, false))
			_fill_cell(img, variant, 5 + corner, _transition_fn(corner, variant, true))
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

## 过渡 cell 像素函数：镜像到 NW 规范角（外缘 = x0/y0 两边），
## 按变体算到路/水边界的有符号距离 d（正 = 域内），再分 草/描边/主体 三段上色。
static func _transition_fn(corner: int, variant: int, water: bool) -> Callable:
	return func(x: float, y: float) -> Color:
		var cx := x if (corner == Autotile.C_NW or corner == Autotile.C_SW) else CELL - x
		var cy := y if (corner == Autotile.C_NW or corner == Autotile.C_NE) else CELL - y
		var d := _signed_dist(cx, cy, variant)
		if d < 0.0:
			return _grass_px(x, y, GRASS_MID)
		if d < RIM:
			return WATER_RIM if water else PATH_RIM
		return _water_px(x, y) if water else _path_px(x, y)

## NW 规范角坐标下，到域边界的有符号距离（正 = 在路/水内）。
static func _signed_dist(cx: float, cy: float, variant: int) -> float:
	match variant:
		Autotile.V_FULL:
			return 1e9
		Autotile.V_EDGE_H:
			return cy - MARGIN      # 边界线水平，草在外缘 y 侧
		Autotile.V_EDGE_V:
			return cx - MARGIN
		Autotile.V_OUTER:
			var c := MARGIN + R_OUT # 凸圆角：圆心 (c,c)，两直边 + 四分之一圆
			if cx < c and cy < c:
				return R_OUT - Vector2(cx - c, cy - c).length()
			return minf(cx - MARGIN, cy - MARGIN)
		_:
			return Vector2(cx, cy).length() - R_IN  # V_INNER：外角点一小片草圆

static func _grass_px(x: float, y: float, base: Color) -> Color:
	# 动森式三角草纹：16px 方块内上/下三角交替，三角内微暗
	var bx := fmod(x, 16.0)
	var by := fmod(y, 16.0)
	var up := posmod(int(x / 16.0) + int(y / 16.0), 2) == 0
	var ty := by if up else 16.0 - by
	var inside := (ty - 2.0) * 8.0 >= absf(bx - 8.0) * 12.0
	var c := base * 0.94 if inside else base
	if _hash2(int(x), int(y)) % 29 == 0:
		c = base * 1.05  # 零星亮点（草尖）
	return c

static func _path_px(x: float, y: float) -> Color:
	var h := _hash2(int(x), int(y))
	if h % 17 == 0:
		return PATH_BODY * 0.92  # 沙土斑点
	if h % 23 == 1:
		return PATH_BODY * 1.05
	return PATH_BODY

static func _water_px(x: float, y: float) -> Color:
	# 横向波纹：每 8px 一道微亮行 + 零星亮点
	var wave := fmod(y + sin(x * 0.6) * 1.5, 8.0) < 1.2
	var c := WATER_BODY * 1.08 if wave else WATER_BODY
	if _hash2(int(x), int(y)) % 37 == 0:
		c = WATER_BODY * 1.18
	return c

static func _hash2(x: int, y: int) -> int:
	var h := x * 73856093 ^ y * 19349663
	h = (h ^ (h >> 13)) * 1274126177
	return absi(h ^ (h >> 16))
