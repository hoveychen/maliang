# themed-terrain P3 逐主题实施规格（12 主题全铺）

> 状态：执行中（2026-07-12 起，接力链）。本文是 P3「批量铺其余 11 主题」的**落地蓝本**，
> 供接力会话精确接续。P2 海底 = 完整样板。冰雪(主题①)已 commit 595411d。
> 母设计 `docs/themed-terrain-design.md`（**注：该文件在 main 未提交、不在 worktree**，
> 内容见 memory `themed-terrain-progress` 与 P1 实现记录 `themed-terrain-p1-plan.md`）。

## 0. 逐主题固定流程（照 P2/冰雪样板，每主题一 commit）

1. **下 CC0 源**：`curl -s -A 'Mozilla/5.0' https://api.polyhaven.com/files/<slug>` →
   `python3 -c "import sys,json;print(json.load(sys.stdin)['Diffuse']['2k']['jpg']['url'])"` → curl 下 jpg。
   （urllib 会 403，必须 curl 带 UA。全 CC0 免登录。）
2. **风格化**：`watercolorize.py`，**选项放位置参数之前**（`$VAR` 展开会触发 argparse 交错报错）。
   有机地面(土/沙/草/岩)用 `_base_organic` 档，结构化(瓷砖/石板/木/砖/金属)用 `_base_structured` 档，
   逐 tile 加 `--tint R,G,B --tint-amt`。画风锁 **①卡通光滑**。程序化贴图见 §3 用 `tools/gen_pattern_tex.py`。
3. **QA**：2×2 平铺缩略对比图人眼看一遍（查接缝/伪影/色偏）。
4. **入库**：产物 1024² RGB 复制到 `assets/textures/terrain/`；`godot --headless --path . --import` 生成 `.import`。
   `git add` **显式列文件**（含 `.png.import`、`.gd.uid`——本仓库 `.uid` 是跟踪的），勿 `-A`（防吞 symlink）。
5. **注册 `scripts/terrain_textures.gd`**：`LAYER_*` 常量 + `LAYER_TEX_PATHS`(顺序对齐!) + `layer_tints/means`
   (tint 已烘入→传 `_WHITE`) + `top_layer/side_layer` match 分支 + `LAYER_COUNT` 更新。
6. **两端白名单**：client `scripts/terrain_map.gd`(T_* + VALID_TYPES + BODY_TYPES) +
   server `server/src/terrain.ts`(T_* + VALID_TILE_TYPES)。⚠ `terrain_codec.test.ts` 用 **99** 作非法码哨兵，别撞。
7. **种子场景 `tools/export_<theme>.gd`**（照抄 `export_seafloor.gd`/`export_icesnow.gd`）：
   **先铺一个占多数的主底地表填满全图**再画区块——`ChunkManager._refresh_base_layer` 按「模态非水地表」
   自动取基底层，没有占多数的主底会取错。`scene_compose._deco_kind` 加 `<theme>` 分支(暂 `return DECO_NONE`)。
8. **测试 `test/test_terrain_<theme>.gd`**（照抄 `test_terrain_icesnow.gd`）：地表覆盖 + 层映射 +
   类型化崖壁(造两种不同类型抬高块) + 模态基底。登记进 `scripts/test-headless.sh`。
9. **回测**：`bash scripts/test-headless.sh`(exit 0；唯一既有 FAIL=`test_matrix_skin` 债，非回归) +
   `cd server && node --test`(全 pass) + `npx tsc --noEmit`(clean)。
10. **素材署名** `docs/asset-credits.md` + **预设记录** `tools/terrain_texture_presets.json` 追加。
11. **commit**（worktree 内，禁 AI 署名）。**不 merge/不 push**——merge 是 P4 验收门。

**环境**：venv(PIL+numpy) 在
`/private/tmp/claude-501/-Users-hoveychen-workspace-maliang/4287b3e2-*/scratchpad/.venv`；
中文字体 `/System/Library/Fonts/Supplemental/Songti.ttc`。Godot 4.6.3 `/Applications/Godot.app`。
worktree 已软链 `addons/maliang_asr_native/bin` + `server/node_modules`（gitignored，勿提交）。
macOS **无 `timeout` 命令**（rc=127）；视觉截图脚本会自行 quit，直接跑即可。

**⚠ live 引擎渲染 QA 当前被既有 harness 回归阻塞**：`test_visual_seafloor.gd` 式注入(把地形塞进
运行中的 main.tscn)已失效——main 启动流程会覆盖注入的 TerrainMap，seafloor/icesnow 皆只渲出村庄草地。
这是本分支 main boot 的既有问题(P2 当初在更早状态验的)，**非 P3 代码问题**。生产不走注入(.mltr 由
服务端 ingest 作世界地形)，已被 headless 自产自销 load+覆盖断言覆盖。P4 可另修 harness(绕开 main.tscn
或延后注入并阻止 main 重刷)后补 GPU 观感 QA。逐主题验证以 **headless 全绿 + 2D 贴图人眼 QA** 为准。

