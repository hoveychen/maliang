class_name TerrainTextures
extends RefCounted
## 地形贴图层注册表（themed-terrain P1）。
## 把「哪种地形贴图」从 atlas 控制图里解耦出来：每种地形（顶面/侧壁各一）对应
## Texture2DArray 里的一个层索引，逐 tile 写进地面 mesh 顶点 COLOR.r（层/255），
## terrain_ground.gdshader 用它 texture(top_array, vec3(wuv, layer)) 按层采样。
## 加主题 = 往本表追加一层（+ 一张同尺寸贴图），atlas / mesh 逻辑零改动
## （atlas 的 autotile 几何已全地形共享，见 scripts/terrain_atlas.gd 收敛说明）。
##
## 层顺序即 Texture2DArray 的层索引，与 LAYER_* 常量、LAYER_TEX_PATHS 顺序三者必须一致。

# ── 层索引（= Texture2DArray 层序，也是 mesh COLOR.r*255 的取值）────────────────
const LAYER_GRASS := 0       ## 草地（万物基底：过渡 cell 的草区恒采此层）
const LAYER_PATH := 1        ## 路面（土）
const LAYER_BED := 2         ## 湖床（水下沙底；地面 mesh 的水 tile V_FULL cell 用）
const LAYER_CLIFF_LIP := 3   ## 崖唇（崖缘草皮外缘的土色）
const LAYER_CLIFF_WALL := 4  ## 崖壁（默认岩壁；抬高 tile 无专属侧壁时的兜底）
const LAYER_SAND := 5        ## 沙地（P0 审定水彩，tint 已烘入贴图）
const LAYER_SNOW := 6        ## 雪地（P0）
const LAYER_TILE := 7        ## 瓷砖地板（P0）
const LAYER_CORAL := 8       ## 礁岩（P0 coral.png；海底 P2 用作礁岩顶面/侧壁）
# ── 海底 P2 新增层（成品水彩，tint 已烘入贴图，故 tint/mean 传白）────────────────
const LAYER_COARSE_SAND := 9  ## 粗沙（coral_gravel 风格化）
const LAYER_CORAL_SAND := 10  ## 珊瑚砂（coral_mud_01 风格化，浅粉带珊瑚碎）
const LAYER_SEAGRASS := 11    ## 海草地（aerial_grass_rock 风格化，青绿）
const LAYER_DEEP_BED := 12    ## 深水床（brown_mud_leaves_01 风格化，暗青）
# ── 冰雪世界 P3 新增层（成品水彩，tint 已烘入贴图，故 tint/mean 传白）────────────────
const LAYER_PACKED_SNOW := 13 ## 压实雪（snow_03 风格化，冷灰白）
const LAYER_ICE := 14         ## 冰面（snow_02 风格化，浅青釉；结冰水共用）
const LAYER_SLUSH := 15       ## 雪泥/融雪（snow_03 风格化，脏灰）
const LAYER_ROCK_SNOW := 16   ## 裸岩积雪（rocks_ground_04 风格化，冷灰岩）
# ── 侏罗纪 P3 新增层（成品水彩，tint 已烘入贴图，故 tint/mean 传白）────────────────
const LAYER_CRACKED_EARTH := 17 ## 干裂土（brown_mud_dry 风格化，干黄棕；中国夯土/罗马斗兽场沙土共用）
const LAYER_VOLCANIC := 18      ## 火山岩（burned_ground_01 风格化，暗炭灰）
const LAYER_MUD_BOG := 19       ## 泥沼（brown_mud_02 风格化，暗褐）
const LAYER_FERN := 20          ## 蕨类草地（forrest_ground_03 风格化，苔绿）
const LAYER_RUBBLE := 21        ## 碎石（bicolour_gravel 风格化，灰砾；罗马碎石共用）
# ── 中世纪 P3 新增层（结构化，成品水彩，tint 已烘入→传白）────────────────────────
const LAYER_COBBLE := 22       ## 鹅卵石（cobblestone_05 风格化；中国卵石庭共用）
const LAYER_STONE_SLAB := 23   ## 石板（cobblestone_floor_04 风格化；中国青石板/罗马石板共用）
const LAYER_FARM_FURROW := 24  ## 农田垄（brown_mud_dry 风格化 + 程序化横垄）
# ── 罗马 P3 新增层（结构化，成品水彩，tint 已烘入→传白）──────────────────────────
const LAYER_MARBLE := 25       ## 大理石（marble_01 风格化，米白）
const LAYER_MOSAIC := 26       ## 马赛克地（marble_mosaic_tiles 风格化，暖陶格）
# ── 中国古代 P3 新增层（结构化，成品水彩，tint 已烘入→传白）──────────────────────
const LAYER_WOOD_FLOOR := 27   ## 木地板（wood_floor 风格化，暖木；玩具/厨房共用）
# ── 现代城市 P3 新增层（成品水彩/程序化，tint 已烘入→传白）────────────────────────
const LAYER_ASPHALT := 28      ## 沥青（asphalt_02 风格化，深灰）
const LAYER_PAVER_BRICK := 29  ## 人行道砖（brick_pavement_02 风格化，砖红）
const LAYER_CROSSWALK := 30    ## 斑马线（程序化，深灰底+白条）
const LAYER_CONCRETE := 31     ## 水泥（concrete_floor_01 风格化，浅灰；未来混凝土/医院手术室共用）
const LAYER_LAWN_GRID := 32    ## 草坪格（grass_concrete_pavement 风格化，草绿+格）
# ── 玩具房间 P3 新增层（程序化平色图案，tint 已含→传白）──────────────────────────
const LAYER_CARPET_RED := 33   ## 地毯红（程序化绒面）
const LAYER_CARPET_BLUE := 34  ## 地毯蓝（程序化绒面）
const LAYER_PUZZLE_MAT := 35   ## 拼图垫（程序化四色互扣泡沫方块）
# ── 厨房 P3 新增层 ──────────────────────────────────────────────────────────
const LAYER_CHECKER_TILE := 36 ## 格纹地砖（程序化黑白棋盘格）
const LAYER_ANTISLIP := 37     ## 防滑垫（anti_slip_concrete 风格化；医院防滑走廊共用）
# ── 医院 P3 新增层（程序化平色 PVC 地胶）────────────────────────────────────────
const LAYER_MED_VINYL_GREEN := 38 ## 医用地胶浅绿（程序化）
const LAYER_MED_VINYL_BLUE := 39  ## 医用地胶浅蓝（程序化）
# ── 未来机器人 P3 新增层 ─────────────────────────────────────────────────────
const LAYER_METAL_PLATE := 40  ## 金属板（metal_plate 风格化，冷银）
const LAYER_GRATING := 41      ## 格栅（metal_grate_rusty 风格化，暗金属）
const LAYER_GLOW_TILE := 42    ## 发光地砖（程序化青蓝发光格）
const LAYER_HAZARD := 43       ## 警戒条纹（程序化黄黑斜条）
# ── 室内房间墙面 P3（老板拍板「配专属墙面贴图搭房间」；toy_room 首个）────────────────
const LAYER_TOY_WALL := 44    ## 玩具房间墙面（程序化奶油底+柔彩圆点，托儿所壁纸；顶面+侧壁共用）
const LAYER_KITCHEN_WALL := 45  ## 厨房墙面（程序化白瓷砖+浅灰勾缝；顶面+侧壁共用）
const LAYER_HOSPITAL_WALL := 46 ## 医院墙面（程序化浅薄荷 plaster 近纯色；顶面+侧壁共用）
const LAYER_FUTURE_WALL := 47   ## 未来舱壁（程序化冷银金属+面板分块线；顶面+侧壁共用）
const LAYER_COUNT := 48

