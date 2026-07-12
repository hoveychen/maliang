# themed-terrain P1 实现计划（渲染架构改造）

> 状态：P0 已完成并 merge 前置（画风审定 ①卡通光滑 / 12 主题全铺，见 commit 13d4ec3）。
> 本文是 P1 的实现蓝图——架构已测绘、方案已选定，供实现会话直接落地，无需重新推导。
> 一句话：把地形渲染从「3 张细节贴图 + tint 复用 + B 通道 ÷8（8 档上限）」升级为
> 「per-tile 层索引（顶点属性）→ sampler2DArray，支持 N 种地形 × 顶面+侧壁 + 共享 autotile 几何」。

## 现状（已核实 file:line，均主 checkout）

- **shader** `shaders/terrain_ground.gdshader`：control_tex atlas（R=主体域 mask / G=描边 rim /
  B=`round(ctl.b*8)` 类型（8 档硬顶）/ A=明暗×0.5）；UV→atlas cell，UV2→世界米做细节平铺。
  只 preload grass/dirt/stone 三张细节图（:12-14），body type 1-7 靠 tint（:18-28）+ 复用
  dirt/stone 细节（:53-56 use_stone 分支）。沙(5)/雪(6)/瓷砖(7) 全塞在这 8 档里，无独立贴图。
- **atlas** `scripts/terrain_atlas.gd`（`class_name TerrainAtlas`，纯静态，headless 可测）：
  CELL=32 + GUTTER=4 → PITCH=40；COLS=5(=autotile 变体数)，ROWS=29。
  行分配：row0 草 / 1-4 路 / 5-8 水 / 9-12 崖唇 / 13-16 崖壁 / 17-20 沙 / 21-24 雪 / 25-28 瓷砖
  （`BODY_ROWS` :31）。每地表占 4 行(NW/NE/SW/SE 四角)×5 列(变体)。
  几何来自 `_signed_dist`（:203-217，FULL/EDGE_H/EDGE_V/OUTER 圆角/INNER 凹角），`_body_fn`
  （:153）克隆路的过渡几何、只换 B=`type/8`、去描边。`uv_rect(type,corner,variant,parity)`
  （:83-108）选 cell。`build_image()`（:111）四重循环烘制，`_fill_cell`（:127）clamp 填 gutter。
- **类型数据流**：服务端 u8 types 平面 → 客户端 `terrain_map.gd` `_types`（`tile_type(t)` :251）→
  `chunk_manager.gd` `_chunk_mesh()`（:408-460）每 tile 取 ttype、选 atlas cell 拿 UV。
  **类型不走顶点属性/uniform，纯靠"选哪个 atlas cell"传给 shader。**
- **崖壁** `chunk_manager.gd` `_emit_walls()`（:565-618）：逐边逐级发 2m 墙格 + 4 个 1m 角 quad；
  **:599 写死 `TerrainAtlas.CLIFF_WALL`(=4)，完全不看被抬高 tile 的类型**（这是"偷懒"）。
  UV=atlas 崖壁 cell，UV2=(沿墙逻辑坐标, 世界 y)。`_emit_walls` 当前签名(:565)只有 `fl` 没 `ttype`。
  `STEP_HEIGHT=2.0`（terrain_map.gd:38）；台阶级 `tile_floor_level()`（terrain_map.gd:294-295）。
- **材质装配**：`chunk_manager.gd` `_make_ground_mat()`（:173-194，static），懒建、9 区块共享
  `_ground_mat`（:70）。control_tex=`TerrainAtlas.texture()`；grass/dirt/stone_tex 来自 :40-42
  **硬编码 preload** `res://assets/textures/watercolor/*.png`——**不走 PackRegistry**（唯一装配点）。
- **白名单**：客户端 `terrain_map.gd` `T_SAND=5/T_SNOW=6/T_TILE=7`(:30-32)、`VALID_TYPES`(:34)、
  `BODY_TYPES`(:36)；服务端 `terrain.ts` `VALID_TILE_TYPES`(:59)。两端一致。u8 支持 0-255，
  **序列化格式无需改版**。
- **测试**：`test/test_terrain_atlas.gd`（:61-84 已覆盖 sand/snow/tile 的 B 对齐/uv_rect 落图内）、
  `test/test_terrain_rebuild.gd`（mesh 构建+缓存契约）、`test/test_terrain_map/v2/load/export/patch.gd`
  （数据层）。改 atlas 布局/mesh 顶点属性必同步。

## 选定方案：顶点属性层索引 + sampler2DArray + 收敛 atlas

**为什么不继续挤 B 通道**：`round(ctl.b*8)` 硬顶 8 档；且 B 同时承载"选 atlas cell"职责，
再塞层索引会耦合；linear filter 在 cell 边界会插值污染索引（现靠"每 cell 单类型 + gutter +
repeat_disable"三重规避，只在"整 cell 恒定"时安全，无法在单 cell 内平滑选层）。12 主题 ×5-8 =
60-100 种远超 8 档。