## 1. 层/类型分配表（1:1，T_code = LAYER index，均 < 99 避哨兵）

已有(0-16)：GRASS0 PATH1 BED2 CLIFF_LIP3 CLIFF_WALL4 SAND5 SNOW6 TILE7 CORAL8 COARSE_SAND9
CORAL_SAND10 SEAGRASS11 DEEP_BED12 | **冰雪已铺**：PACKED_SNOW13 ICE14 SLUSH15 ROCK_SNOW16。

新层(17-43，逐主题追加。src=Poly Haven slug 或 PROC=程序化；base=organic/structured)：

| idx | 名 | 用途(主题) | src | base | tint 提示 |
|--|--|--|--|--|--|
| 17 | CRACKED_EARTH | 干裂土(侏罗) / 夯土(中国) / 斗兽场沙土(罗马) | `brown_mud_dry` | organic | 干黄棕 |
| 18 | VOLCANIC | 火山岩(侏罗) | `burned_ground_01` | organic | 暗灰黑 |
| 19 | MUD_BOG | 泥沼(侏罗) | `brown_mud_02` | organic | 暗褐 |
| 20 | FERN | 蕨类草地(侏罗) | `forrest_ground_03` | organic | 深苔绿 |
| 21 | RUBBLE | 碎石(侏罗/罗马) | `bicolour_gravel` | organic | 中灰 |
| 22 | COBBLE | 鹅卵石(中世纪) / 卵石庭(中国) | `cobblestone_05` | structured | 暖灰 |
| 23 | STONE_SLAB | 石板(中世纪) / 青石板(中国) / 罗马石板 | `cobblestone_floor_04` | structured | 冷灰 |
| 24 | FARM_FURROW | 农田垄(中世纪) | `brown_mud_dry` | organic(带垄) | 棕；PROC 叠横垄暗线 |
| 25 | MARBLE | 大理石(罗马) | `marble_01` | structured | 米白 |
| 26 | MOSAIC | 马赛克地(罗马) | `old_mosaic_floor` | structured | 暖陶 |
| 27 | WOOD_FLOOR | 木地板(中国/玩具/厨房) | `wood_floor` | structured | 暖木 |
| 28 | ASPHALT | 沥青(现代) | `asphalt_02` | organic | 深灰 |
| 29 | PAVER_BRICK | 人行道砖(现代) | `brick_pavement_02` | structured | 砖红灰 |
| 30 | CROSSWALK | 斑马线(现代) | PROC | — | 深灰底+白条 |
| 31 | CONCRETE | 水泥(现代) / 混凝土(未来) / 手术室地(医院) | `concrete_floor_01` | structured | 浅灰 |
| 32 | LAWN_GRID | 草坪格(现代) | `grass_concrete_pavement` | structured | 草绿+格 |
| 33 | CARPET_RED | 地毯红(玩具) | PROC | — | 绒红 |
| 34 | CARPET_BLUE | 地毯蓝(玩具) | PROC | — | 绒蓝 |
| 35 | PUZZLE_MAT | 拼图垫(玩具) | PROC | — | 彩色互扣方块 |
| 36 | CHECKER_TILE | 格纹地砖(厨房) | `checkered_pavement_tiles` | structured | 黑白格 |
| 37 | ANTISLIP | 防滑垫(厨房) / 防滑走廊(医院) | `anti_slip_concrete` | structured | 中灰颗粒 |
| 38 | MED_VINYL_GREEN | 医用地胶浅绿(医院) | PROC | — | 浅薄荷绿 |
| 39 | MED_VINYL_BLUE | 医用地胶浅蓝(医院) | PROC | — | 浅天蓝 |
| 40 | METAL_PLATE | 金属板(未来) | `metal_plate` | structured | 冷银 |
| 41 | GRATING | 格栅(未来) | `metal_grate_rusty` | structured | 深银 |
| 42 | GLOW_TILE | 发光地砖(未来) | PROC | — | 青蓝发光格 |
| 43 | HAZARD | 警戒条纹(未来) | PROC | — | 黄黑斜条 |

**LAYER_COUNT 终值 = 44。** SHADER_ARRAY_SIZE=64 够。

## 2. 12 主题 tile 清单（每主题种子场景铺哪些 tile；★=主底占多数）