## shader 端 layer_tint[]/layer_mean[] 的固定数组长度（预留冗余，P3 加层不必改 shader）。
## P3（12 主题全铺）预计 40-50 层，故 16→64（老板 2026-07-12 定：最小改动，
## 单全局数组，接受老 Mali 全主题常驻的显存代价，留真机测试再优化——见 [[tablet-perf-investigation]]）。
## 与 shaders/terrain_ground.gdshader 的 layer_tint[N]/layer_mean[N] 必须同步。
const SHADER_ARRAY_SIZE := 64

## 层 → 贴图资源路径（下标 = 层索引，顺序敏感）。各层须同尺寸同格式（现全 1024² RGB）。
const LAYER_TEX_PATHS: Array[String] = [
	"res://assets/textures/watercolor/grass.png",  # 0 GRASS
	"res://assets/textures/watercolor/dirt.png",   # 1 PATH
	"res://assets/textures/watercolor/dirt.png",   # 2 BED
	"res://assets/textures/watercolor/dirt.png",   # 3 CLIFF_LIP
	"res://assets/textures/watercolor/stone.png",  # 4 CLIFF_WALL
	"res://assets/textures/terrain/sand.png",      # 5 SAND
	"res://assets/textures/terrain/snow.png",      # 6 SNOW
	"res://assets/textures/terrain/tile.png",      # 7 TILE
	"res://assets/textures/terrain/coral.png",     # 8 CORAL (礁岩)
	"res://assets/textures/terrain/coarse_sand.png", # 9 COARSE_SAND
	"res://assets/textures/terrain/coral_sand.png",  # 10 CORAL_SAND
	"res://assets/textures/terrain/seagrass.png",    # 11 SEAGRASS
	"res://assets/textures/terrain/deep_bed.png",    # 12 DEEP_BED
	"res://assets/textures/terrain/packed_snow.png", # 13 PACKED_SNOW
	"res://assets/textures/terrain/ice.png",         # 14 ICE
	"res://assets/textures/terrain/slush.png",       # 15 SLUSH
	"res://assets/textures/terrain/rock_snow.png",   # 16 ROCK_SNOW
	"res://assets/textures/terrain/cracked_earth.png", # 17 CRACKED_EARTH
	"res://assets/textures/terrain/volcanic.png",    # 18 VOLCANIC
	"res://assets/textures/terrain/mud_bog.png",     # 19 MUD_BOG
	"res://assets/textures/terrain/fern.png",        # 20 FERN
	"res://assets/textures/terrain/rubble.png",      # 21 RUBBLE
	"res://assets/textures/terrain/cobble.png",      # 22 COBBLE
	"res://assets/textures/terrain/stone_slab.png",  # 23 STONE_SLAB
	"res://assets/textures/terrain/farm_furrow.png", # 24 FARM_FURROW
	"res://assets/textures/terrain/marble.png",      # 25 MARBLE
	"res://assets/textures/terrain/mosaic.png",      # 26 MOSAIC
	"res://assets/textures/terrain/wood_floor.png",  # 27 WOOD_FLOOR
	"res://assets/textures/terrain/asphalt.png",     # 28 ASPHALT
	"res://assets/textures/terrain/paver_brick.png", # 29 PAVER_BRICK
	"res://assets/textures/terrain/crosswalk.png",   # 30 CROSSWALK
	"res://assets/textures/terrain/concrete.png",    # 31 CONCRETE
	"res://assets/textures/terrain/lawn_grid.png",   # 32 LAWN_GRID
	"res://assets/textures/terrain/carpet_red.png",  # 33 CARPET_RED
	"res://assets/textures/terrain/carpet_blue.png", # 34 CARPET_BLUE
	"res://assets/textures/terrain/puzzle_mat.png",  # 35 PUZZLE_MAT
	"res://assets/textures/terrain/checker_tile.png", # 36 CHECKER_TILE
	"res://assets/textures/terrain/antislip.png",    # 37 ANTISLIP
	"res://assets/textures/terrain/med_vinyl_green.png", # 38 MED_VINYL_GREEN
	"res://assets/textures/terrain/med_vinyl_blue.png",  # 39 MED_VINYL_BLUE
	"res://assets/textures/terrain/metal_plate.png", # 40 METAL_PLATE
	"res://assets/textures/terrain/grating.png",     # 41 GRATING
	"res://assets/textures/terrain/glow_tile.png",   # 42 GLOW_TILE
	"res://assets/textures/terrain/hazard.png",      # 43 HAZARD
	"res://assets/textures/terrain/toy_wall.png",    # 44 TOY_WALL
	"res://assets/textures/terrain/kitchen_wall.png",  # 45 KITCHEN_WALL
	"res://assets/textures/terrain/hospital_wall.png", # 46 HOSPITAL_WALL
	"res://assets/textures/terrain/future_wall.png",   # 47 FUTURE_WALL
]

