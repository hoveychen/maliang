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
const LAYER_COUNT := 13

## shader 端 layer_tint[]/layer_mean[] 的固定数组长度（预留冗余，P3 加层不必改 shader）。
const SHADER_ARRAY_SIZE := 16

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
	return LAYER_CLIFF_WALL

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
