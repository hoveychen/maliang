# 场景重构设计：地形矩阵 v2 + 万物皆物品（scene-items）

> 状态：定稿（2026-07-11 老板过目并纠正物品模型后修订）。
> 目标一句话：**一份地形矩阵 = 一个场景的完整静态描述**——tile 类型/高度/水深 + 挂在 tile 上的物品引用，
> 物品本身是统一实体表（内置布置物与语音造物同表，可克隆可引用），
> 服务端可 tile 级局部修改并广播，客户端凭矩阵完整重构世界，admin 后台画出矩阵图过滤全世界的东西。

## 0. 老板拍板的约束（2026-07-11）

1. **万物皆物品，统一实体表**：每种物品（树/民居/水井/语音造物…）都是物品实体表的一行，
   持有自己的全量参数（渲染引用/SDF spec/占地/阻挡…）；**其他所有地方都是对实体 ID 的引用**，
   同一实体可被克隆/多处引用。静态布置物收敛为内置的十几行 seed。
2. 物品直接挂在 tile 数据里（tile 正上方，或 tile 四面边缘），只附方向/高度这类小参数；
   **将物品放在某处 = 修改那个 tile 的数据（挂一个物品引用）**。
3. **OccupancyMap 融入地形 tile**：静态占用从矩阵推导，不再靠摆放时登记。
4. **一份矩阵传输 = 客户端完整重构整个世界**。
5. 地形修改是**频繁**的（游戏内玩法驱动），必须支持 **tile 级局部 update**。
6. tile 四面**边缘挂载**（墙/篱笆/门类薄片物）：数据位一期就留，渲染二期。
7. 散布装饰（森林铺满树 ≈2800 个）也全量入矩阵，彻底删除运行时散布规则。

## 1. 现状（已核实，file:line 均验证过）

### 1.1 地形——已经是「类型+高度」矩阵，缺的是可变性