const _WHITE := Color(1.0, 1.0, 1.0)

## 层 → 色调 tint（shader col = tint × tex/mean）。旧水彩层（草/土/石）沿用原调色板
## 复现既有观感；P0 审定层已把 tint 烘进贴图，故用白，不二次上色（避免双重上色）。
static func layer_tints() -> PackedColorArray:
	var t := PackedColorArray()
	t.resize(LAYER_COUNT)
	t[LAYER_GRASS] = TerrainAtlas.GRASS_TINT
	t[LAYER_PATH] = TerrainAtlas.PATH_TINT
	t[LAYER_BED] = TerrainAtlas.BED_TINT
	t[LAYER_CLIFF_LIP] = TerrainAtlas.CLIFF_LIP_TINT
	t[LAYER_CLIFF_WALL] = TerrainAtlas.WALL_TINT
	t[LAYER_SAND] = _WHITE
	t[LAYER_SNOW] = _WHITE
	t[LAYER_TILE] = _WHITE
	t[LAYER_CORAL] = _WHITE
	t[LAYER_COARSE_SAND] = _WHITE
	t[LAYER_CORAL_SAND] = _WHITE
	t[LAYER_SEAGRASS] = _WHITE
	t[LAYER_DEEP_BED] = _WHITE
	t[LAYER_PACKED_SNOW] = _WHITE
	t[LAYER_ICE] = _WHITE
	t[LAYER_SLUSH] = _WHITE
	t[LAYER_ROCK_SNOW] = _WHITE
	t[LAYER_CRACKED_EARTH] = _WHITE
	t[LAYER_VOLCANIC] = _WHITE
	t[LAYER_MUD_BOG] = _WHITE
	t[LAYER_FERN] = _WHITE
	t[LAYER_RUBBLE] = _WHITE
	t[LAYER_COBBLE] = _WHITE
	t[LAYER_STONE_SLAB] = _WHITE
	t[LAYER_FARM_FURROW] = _WHITE
	t[LAYER_MARBLE] = _WHITE
	t[LAYER_MOSAIC] = _WHITE
	t[LAYER_WOOD_FLOOR] = _WHITE
	t[LAYER_ASPHALT] = _WHITE
	t[LAYER_PAVER_BRICK] = _WHITE
	t[LAYER_CROSSWALK] = _WHITE
	t[LAYER_CONCRETE] = _WHITE
	t[LAYER_LAWN_GRID] = _WHITE
	t[LAYER_CARPET_RED] = _WHITE
	t[LAYER_CARPET_BLUE] = _WHITE
	t[LAYER_PUZZLE_MAT] = _WHITE
	t[LAYER_CHECKER_TILE] = _WHITE
	t[LAYER_ANTISLIP] = _WHITE
	t[LAYER_MED_VINYL_GREEN] = _WHITE
	t[LAYER_MED_VINYL_BLUE] = _WHITE
	t[LAYER_METAL_PLATE] = _WHITE
	t[LAYER_GRATING] = _WHITE
	t[LAYER_GLOW_TILE] = _WHITE
	t[LAYER_HAZARD] = _WHITE
	t[LAYER_TOY_WALL] = _WHITE
	t[LAYER_KITCHEN_WALL] = _WHITE
	t[LAYER_HOSPITAL_WALL] = _WHITE
	t[LAYER_FUTURE_WALL] = _WHITE
	return t