- ① **冰雪 icesnow**（✅595411d）：★压实雪13 / 雪原6 / 冰面14 / 雪泥15 / 裸岩积雪16 / 水2。
- ② **侏罗纪 jurassic**：★干裂土17 / 火山岩18 / 泥沼19 / 蕨类草地20 / 碎石21 /（抬高块：火山岩+碎石两型侧壁）。
- ③ **中世纪 medieval**：★草地0 / 泥土路1 / 鹅卵石22 / 石板23 / 农田垄24 /（抬高：石板+鹅卵石两型）。
- ④ **罗马 roman**：★罗马石板23 / 大理石25 / 碎石21 / 马赛克26 / 斗兽场沙土17 /（抬高：大理石+碎石）。
- ⑤ **中国古代 ancient_china**：★青石板23 / 夯土17 / 木地板27 / 卵石庭22 / 水墨水塘2 /（抬高：夯土+青石板）。
- ⑥ **现代城市 modern_city**：★沥青28 / 人行道砖29 / 斑马线30 / 水泥31 / 草坪格32 /（抬高：水泥+人行道砖）。
- ⑦ **玩具房间 toy_room**：★木地板27 / 地毯红33 / 地毯蓝34 / 拼图垫35 / 瓷砖7 /（抬高：瓷砖+木地板）。
- ⑧ **厨房 kitchen**：★白瓷砖7 / 格纹地砖36 / 木地板27 / 防滑垫37 /（抬高：瓷砖+木地板）。
- ⑨ **医院 hospital**：★医用地胶浅绿38 / 白瓷砖7 / 防滑走廊37 / 手术室地31 / 医用地胶浅蓝39 /（抬高：瓷砖+防滑）。
- ⑩ **未来机器人 future_robot**：★金属板40 / 格栅41 / 发光地砖42 / 警戒条纹43 / 混凝土31 /（抬高：金属板+混凝土）。
- ⑪ **中世纪/罗马/中国** 已在 ③④⑤。基础村庄(草/路/水)已有，作混搭底。

> ⑫ 主题数：冰雪+②-⑩ = 10 个新主题 + 基础村庄 + 海底(P2) = 12。老板过程中可增删每主题 tile。

## 3. 程序化贴图（`tools/gen_pattern_tex.py`，待建）

CC0 拿不到干净图案的 tile 用程序化平色图案生成（契合卡通光滑白卡纸风，比 AIGC 材质照片更过审）：
- **crosswalk**：深灰底 + 若干等距白色粗条（横向），条边缘微羽化 + 轻纸纹。
- **carpet_red/blue**：单色绒底 + 细高频噪声（绒毛感）+ 轻边缘积色，饱和度中低。
- **puzzle_mat**：4×4 互扣泡沫方块，相邻块不同柔和色（红/蓝/黄/绿），块间浅描边 + 凸角接口。
- **checker_tile**（若 CC0 不够干净则程序化）：黑白/米白棋盘格 8×8 + 轻纸纹。
- **med_vinyl_green/blue**：极浅纯色 + 极细颗粒（医用 PVC 地胶观感），近乎纯色。
- **glow_tile**：深底 + 青蓝发光网格线（格线亮、格内暗），发光靠亮度提升近似（无 emission，靠贴图亮值）。
- **hazard**：黄黑 45° 斜条纹交替，条边微羽化。
全部 1024²、无缝（图案周期整除 1024）、输出 RGB。tint 已含在图案色里→层 tint/mean 传 `_WHITE`。

## 4. 进度

- [x] ① 冰雪 icesnow — commit 595411d（层 13-16）
- [x] ② 侏罗纪 jurassic — commit 274002e（层 17-21）
- [x] ③ 中世纪 medieval — commit d40ff09（层 22-24；一并入库 marble/mosaic/wood_floor 贴图）
- [x] ④ 罗马 roman（层 25-26，复用 17/21/23）— 与⑤同 commit
- [x] ⑤ 中国古代 ancient_china（层 27，复用 22/23/17）— 与④同 commit
- [x] ⑥ 现代城市 modern_city（层 28-32；crosswalk PROC）— 新增 tools/gen_pattern_tex.py
- [x] ⑦ 玩具房间 toy_room（层 33-35 PROC，复用 7/27）— carpet_red/blue/puzzle_mat 程序化
- [ ] ⑧ 厨房 kitchen（层 36-37，复用 7/27）— checker_tile(CC0 checkered_pavement_tiles 或 PROC checker) + antislip(CC0 anti_slip_concrete)
- [ ] ⑨ 医院 hospital（层 38-39 PROC，复用 7/31/37）— med_vinyl_green/blue 程序化 vinyl
- [ ] ⑩ 未来机器人 future_robot（层 40-43；42/43 PROC，复用 31）— metal_plate/grating CC0 + glow/hazard 程序化