- 格式 `.mltr` v1：11B 头 + `types`/`heights`/`depths` 三张 75×75 u8 平面
  （[server/src/terrain.ts:8-19](../server/src/terrain.ts#L8-L19)、[scripts/terrain_map.gd:33-79](../scripts/terrain_map.gd#L33-L79)）。
  raw 16886B，gzip 后实测 495B。
- 服务端只做校验+内容寻址存储+记 hash（`scenes.terrain_asset`），从不生成/修改；
  地形由 Godot 离线工具（`tools/export_terrain.gd` / `export_forest.gd`）程序化导出再 `POST /admin/scenes` 上传。
- 客户端 mesh **按 wrapped chunk（25×25）键控永久缓存**（[chunk_manager.gd:107-111](../scripts/chunk_manager.gd#L107-L111)），
  唯一重建入口是换场景时 `changed` 才全图 `rebuild()`（[chunk_manager.gd:236-240](../scripts/chunk_manager.gd#L236-L240)）。
  没有场景内热更协议。

### 1.2 布置对象——四档来源，大部分服务端不可见

| 类别 | 来源 | 服务端可见 |
| --- | --- | --- |
| 散布装饰（树/灌/石/草丛，上千个） | 客户端逐 tile hash 确定性生成（[chunk_manager.gd:369-461](../scripts/chunk_manager.gd#L369-L461)） | ❌ |
| 地标建筑（井/风车/8 民居/泉石） | 客户端硬编码 `LANDMARKS` 常量表（[chunk_manager.gd:70-83](../scripts/chunk_manager.gd#L70-L83)） | ❌ |
| SDF 可动物件（走路小屋/信箱…7 个） | 客户端硬编码 `SDF_PROPS` 常量表（[chunk_manager.gd:88-96](../scripts/chunk_manager.gd#L88-L96)） | ❌ |
| Portal 拱门 | 坐标服务端 `scenes.portals` 下发，spec 客户端 | ✅ 半 |
| 语音造物 WorldProp | 唯一 SDF spec + tile + state(placed/bagged) 持久化（`props` 表） | ✅ |

- 所有静态物已吸附 tile 中心（`_tile_local`）、按 tile 占地。
- 摆放冲突靠**运行时螺旋找位**（`_spawn_on_tile` search/ring，[chunk_manager.gd:812-822](../scripts/chunk_manager.gd#L812-L822)）——
  客户端摆放时试探 `OccupancyMap.prop_area_ok`，找不到就外扩。新模型下这整套逻辑消亡（见 §3.4）。

### 1.3 OccupancyMap——两层，静态层靠摆放登记

0.5-tile 分辨率环面位图（[occupancy_map.gd:1-15](../scripts/occupancy_map.gd#L1-L15)）：
物件层 `_occ`（摆放登记/释放，chunk 重刷时按 `_claims` 释放再登记）+ 角色层 `_chars`（运行时迁移）。
`prop_area_ok` 综合查地形类型/高度一致/物件占用/角色站位（[occupancy_map.gd:120-133](../scripts/occupancy_map.gd#L120-L133)）。

### 1.4 admin 俯视图——半成品

`SceneMap`（server/admin/src/pages/WorldDetail.tsx）画 POI/portal/角色/造物标记，
**不解码地形**（草/水/高度不可见），客户端硬编码的两档对象也看不见。

## 2. 目标数据模型

三层结构，自上而下：

```
items 实体表（物品定义，内置 seed + 语音造物同表）
   ↑ 被引用（item id）
scene palette（场景调色板：u8 索引 → item id，内嵌矩阵尾部）
   ↑ 被索引（u8）
tile 矩阵（九张平面 + palette，一份自包含 blob）
```

### 2.1 items 实体表（统一物品定义）

SQLite 新表（替代 `props` 表，见 §5 迁移）：

```
items(
  id TEXT PRIMARY KEY,       -- 内置项用众所周知 id（'tree_puff_a'…），造物用生成 id
  world_id TEXT NULL,        -- NULL = 内置全局定义；非空 = 该 world 的语音造物
  name TEXT,                 -- 显示名（"苹果树"/孩子起的名字）
  render_ref TEXT,           -- 渲染引用：'baked:tree_puff_a' | 'kaykit:house_0' |
                             --   'sdf_res:walking_hut' | 'sdf_inline'（spec 字段内联）
  spec TEXT NULL,            -- sdf_inline 时的 LLM 生成 SDF spec JSON
  footprint_w INT, footprint_h INT,   -- 占地（1×1 / 3×3…），锚点展开
  blocking INT,              -- 0=可穿行(草丛) 1=占位
  path_ok INT,               -- 允许压路（水井）
  wander REAL,               -- SDF 物件锚点游走半径（米），0=不动
  created_at INT
)
```

- **内置 seed ≈ 21 行**：tree_puff_a/b/c、bush_puff、rock_0/1/2、tuft_0/1、house_0..3、
  well、windmill、walking_hut、hop_mailbox、nodding_flower、pinwheel、paper_note、crayon、village_sign。
  语义（footprint/blocking/wander）从现硬编码表迁入；每个视觉变体一行（palette 空间足够，
  不再需要 variant 位）。
- **语音造物插新行**（`render_ref='sdf_inline'` + spec 内联），与内置项同表同机制——
  这就是"可克隆/引用"：同一造物可以被多个 tile 引用（孩子把一朵花种满一排）。
- 客户端渲染绑定：`render_ref` 前缀分发——`baked:`/`kaykit:` 查 GDScript preload 映射表
  （编译期资源，一行一个），`sdf_res:`/`sdf_inline` 走 `SdfProp.from_spec`。语义全部来自实体行，
  客户端映射表只做资源绑定。

### 2.2 `.mltr` v2 —— 九张平面 + palette 尾段（自包含）

保持 planar 布局（gzip 对全零/低熵平面近乎免费），头部 version=2：

```
magic    "MLTR"   4 B
version  u8 = 2   1 B
gridW    u8       1 B
gridH    u8       1 B
tileSize f32      4 B
types      u8[N]   0 草 / 1 路 / 2 水            （沿用 v1）
heights    u8[N]   0..255 级台阶                 （沿用 v1）
depths     u8[N]   水深，仅水 tile 非零           （沿用 v1）
item_ref   u8[N]   0=无物品 / 1..255=palette 索引 （新增）
item_arg   u8[N]   bits0-1 朝向四象限 / bits2-7 保留（新增）
edge_n     u8[N]   北边缘 palette 索引，一期恒 0   （新增，数据位）
edge_e     u8[N]   东边缘，一期恒 0
edge_s     u8[N]   南边缘，一期恒 0
edge_w     u8[N]   西边缘，一期恒 0
--- palette 尾段 ---
count    u8
entry×count：len u8 + item_id UTF-8 bytes
```

- 75×75 → 11 + 9×5625 + palette ≈ 51KB raw；gzip 预计 <3KB（item 平面大部分为 0）。
- **palette 内嵌 blob**：矩阵自包含（"一份矩阵重构世界"）——客户端另需的只有 palette
  所引用的 items 定义（场景进入时随包下发/按需拉取+缓存，见 §3.1）。
- 255 个不同物品定义/场景的上限足够（内置 21 + 该场景造物种数）；palette 可在造物被
  全部移除后压实回收。
- **多 tile 物品（民居 3×3 等）只写锚点 tile**；footprint 从实体行展开推导，被覆盖 tile 不写数据。
  朝向旋转 footprint。
- **视觉抖动不入库**：散布树的每棵微缩放/精细朝向仍由 tile hash 确定性派生（保持现观感，
  [chunk_manager.gd:360](../scripts/chunk_manager.gd#L360) 同款算式），`item_arg` 只存语义朝向。
- 边缘物品的参数平面（篱笆高度档等）留给 v3；边缘物世界高度默认取所在 tile `height`。

### 2.3 明确不进矩阵的东西

- **角色**：暂态活物，客户端空间权威 + positions_report，照旧。
- **Portal**：携带 `to_scene`/`to_tile` 跨场景引用，保留在 `scenes.portals` JSON；
  拱门渲染照旧走 world.gd 专用通道（占位/传送语义特殊）。
- **POI**：语义标注（名字/别名/触发），非物理物，保留在 `scenes.pois`。
- ~~语音造物~~ **已并入 items 实体表**（老板纠正后）——不再是例外。

### 2.4 存储与版本：矩阵搬进 DB，告别内容寻址

频繁编辑与内容寻址天然冲突（每次编辑生成新 hash、旧 asset 堆积）。改为：

- `scenes` 表加 `terrain BLOB`（v2 raw bytes）+ `terrain_version INTEGER`（单调递增，每次编辑 +1）。
- 全量下载走新端点 `GET /worlds/:wid/scenes/:sid/terrain`（gzip，响应头带 version）。
- `terrain_asset` 列保留一个过渡期（迁移脚本把 asset 内容搬进 blob 后置空）。
- 客户端磁盘缓存键 = `(worldId, sceneId, version)`。

## 3. 协议与行为

### 3.1 场景进入与 items 定义下发

`scene_entered` 响应增补：`terrainVersion` + `items[]`（palette 引用到的全部实体行；
内置定义体积小，造物 spec 稍大但每场景个位数到几十——直接随包下发，客户端按 id 缓存）。
后续新造物经 `prop_created` 同款推送渠道带上新实体行。

### 3.2 局部更新（新 WS 消息）

```
// 服务端 → 同 world 在场客户端广播
{ type: 'terrain_patch', worldId, sceneId, version,
  paletteAppend?: [{ index, itemId }],   // 首次引用新物品时扩 palette
  itemsAppend?: [ItemDef],               // 客户端没见过的实体定义随 patch 带上
  edits: [{ x, y,
            t?: number,                  // tile 类型
            h?: number, d?: number,
            item?: [refIndex, arg] | null,   // null = 移除物品引用
            edge?: [side, refIndex] }] }
```

- 服务端持有唯一写入口 `applyTileEdits(worldId, sceneId, edits)`：
  校验（水深仅限水 tile、footprint 不重叠/不压水/高度一致——把 `prop_area_ok` 语义搬到 TS）→
  应用到 blob → `version++` → 广播。
- 客户端收到 patch：version 必须 == 本地 version+1，否则（乱序/断连漏包）**全量重拉**兜底。
- 编辑入口一期两个：admin API（后台/脚本用）+ 现有拾起/摆放链路改走 tile 编辑（§3.5）。
  游戏内 LLM 意图 `edit_terrain`（挖水/铺路/种树）留作后续独立 PRD——API 本期修到位。

### 3.3 客户端局部重铺

mesh 缓存本来就按 chunk 键控，局部重铺 = 精准失效：

1. `TerrainMap.apply_patch(edits)` 改九张平面 + 重算派生占用（§3.4），返回受影响 tile 集。
2. 受影响 chunk = tile 所在 chunk ∪ 相邻 chunk（当 tile 落在 chunk 边界 ±1 内——autotile 掩码、
   崖壁、水面角点色都看 ±1 邻居，[chunk_manager.gd:508-524](../scripts/chunk_manager.gd#L508-L524)）。
3. `chunk_manager.rebuild_tiles(affected)`：清对应 `_chunk_meshes`/`_water_meshes` 项 +
   slot `skinned=false`，复用现有 `update()` 每帧一块的分帧重铺（单块真机 80-200ms，
   一次编辑最多波及 4 块，分帧无感）。

### 3.4 chunk_manager 数据源切换 + OccupancyMap 融合（摆放语义反转）

- `_skin` 里三段布置逻辑（LANDMARKS 表 / SDF_PROPS 表 / `_deco_kind` 分区散布）**整体删除**，
  换成一段：逐 tile 读 `item_ref/item_arg` → palette → items 定义 → 该合批的合批
  （tree/bush/rock/tuft 照旧 MultiMesh + 贴片阴影），该独立节点的独立节点
  （house/well/SDF 物件照旧）。渲染管线零改动，只换数据源。
- **旧**：客户端摆放时试探 `prop_area_ok`，冲突则螺旋找位，`_claims` 登记/释放。
  **新**：矩阵说了算。服务端写入时已保证无冲突；客户端 `TerrainMap` 载入/patch 时把所有
  item footprint 展开成一张**派生静态占用位图**，`prop_area_ok` 的物件层查询改查它。
  `_spawn_on_tile` 的 search/ring 螺旋、`_claims` 登记簿、`_dynamic_props` 运行时清单
  全部删除——净删代码。
- OccupancyMap 只保留**角色层**（暂态运行时状态，照旧）。
- 生成端（导出工具）负责初始布局无冲突；服务端 `applyTileEdits` 负责编辑期无冲突。

### 3.5 拾起/摆放/背包语义（造物融合的连带变化）

现状：WorldProp 实例有 id，`placed/bagged` 状态，拾起拖拽按实例寻址
（`pickup_dynamic_prop`）。新模型下**实例身份消解为（tile + 实体引用）**：

- **摆放** = `applyTileEdits` 在目标 tile 挂 item 引用（palette 索引），背包扣一份。
- **拾起** = `applyTileEdits` 清掉该 tile 的 item 引用，背包加一份。
- **背包** = `(world, player)` 持有的 item id 计数清单（wallet 同款分表思路）。
- **克隆**：同一实体 id 可被任意多 tile 引用——"把一朵花种满一排"天然成立。
- 拖拽预览等纯客户端交互照旧，落定那一刻才发 tile 编辑。
- 内置物品（树/石头）与造物走同一条路——为盖房腾地砍一棵树 = 同一个 tile 编辑。

### 3.6 生成管线迁移

- `_deco_kind` 村庄/森林分区散布规则 + `LANDMARKS`/`SDF_PROPS` 常量表 → **搬进导出工具**
  （`tools/export_terrain.gd`/`export_forest.gd`，仍是 Godot 离线跑），产出含 item 平面 +
  palette 的 v2 矩阵上传。服务端不需要生成规则，只需要编辑校验。
- **离线/回测回退**：导出工具产出的默认村庄 v2 矩阵作为资源进包（`assets/terrain/village.mltr`，
  git tracked），离线模式与 headless 回测加载它 + 内置 items seed 打包进客户端——
  散布/地标从此在离线态也与线上一致。`_paint()` 保留为极端兜底（资源缺失），
  纯 `_paint()` 兜底下世界没有树（可接受：只是兜底，不是常态路径）。

## 4. admin 矩阵图升级

- `SceneMap` 拉 v2 矩阵：canvas 渲染地貌底图（草/路/水调色 + 高度明暗 + 水深加深），
  item 层按实体定义上色/图标叠加，现有角色/POI/portal 标记继续叠最上层。
- **图层开关 + item 过滤器**：按实体 id/名字勾选 tree/house/某个造物…快速过滤整个世界里的
  各种东西（老板的核心诉求）。
- 后台画笔编辑不在一期（老板拍板地形修改主要由游戏内玩法驱动）；但 `applyTileEdits` 是
  通用 API，后台编辑器随时可以作为纯前端功能补上。

## 5. 迁移与风险

**props 表迁移**：存量 WorldProp → items 行（spec 内联）+ `placed` 者写进所在场景矩阵
（palette 扩容 + tile 引用）+ `bagged` 者进背包计数表。`props` 表与 `terrain_asset`
内容寻址走完过渡期后退役。

| 风险 | 缓解 |
| --- | --- |
| headless 回测大量锚定默认地形/散布（风车丘/池塘/占位测试） | 默认 v2 矩阵进包且由现规则确定性导出——布局与今天逐 tile 一致，测试锚点不漂移；断言改读矩阵 |
| patch 乱序/漏包导致双端矩阵分叉 | version 严格 +1 校验，不合即全量重拉（gzip <3KB，代价可忽略） |
| 编辑落在角色脚下（挖水淹角色/物品压角色） | `applyTileEdits` 校验不含角色（服务端只有 tile 精度旧位置）；客户端 patch 应用后对站在非法 tile 的本地角色触发一次就近挪位（复用 `_find_free_spot`） |
| 单 tile 编辑波及 4 chunk 重铺（真机 80-200ms/块） | 复用现成分帧重铺；编辑不是每帧发生，可接受 |
| 拾起/摆放链路重写引入回归（造物是核心玩法） | P5 专项 headless 覆盖：摆放→拾起→再摆放 roundtrip、断连重入恢复 |
| v1→v2 迁移 | decodeTerrain 兼容读 v1（item 平面补零、空 palette）；两个存量场景用升级后导出工具重跑重传 |
| GRID_TILES=75 编译期锁死 | 本次不放开（与 v1 相同约束，独立事项） |

## 6. 分期（7 个 P-task）

- **P1 格式与实体表**：`.mltr` v2 编解码（TS + GDScript 双端，含 palette 尾段）+ items 表
  schema/CRUD + 内置 seed 定义 + footprint 展开/冲突校验纯函数；单测（roundtrip / v1 兼容 /
  footprint 冲突拒收 / palette 扩容压实）。
- **P2 导出工具搬规则**：`_deco_kind` 分区散布 + LANDMARKS/SDF_PROPS 迁入导出工具，产出
  村庄/森林 v2 矩阵（含 palette）；默认村庄矩阵进包；与今日客户端逐 tile 判定结果一致
  （等价性快照测试）。
- **P3 服务端**：scenes 表迁移（terrain blob + version、asset 内容搬入）、items 表落库 +
  props 迁移脚本、全量下载端点、`applyTileEdits` + 校验 + `terrain_patch` 广播、
  `scene_entered` 增补 items 下发；单测。
- **P4 客户端读矩阵**：TerrainMap v2 + 派生占用 + chunk_manager 数据源切换
  （删三段硬编码布置 + 螺旋找位 + `_dynamic_props`）；headless 回测（同一矩阵重构出等价世界、
  锚点测试迁移）。
- **P5 局部更新链路**：`apply_patch` + `rebuild_tiles` + WS patch 处理 + version 兜底 +
  拾起/摆放/背包改走 tile 编辑 + 角色非法位挪位；headless 测试（patch 后 mesh 失效范围/
  占用同步/摆放拾起 roundtrip）。
- **P6 admin 矩阵图**：地貌底图渲染 + item 图层 + 实体过滤器。
- **P7 验收门**：全套回测 + 真机（平板）过一遍帧率与编辑手感 + merge --no-ff 回 main。

游戏内玩法的 LLM 意图接入（`edit_terrain` 意图设计与提示词）为**后续独立 PRD**——
本期把 `applyTileEdits` API 修到位，玩法接入只是加意图类型。