## 层 → 全图均值（tex/mean 归一：把偏暗的水彩包除到均值 1，只留笔触，色由 tint 定）。
## P0 审定层用白 = 不归一，直接保留成品色（配合 tint 白 = 贴图原样过 shader）。
static func layer_means() -> PackedColorArray:
	var dirt := Color(77.0 / 255.0, 48.0 / 255.0, 36.0 / 255.0)
	var m := PackedColorArray()
	m.resize(LAYER_COUNT)
	m[LAYER_GRASS] = Color(72.0 / 255.0, 92.0 / 255.0, 39.0 / 255.0)
	m[LAYER_PATH] = dirt
	m[LAYER_BED] = dirt
	m[LAYER_CLIFF_LIP] = dirt
	m[LAYER_CLIFF_WALL] = Color(91.0 / 255.0, 91.0 / 255.0, 97.0 / 255.0)
	m[LAYER_SAND] = _WHITE
	m[LAYER_SNOW] = _WHITE
	m[LAYER_TILE] = _WHITE
	m[LAYER_CORAL] = _WHITE
	m[LAYER_COARSE_SAND] = _WHITE
	m[LAYER_CORAL_SAND] = _WHITE
	m[LAYER_SEAGRASS] = _WHITE
	m[LAYER_DEEP_BED] = _WHITE
	m[LAYER_PACKED_SNOW] = _WHITE
	m[LAYER_ICE] = _WHITE
	m[LAYER_SLUSH] = _WHITE
	m[LAYER_ROCK_SNOW] = _WHITE
	m[LAYER_CRACKED_EARTH] = _WHITE
	m[LAYER_VOLCANIC] = _WHITE
	m[LAYER_MUD_BOG] = _WHITE
	m[LAYER_FERN] = _WHITE
	m[LAYER_RUBBLE] = _WHITE
	m[LAYER_COBBLE] = _WHITE
	m[LAYER_STONE_SLAB] = _WHITE
	m[LAYER_FARM_FURROW] = _WHITE
	m[LAYER_MARBLE] = _WHITE
	m[LAYER_MOSAIC] = _WHITE
	m[LAYER_WOOD_FLOOR] = _WHITE
	m[LAYER_ASPHALT] = _WHITE
	m[LAYER_PAVER_BRICK] = _WHITE
	m[LAYER_CROSSWALK] = _WHITE
	m[LAYER_CONCRETE] = _WHITE
	m[LAYER_LAWN_GRID] = _WHITE
	m[LAYER_CARPET_RED] = _WHITE
	m[LAYER_CARPET_BLUE] = _WHITE
	m[LAYER_PUZZLE_MAT] = _WHITE
	m[LAYER_CHECKER_TILE] = _WHITE
	m[LAYER_ANTISLIP] = _WHITE
	m[LAYER_MED_VINYL_GREEN] = _WHITE
	m[LAYER_MED_VINYL_BLUE] = _WHITE
	m[LAYER_METAL_PLATE] = _WHITE
	m[LAYER_GRATING] = _WHITE
	m[LAYER_GLOW_TILE] = _WHITE
	m[LAYER_HAZARD] = _WHITE
	m[LAYER_TOY_WALL] = _WHITE
	m[LAYER_KITCHEN_WALL] = _WHITE
	m[LAYER_HOSPITAL_WALL] = _WHITE
	m[LAYER_FUTURE_WALL] = _WHITE
	return m

