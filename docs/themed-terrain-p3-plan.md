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
- [x] ⑧ 厨房 kitchen（层 36-37，复用 7/27）— checker_tile PROC + antislip CC0
- [x] ⑨ 医院 hospital（层 38-39 PROC，复用 7/31/37）— med_vinyl_green/blue 程序化 vinyl
- [x] ⑩ 未来机器人 future_robot（层 40-43；42/43 PROC，复用 31）— metal_plate/grating CC0 + glow/hazard 程序化

**P3 全部 10 个新主题完成（LAYER_COUNT=44）。加上 P2 海底 + 基础村庄 = 12 主题全铺。**

## 5. 老板 GPU 观感验收反馈（2026-07-12，决策卡）+ 已改 / 待做

老板对 10 主题桌面 GPU 渲染（`test/test_visual_theme.gd`，commit e67c25f）验收，提 4 点：

**已改完提交：**
- ✅ **冰雪太灰 → 白皑皑**（commit 7b91eda）：packed_snow/rock_snow/slush 重做，高 lift 提亮 +
  低饱和 + 近白 tint。桌面 GPU 复验够白。
- ✅ **现代城市沥青太浅 → 压深**（7b91eda）：asphalt tint 60,62,66 amt 0.55，深灰路面。
- ✅ **侧壁黑色圆角凹缝 → 去掉干净平铺**（commit df712c1）：`_wall_fn` 恒 A=0.5（纯贴图×tint，
  无凹缝/棱线/地层带）；改了 test_terrain_atlas「wall crevice」断言；删死代码 _wall_lum/R_OUT_WALL。
  桌面 GPU 复验侧壁已无黑描边。

- ✅ **冰雪崖壁「白方糖」→ 雪崖感**（commit ce28dc2）：`_wall_fn` 沿纵向烘「崖顶亮(1.5×)
  →崖底暗(0.66×)」明暗浮雕（A 通道，只随 y 变不随 d 变 → 去横向黑边保留、无卡通描边）；
  shader 加 `wall_relief[64]` 逐侧壁层强度，仅作用崖壁 role（顶面/地表明暗不受影响）；
  `layer_wall_reliefs` 雪族满档、冰面略低、其余层默认 0=平铺（室外岩壁/室内光滑墙零回归）。
  桌面 GPU 复验：崖壁顶缘明显提亮、崖基入影，破了硬方块感。
  QA harness 修了 look_at 入树前调用的既有 bug + 加 AIMY 取景偏移。
- ✅ **冰雪崖壁几何倒角**（commit 1618d9b，老板拍板「逐 tile 倒角、非全主题一刀切」）：
  `TerrainTextures.tile_bevel(ttype)` 逐 tile 类型开关——雪族 0.4m/冰面 0.6×，其余恒 0=直角。
  `chunk_manager._emit_top_face` 对 beveled tile 内缩临崖顶缘 + 发 45° chamfer 斜面(顶面雪贴图，
  雪盖滚过棱)+外凸角 miter；`_emit_walls` 顶级墙顶降 bevel 让位。地形网格无碰撞、纯视觉不影响寻路。
  桌面 GPU 复验：雪崖顶缘圆润雪盖斜面；jurassic 等非雪主题崖壁仍利落直角(零回归)。
  test_terrain_icesnow +倒角逐类型断言 +倒角斜面几何断言。
- ✅ **崖壁倒角改圆润 fillet + 缩小**（commit 1d448ec，老板反馈「不圆滑/切一刀/太多」）：
  单一 45° 平斜面(平法线像刀切)→ 3 段 1/4 圆弧外凸 + 逐顶点径向法线(顶缘 UP 接顶面、底缘水平接墙)，
  光照从顶面平滑扫到墙面 = 真圆润棱；BEVEL_SNOW 0.4→0.22(冰面 0.6×)收小；外凸角 miter 也改平滑法线。
  `_emit_fillet`(BEVEL_SEGS=3 弧段) + `_emit_facet4n`(逐顶点法线发射器)。**老板已 GPU 验收通过**。

**室内主题墙面重做（老板拍板「配专属墙面贴图搭房间」）：**
- ✅ **玩具房间 toy_room**（commit 85645e4）：新层 LAYER_TOY_WALL=44 + wall_toy 程序化贴图
  （奶油底+柔彩圆点托儿所壁纸）；新 tile T_TOY_WALL=44 两端白名单；export_toy_room 重写为
  木地板底 + 四周 2 格厚墙环抬高 3 级成四面围墙 + 内部红毯/蓝毯/拼图/瓷砖 + 中央矮玩具台；
  `_wall_ring` 助手（可复用给其余室内主题）；test +墙覆盖/抬高/层映射断言。GPU 复验波点墙围房间。
  **机械配方（其余 3 个室内主题照此）**：① gen_pattern_tex 加 wall_<theme> 或 CC0 墙贴图 →
  ② LAYER_* +1/LAYER_COUNT +1/LAYER_TEX_PATHS/tint白/mean白 → ③ T_* 两端白名单(+VALID +BODY) →
  ④ top/side_layer 映射 + tile_bevel 保持 0 → ⑤ export_<theme> 用 `_wall_ring` 围房间 →
  ⑥ test +墙断言 → ⑦ import + headless + tsc + server + GPU 复验。
- ✅ **厨房 kitchen / 医院 hospital / 未来机器人 future_robot**（commit 6243cbd）：照 toy_room
  配方各配专属程序化墙贴图搭带墙房间——新层 45 KITCHEN_WALL（白瓷砖墙：白底+浅灰勾缝网格）、
  46 HOSPITAL_WALL（浅薄荷 plaster 近纯色）、47 FUTURE_WALL（冷银金属舱壁：面板分块线+横向拉丝）；
  `tools/gen_pattern_tex.py` 加 wall_kitchen/wall_hospital/wall_future 三 kind；两端白名单加
  T_KITCHEN_WALL/T_HOSPITAL_WALL/T_FUTURE_WALL(45/46/47)；export_* 重写为 `_wall_ring` 围四壁
  （木/瓷砖/金属地面底 + 内部地面装饰 + 中央矮台 type-aware 侧壁），未来舱去水池（室内无水）；
  tile_bevel 保持 0（室内墙利落直角）；test 加墙断言（墙 tile 出现 + 抬高 h≥2 + top/side 墙层）。
  验证：import + 3 新测试 PASS + 全套 headless「全部通过 ✔」+ server 527 pass/0 fail + tsc 0；
  桌面 GPU 复验三房间墙体围合、地面装饰正确。**待老板 GPU 逐个验收。**
  ⚠ 户外主题（冰雪/侏罗/中世纪/罗马/中国/现代/海底）保持「地面+mound」不动。
## 6. 下一步

- **先做 §5 室内墙面重做**（老板头号）。
- 然后 P4：主题公园 demo（一场景混多主题地面）+ 铺地入口（主题种子场景 POST /admin/scenes /
  玩家涂地面工具，老板定）+ 全套回测 + merge --no-ff 回 main（验收门）。
- GPU 观感 QA 用 `test/test_visual_theme.gd`（THEME/FOCUS/PITCH/DIST 环境变量；bend 曲率截图上半为天，
  地形在下半；勿 set curvature=0——会连带破坏 world-scroll）。真机（老 Mali）性能/观感仍未验。