**方案三支柱**：
1. **层索引走顶点属性**：地面 mesh 目前不带 `ARRAY_COLOR`（水面才带，存深度 :517）。给地面 quad
   四顶点写入相同的层索引（顶面层、侧面层可打包进 COLOR 的两个分量，如 R=顶面层/255、G=侧面层/255）。
   同一 quad 四顶点索引相同 → 无插值问题；跨 quad 由逐 quad 恒定保证。**这是绕开 8 档 + linear
   风险的核心。**
2. **sampler2DArray 顶面+侧壁纹理数组**：shader 的 grass/dirt/stone_tex → `sampler2DArray
   top_array` + `side_array`，`texture(top_array, vec3(wuv, top_layer))` 按层采。
   `_make_ground_mat()` 组一个 `Texture2DArray`（Godot: `Texture2DArray.create_from_images` 或
   `.godot` 导入 .png 序列为 Texture2DArray），层顺序 = 一张"地形→层索引"注册表。
3. **atlas 收敛为渲染角色**：autotile 几何（SDF 边缘/角/变体）**所有地形共享**——不再每种地表烘一组
   4×5 行。atlas B 通道退化为只区分渲染角色（草底/body/描边/崖壁，≤8 足够）；atlas 行数从 29
   收敛回 ~17（草/路/水/崖唇/崖壁）。真正"哪种地表贴图"全交给顶点层索引。**这大幅缩小 atlas 且让
   加主题零 atlas 改动**（P3 加主题只往纹理数组加层 + 注册表加行）。

## 改动清单（按依赖序，每步尽量保持可 build/green）

> 建议实现顺序：先做"绿保持的地基重构"（层索引复现现有选择、输出不变、旧测试仍绿），
> 再逐步把真实 per-terrain 贴图接上。避免一次性半途留坏树。

1. **地形→层索引注册表**（新文件，如 `scripts/terrain_textures.gd` 或塞进 terrain_map.gd 常量）：
   `{T_GRASS: {top:0, side:?}, T_PATH:{...}, T_SAND:{top,side}, ...}`。顶面/侧壁各一层索引。
   侧壁：可抬高地形各配侧壁层；纯室内平地（地毯/地胶，P3）共用一中性踢脚层。
2. **纹理数组构建** `chunk_manager.gd:_make_ground_mat()`（:173-194）：
   把 :40-42 的多张 preload 换成组 `Texture2DArray`（顶面数组 + 侧壁数组），uniform 传 shader。
   P1 阶段先用现有 7 张（grass/dirt/stone + P0 审定的 sand/snow/coral/tile，
   在 `docs/terrain-style-samples/`，正式入库时移到 `assets/textures/terrain/`）验证；
   缺的层先用占位。**注意**：Texture2DArray 要求各层同尺寸同格式。
3. **shader** `terrain_ground.gdshader`：
   - uniform（:12-28）：grass/dirt/stone_tex → `sampler2DArray top_array, side_array`；tint/mean
     可保留为小数组或按层烘进贴图（P0 已把 tint 烘进纹理，故 shader 端 tint 可大幅简化甚至去掉）。
   - vertex：从 `COLOR` 解出 top_layer/side_layer，`varying flat float` 传 fragment。
   - fragment（:45-60）：`texture(top_array, vec3(wuv, top_layer))`；崖壁 quad 用 side_layer 采
     `side_array`。body_tint/use_stone 分支（:51-56）删除或改按层。ctl.r/g/a 的域/描边/明暗逻辑保留。
   - ⚠️ P0 纹理已是成品水彩观感（tint 已烘入），shader 不应再叠 tint，否则双重上色。
4. **mesh 顶点属性** `chunk_manager.gd`：
   - `_chunk_mesh()`（:408-460）：每 tile 查注册表得 top_layer，写进 quad 四顶点 COLOR。
   - `_emit_quad()`（:541）：签名 + 传 COLOR/层索引。SurfaceTool 需 `set_color` 前 `set_uv/uv2`。
   - `_emit_walls()`（:565-618）：**签名加 `ttype`**（调用点 :449 传 `tile_type(t)`）；
     :599 的 `CLIFF_WALL` → 由 ttype 查注册表得 side_layer，写进墙 quad 顶点 COLOR。**这修"偷懒"。**
   - Mesh 的 ARRAY_FORMAT 要含 `ARRAY_COLOR`；确认 `_ground_mat` 的 vertex_color_use_as_albedo
     关掉（否则 COLOR 被当反照率）。
5. **白名单**（P1 只验证现有类型可不动；P2/P3 加海底类型时扩）：
   `terrain_map.gd:34/36` + `terrain.ts:59` 两端同步加新 tile 类型码。