## tile 类型（TerrainMap.T_*）→ 顶面贴图层索引。未知类型兜底草地。
static func top_layer(ttype: int) -> int:
	match ttype:
		TerrainMap.T_GRASS: return LAYER_GRASS
		TerrainMap.T_PATH: return LAYER_PATH
		TerrainMap.T_WATER: return LAYER_BED
		TerrainMap.T_SAND: return LAYER_SAND
		TerrainMap.T_SNOW: return LAYER_SNOW
		TerrainMap.T_TILE: return LAYER_TILE
		TerrainMap.T_COARSE_SAND: return LAYER_COARSE_SAND
		TerrainMap.T_CORAL_SAND: return LAYER_CORAL_SAND
		TerrainMap.T_REEF: return LAYER_CORAL
		TerrainMap.T_SEAGRASS: return LAYER_SEAGRASS
		TerrainMap.T_DEEP_BED: return LAYER_DEEP_BED
		TerrainMap.T_PACKED_SNOW: return LAYER_PACKED_SNOW
		TerrainMap.T_ICE: return LAYER_ICE
		TerrainMap.T_SLUSH: return LAYER_SLUSH
		TerrainMap.T_ROCK_SNOW: return LAYER_ROCK_SNOW
		TerrainMap.T_CRACKED_EARTH: return LAYER_CRACKED_EARTH
		TerrainMap.T_VOLCANIC: return LAYER_VOLCANIC
		TerrainMap.T_MUD_BOG: return LAYER_MUD_BOG
		TerrainMap.T_FERN: return LAYER_FERN
		TerrainMap.T_RUBBLE: return LAYER_RUBBLE
		TerrainMap.T_COBBLE: return LAYER_COBBLE
		TerrainMap.T_STONE_SLAB: return LAYER_STONE_SLAB
		TerrainMap.T_FARM_FURROW: return LAYER_FARM_FURROW
		TerrainMap.T_MARBLE: return LAYER_MARBLE
		TerrainMap.T_MOSAIC: return LAYER_MOSAIC
		TerrainMap.T_WOOD_FLOOR: return LAYER_WOOD_FLOOR
		TerrainMap.T_ASPHALT: return LAYER_ASPHALT
		TerrainMap.T_PAVER_BRICK: return LAYER_PAVER_BRICK
		TerrainMap.T_CROSSWALK: return LAYER_CROSSWALK
		TerrainMap.T_CONCRETE: return LAYER_CONCRETE
		TerrainMap.T_LAWN_GRID: return LAYER_LAWN_GRID
		TerrainMap.T_CARPET_RED: return LAYER_CARPET_RED
		TerrainMap.T_CARPET_BLUE: return LAYER_CARPET_BLUE
		TerrainMap.T_PUZZLE_MAT: return LAYER_PUZZLE_MAT
		TerrainMap.T_CHECKER_TILE: return LAYER_CHECKER_TILE
		TerrainMap.T_ANTISLIP: return LAYER_ANTISLIP
		TerrainMap.T_MED_VINYL_GREEN: return LAYER_MED_VINYL_GREEN
		TerrainMap.T_MED_VINYL_BLUE: return LAYER_MED_VINYL_BLUE
		TerrainMap.T_METAL_PLATE: return LAYER_METAL_PLATE
		TerrainMap.T_GRATING: return LAYER_GRATING
		TerrainMap.T_GLOW_TILE: return LAYER_GLOW_TILE
		TerrainMap.T_HAZARD: return LAYER_HAZARD
		TerrainMap.T_TOY_WALL: return LAYER_TOY_WALL
		TerrainMap.T_KITCHEN_WALL: return LAYER_KITCHEN_WALL
		TerrainMap.T_HOSPITAL_WALL: return LAYER_HOSPITAL_WALL
		TerrainMap.T_FUTURE_WALL: return LAYER_FUTURE_WALL
	return LAYER_GRASS

## tile 类型 → 侧壁（崖壁）贴图层索引：该 tile 被抬高时其竖直立面所采的层。
## 沙/雪/瓷砖有专属侧壁（同层顶面），草/路/水抬高走默认岩壁。
static func side_layer(ttype: int) -> int:
	match ttype:
		TerrainMap.T_SAND: return LAYER_SAND
		TerrainMap.T_SNOW: return LAYER_SNOW
		TerrainMap.T_TILE: return LAYER_TILE
		TerrainMap.T_COARSE_SAND: return LAYER_COARSE_SAND
		TerrainMap.T_CORAL_SAND: return LAYER_CORAL_SAND
		TerrainMap.T_REEF: return LAYER_CORAL
		TerrainMap.T_SEAGRASS: return LAYER_SEAGRASS
		TerrainMap.T_DEEP_BED: return LAYER_DEEP_BED
		TerrainMap.T_PACKED_SNOW: return LAYER_PACKED_SNOW
		TerrainMap.T_ICE: return LAYER_ICE
		TerrainMap.T_SLUSH: return LAYER_SLUSH
		TerrainMap.T_ROCK_SNOW: return LAYER_ROCK_SNOW
		TerrainMap.T_CRACKED_EARTH: return LAYER_CRACKED_EARTH
		TerrainMap.T_VOLCANIC: return LAYER_VOLCANIC
		TerrainMap.T_MUD_BOG: return LAYER_MUD_BOG
		TerrainMap.T_FERN: return LAYER_FERN
		TerrainMap.T_RUBBLE: return LAYER_RUBBLE
		TerrainMap.T_COBBLE: return LAYER_COBBLE
		TerrainMap.T_STONE_SLAB: return LAYER_STONE_SLAB
		TerrainMap.T_FARM_FURROW: return LAYER_FARM_FURROW
		TerrainMap.T_MARBLE: return LAYER_MARBLE
		TerrainMap.T_MOSAIC: return LAYER_MOSAIC
		TerrainMap.T_WOOD_FLOOR: return LAYER_WOOD_FLOOR
		TerrainMap.T_ASPHALT: return LAYER_ASPHALT
		TerrainMap.T_PAVER_BRICK: return LAYER_PAVER_BRICK
		TerrainMap.T_CROSSWALK: return LAYER_CROSSWALK
		TerrainMap.T_CONCRETE: return LAYER_CONCRETE
		TerrainMap.T_LAWN_GRID: return LAYER_LAWN_GRID
		TerrainMap.T_CARPET_RED: return LAYER_CARPET_RED
		TerrainMap.T_CARPET_BLUE: return LAYER_CARPET_BLUE
		TerrainMap.T_PUZZLE_MAT: return LAYER_PUZZLE_MAT
		TerrainMap.T_CHECKER_TILE: return LAYER_CHECKER_TILE
		TerrainMap.T_ANTISLIP: return LAYER_ANTISLIP
		TerrainMap.T_MED_VINYL_GREEN: return LAYER_MED_VINYL_GREEN
		TerrainMap.T_MED_VINYL_BLUE: return LAYER_MED_VINYL_BLUE
		TerrainMap.T_METAL_PLATE: return LAYER_METAL_PLATE
		TerrainMap.T_GRATING: return LAYER_GRATING
		TerrainMap.T_GLOW_TILE: return LAYER_GLOW_TILE
		TerrainMap.T_HAZARD: return LAYER_HAZARD
		TerrainMap.T_TOY_WALL: return LAYER_TOY_WALL
		TerrainMap.T_KITCHEN_WALL: return LAYER_KITCHEN_WALL
		TerrainMap.T_HOSPITAL_WALL: return LAYER_HOSPITAL_WALL
		TerrainMap.T_FUTURE_WALL: return LAYER_FUTURE_WALL
	return LAYER_CLIFF_WALL