6. **测试**：
   - `test/test_terrain_atlas.gd`（:61-84）：atlas 收敛后 sand/snow/tile 行没了，断言改为渲染角色语义。
   - `test/test_terrain_rebuild.gd`：mesh 新增 COLOR 通道，验证 ARRAY_FORMAT + 层索引正确。
   - 新增断言：per-tile 顶面层索引正确、崖壁按 raised tile 类型取 side_layer。
   - 运行器 `scripts/test-headless.sh`（Godot 4.6.3 official，/Applications/Godot.app）。
     worktree 已软链 ASR framework（否则 Godot 加载崩 exit134）。

## P1 验收（设计 §5）

以**海底**为验证主题：架构改造完成后，能用现有/占位贴图渲染出「顶面按 tile 类型取不同贴图 +
崖壁按被抬高 tile 类型取对应侧壁」的效果，headless 测试全绿。真实海底全套 tile + 场景是 P2。

## 风险 / 注意

- Texture2DArray 各层必须同尺寸同格式（P0 输出统一 1024×1024 RGB，OK）。
- COLOR 顶点属性打包层索引：用整数层数 ≤255 时 `float(layer)/255.0` 存、shader `round(c*255)` 解；
  `flat` varying 避免插值。
- 老 Mali GPU 性能（memory「平板卡顿排查」）：sampler2DArray 采样成本 ≈ 单 sampler2D，层数不增
  每像素采样次数（仍是顶面 1 次 + 崖壁 1 次），比现在的 tint+detail 双采样可能更省。仍需真机验。
- P0 tint 已烘入纹理——shader 去 tint，避免双重上色（见步骤 3 ⚠️）。

## P1 实现记录（已落地，headless 全绿；对蓝图的两处简化）

已合入 `prd/themed-terrain`，本节记录与上文蓝图的偏差，供 P2 直接接手。

- **单数组，非双数组**：蓝图设想 `top_array` + `side_array` 两个 Texture2DArray。实测发现
  「每 quad 只需一个层索引」——顶面 quad 写 tile 顶面层、崖壁 quad 写被抬高 tile 的侧壁层——
  故合并为**一个** `top_array`（含 grass/path/bed/lip/wall/sand/snow/tile/coral 共 9 层），
  层索引写进 mesh 顶点 **COLOR.r**（`layer/255`，`flat` varying 解）。侧壁只是「取哪个层」不同，
  不需要独立数组。加主题 = `TerrainTextures.LAYER_TEX_PATHS` 追加一层 + 建表加一行。
- **逐层 tint/mean 数组桥接，非彻底去 tint**：旧 grass/dirt/stone 是未烘 tint 的水彩包，
  P0 审定的 sand/snow/coral/tile 已烘 tint。为「绿保持」不改旧观感，shader 保留
  `uniform vec3 layer_tint[16] / layer_mean[16]`（`TerrainTextures.layer_tints/means`，手动
  sRGB→线性传入）：旧层用原调色板 tint+实测 mean 复现，P0 审定层用**白 tint + 白 mean**
  （= 贴图原样过 shader，不二次上色）。**P2/P3 若把旧层也烘成成品贴图，可把对应 tint/mean 改白，
  最终收敛到「纯贴图无 tint」**。
- **atlas 收敛 29→21 行**：sand/snow/tile 各自 4 行删除，合并为一组 `CELL_BODY`（无描边 body，
  4 行 17–20）。B 通道从「地形类型」改为「渲染角色」`ROLE_*`（仅 shader 在描边区选 rim 色用）。
  `uv_rect` 第一参数改为 cell 种类 `CELL_*`（`CELL_GRASS/PATH/WATER/CLIFF_RIM/CLIFF_WALL/BODY`；
  `CLIFF_RIM/CLIFF_WALL` 留了旧名别名）。
- **崖壁修偷懒**：`_emit_walls` 加 `ttype` 参数，侧壁层 = `TerrainTextures.side_layer(ttype)`
  （沙/雪/瓷砖有专属侧壁，草/路/水走默认岩壁），不再写死 `CLIFF_WALL`。
- **资产入库**：P0 四张审定贴图从 `docs/terrain-style-samples/` 复制到 `assets/textures/terrain/`
  作运行期层来源（docs 版留作审定证据）。
- **验收**：`test_terrain_layers.gd`（新增）构造「草地里立一块抬高 sand tile + 一块平瓷砖」，
  断言顶面按类型取层、崖壁按被抬高 tile 取侧壁层；`test_terrain_atlas` 改断言渲染角色语义；
  `test_visual_water` 改检 `top_array`。全套 `scripts/test-headless.sh` 全绿（exit 0）。
- **未验**：shader 仅 headless 语法级通过（dummy renderer 不做 GPU 编译）；真机水彩观感 + 老 Mali
  `sampler2DArray`/`flat int` varying/动态数组下标性能**未在真机验证**——留 P2 真机 + 老板过目。
- **P2 起点**：填「哪种海底 tile → 哪个层」只动 `TerrainTextures`（加层 + top/side_layer 映射）
  与两端类型白名单（`terrain_map.gd` `VALID_TYPES/BODY_TYPES` + `server terrain.ts`），
  atlas / mesh / shader **零改动**。