## 层 → 崖壁纵向明暗浮雕强度（shader wall_relief[]，只作用于崖壁 role）。
## 默认 0 = 平铺（沿用老板已验收的干净墙面，室外岩壁/室内光滑墙零回归）；
## 雪族满档出「崖顶积雪高光→崖基入影」的雪崖感，破老板反馈的「白方糖硬方块」。
## 冰面略低（冰本就通透少积雪），雪泥/裸岩积雪/雪原/压实雪拉满。加主题默认继承 0，需要时再点名。
static func layer_wall_reliefs() -> PackedFloat32Array:
	var r := PackedFloat32Array()
	r.resize(SHADER_ARRAY_SIZE)
	r[LAYER_SNOW] = 1.0
	r[LAYER_PACKED_SNOW] = 1.0
	r[LAYER_SLUSH] = 0.9
	r[LAYER_ROCK_SNOW] = 1.0
	r[LAYER_ICE] = 0.85
	return r

## tile 类型 → 崖壁顶缘几何倒角量（米，0 = 直角盒不倒角）。
## 老板 GPU 反馈：冰雪崖壁要「边缘圆润平滑」——明暗浮雕(layer_wall_reliefs)近似受光后，
## 再对崖顶棱线做真几何倒角(45° chamfer)把硬直角切软。逐 tile 类型开关(非全主题一刀切)：
## 雪族崖壁倒角出雪盖圆润感，室外岩壁/室内光滑墙/现代路缘等默认 0=保持利落直角(零回归)。
## 地形网格无碰撞体(角色高度走逻辑格 tile_height×STEP)，倒角纯视觉、不影响行走/寻路。
const BEVEL_SNOW := 0.22
## 有机地表崖顶软圆角（Pokopia 化 P5）：草/沙/土/苔类台地顶棱也吃 fillet——
## Pokopia 全场景找不到一条锋利 90° 边（设计文档§2）。比雪盖轻一档；
## 结构地面（瓷砖/石板/现代路缘等）保持利落直角不动。
const BEVEL_SOFT := 0.12
static func tile_bevel(ttype: int) -> float:
	match ttype:
		TerrainMap.T_SNOW, TerrainMap.T_PACKED_SNOW, \
		TerrainMap.T_SLUSH, TerrainMap.T_ROCK_SNOW:
			return BEVEL_SNOW
		TerrainMap.T_ICE:
			return BEVEL_SNOW * 0.6  ## 冰面积雪少，倒角轻一点
		TerrainMap.T_GRASS, TerrainMap.T_PATH, TerrainMap.T_SAND, \
		TerrainMap.T_COARSE_SAND, TerrainMap.T_CORAL_SAND, TerrainMap.T_REEF, \
		TerrainMap.T_SEAGRASS, TerrainMap.T_DEEP_BED, TerrainMap.T_CRACKED_EARTH, \
		TerrainMap.T_VOLCANIC, TerrainMap.T_MUD_BOG, TerrainMap.T_FERN:
			return BEVEL_SOFT
	return 0.0

## PackedColorArray → shader vec3[] 用的线性 PackedVector3Array（补齐到 SHADER_ARRAY_SIZE）。
## 手动 sRGB→线性：shader 侧 uniform 不带 source_color（数组 uniform 的 source_color 支持
## 各版本不一），与 source_color 采样的贴图在线性空间一致（复现旧 : source_color 语义）。
static func _to_linear_padded(cols: PackedColorArray) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(SHADER_ARRAY_SIZE)
	for i in range(cols.size()):
		var lc := cols[i].srgb_to_linear()
		out[i] = Vector3(lc.r, lc.g, lc.b)
	return out

static func layer_tints_linear() -> PackedVector3Array:
	return _to_linear_padded(layer_tints())

static func layer_means_linear() -> PackedVector3Array:
	return _to_linear_padded(layer_means())

## 层 → 平色（Pokopia 化 P2）：该层贴图经 shader 上色后呈现色的空间均值（线性空间），
## = tint × img_mean / mean（旧水彩层 img_mean≈mean → 平色≈tint；烘色层 tint/mean 白 →
## 平色=贴图均值，一条公式两类层通吃）。flatten 旋钮把 body 往这个平色收敛：远看干净
## 色块、近看只留少量笔触。low_detail 档的纯色 body 也用它（layer_tint 对烘色层是白，
## 直接当纯色会把地面洗白）。
static var _layer_flats := PackedVector3Array()

## 层 → 盖帽门控（Pokopia 化 P4）：该层作为「被抬高 tile 的顶面」时，崖壁顶缘要不要画
## 波浪盖帽。有机地表（草/沙/雪/苔/泥…）= 1，结构地面（木地板/大理石/瓷砖/沥青/地毯…）= 0
## ——波浪毛边帽在人造地面上违和。缺省 0，只登记有机层。
static func layer_cap_trims() -> PackedFloat32Array:
	var c := PackedFloat32Array()
	c.resize(SHADER_ARRAY_SIZE)
	c[LAYER_GRASS] = 1.0
	c[LAYER_PATH] = 0.6       # 土顶：薄土唇
	c[LAYER_BED] = 0.6
	c[LAYER_SAND] = 1.0
	c[LAYER_SNOW] = 1.0
	c[LAYER_CORAL] = 1.0
	c[LAYER_COARSE_SAND] = 1.0
	c[LAYER_CORAL_SAND] = 1.0
	c[LAYER_SEAGRASS] = 1.0
	c[LAYER_DEEP_BED] = 1.0
	c[LAYER_PACKED_SNOW] = 1.0
	c[LAYER_ICE] = 0.4        # 冰沿只留淡淡一圈
	c[LAYER_SLUSH] = 1.0
	c[LAYER_ROCK_SNOW] = 1.0
	c[LAYER_CRACKED_EARTH] = 1.0
	c[LAYER_VOLCANIC] = 0.8
	c[LAYER_MUD_BOG] = 1.0
	c[LAYER_FERN] = 1.0
	c[LAYER_RUBBLE] = 0.6
	c[LAYER_FARM_FURROW] = 1.0
	c[LAYER_LAWN_GRID] = 1.0
	return c

static func layer_flats_linear() -> PackedVector3Array:
	if _layer_flats.is_empty():
		_compute_layer_flats()
	return _layer_flats

## 逐层算贴图均值：sRGB→线性后对半缩到 1×1（逐级 box 均值，全程 C++ 路径，启动一次性）。
static func _compute_layer_flats() -> void:
	var tints := layer_tints_linear()
	var means := layer_means_linear()
	_layer_flats.resize(SHADER_ARRAY_SIZE)
	for i in range(LAYER_TEX_PATHS.size()):
		var tex: Texture2D = load(LAYER_TEX_PATHS[i])
		var img: Image = tex.get_image() if tex != null else null
		if img == null:
			_layer_flats[i] = tints[i]
			continue
		if img.is_compressed():
			img.decompress()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		img.srgb_to_linear()
		while img.get_width() > 1 or img.get_height() > 1:
			img.resize(maxi(1, img.get_width() >> 1), maxi(1, img.get_height() >> 1), Image.INTERPOLATE_BILINEAR)
		var c := img.get_pixel(0, 0)
		_layer_flats[i] = Vector3(
			tints[i].x * c.r / maxf(means[i].x, 0.001),
			tints[i].y * c.g / maxf(means[i].y, 0.001),
			tints[i].z * c.b / maxf(means[i].z, 0.001))

## 组装顶面/侧壁共用的 Texture2DArray（各层同尺寸同格式）。运行期一次性建，材质共享。
## headless 下也可安全构造（Image 解码 + create_from_images 不依赖窗口/GPU 上传）。
static func build_texture_array() -> Texture2DArray:
	var imgs: Array[Image] = []
	for path in LAYER_TEX_PATHS:
		var tex: Texture2D = load(path)
		var img := tex.get_image()
		if img == null:
			push_error("TerrainTextures: 层贴图无 Image：%s" % path)
			continue
		if img.is_compressed():
			img.decompress()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		img.generate_mipmaps()
		imgs.append(img)
	var arr := Texture2DArray.new()
	arr.create_from_images(imgs)
	return arr
