# world = template(base) + 世界 overlay：真 base+overlay 重构设计

状态：**P2 + P3 已实现（worktree `prd/template-overlay-arch`，待合并/部署）**。取代原「快照拷贝 + 单向 additive 补丁」模型。
背景与踩坑见 memory `village-homes-seeded-template-propagation`。§6 决策点已按老板拍板落定、§8 记「实现如何」。

## 1. 为什么要改（钉住需求，不发明需求）

**老板实际要的（本次唯一需求）：** 作者对 template 的内容更新（先是 `pois`/`portals`/`homes`，
最终连 authored 地形），要能自动传到**存量玩家世界**，而**不冲掉孩子在自己世界里做过的编辑**。

具体痛点（已发生，非假想）：给 template 加了 `homes`，b825/c6a2/w_2375 都收不到，只能逐个手动 POST；
而且并行的内容 plan 重 seed template 场景时，不带 homes 就把 homes 整行覆盖没了。

**不在本次范围（明确 OUT）：** characters/items 实例层的 base+overlay（角色站哪、造物）。
`character_defs`（长相/身份定义）**已经**是全局共享层，够用；实例层迁移是另一个 plan 的事，别顺手做。

## 2. 现状（逐行核过 persistence.ts）

- 每个世界是 template 的**一份完整独立拷贝**，克隆时整个 materialize。`getWorld` 读世界自己的行
  （`WHERE world_id=?`），**没有**读时合成。
- `scenes` 表：每 (world_id, scene_id) 一行，含完整 terrain blob + `pois`/`portals`/`homes`（JSON 文本）。
- 孩子的编辑（placement mode / `applyTileEdits`）**直接改**世界自己那份 terrain 矩阵；没有任何地方
  存「孩子相对 template 的差异」。
- `#migrateWorldPlacements`→`#cloneScenes(additiveOnly=true)`：只补世界**还没有**的整个场景，
  `if (existing.has(scene_id)) continue`——已有场景从不更新。这是 homes 传不过去的根因。

## 3. 目标模型：base + overlay

**base**：`scene(templateWorld, sceneId)` 的**当前**内容（跟着作者更新走），充当所有世界该场景的底。

**overlay**：每个世界只存**相对 base 的 diff**，读时 `compose(base, overlay)` 现算出该世界看到的场景。

字段分两类，overlay 的语义不同：

| 字段 | 孩子能改? | overlay 里存什么 | 读时结果 |
|---|---|---|---|
| `pois` / `portals` / `homes` | ❌ 无编辑入口 | **什么都不存** | 恒等于 base（作者更新自动生效） |
| terrain 矩阵 | ✅ placement/tile edit | 孩子改过的 **tile-diff 集**（tile→新值）+ 放置物 | base 地形叠上孩子的 tile-diff |

**冲突策略（terrain）：** 若作者改了某 tile、孩子也改过同一 tile → **孩子 overlay 胜**（保住孩子 agency，
延续当前 additive-protect 的初衷）；作者对孩子没碰过的 tile 的改动照常流入。

**关键收益：** base = template 场景的**当前值**，所以作者一改 template，存量世界下次读自动重算 → 传播天然成立，
无需逐个 POST，也不会被重 seed 冲掉（世界压根不存这些字段的副本）。

## 4. 薄切分档（Rule 6：先证最薄一条竖切，别一次盖全）

### P2 — 作者字段先行（薄切，低风险，直接修 demonstrated 痛点）
`pois`/`portals`/`homes` 读时一律取自 template base；世界行**不再各存**这三字段。
- `getScene`/`listScenes`：这三字段从 `scene(template, sceneId)` 取，不从世界行取。
- 迁移：存量世界这三字段清空（读路径已改走 base，数据冗余无意义）。terrain 暂不动。
- **这一档独立交付就已消灭 homes/新 POI/新故事门不传播的痛**，且完全不碰高风险的地形 diff。

### P3 — 地形 base+overlay（野心档，高风险，单独一档）
世界只存相对 template base 的 tile-diff overlay：
- 孩子 `applyTileEdits`/placement → 写 overlay（tile-diff 集），不再整块改世界 blob。
- 读时 `composeTerrain(base, overlay)`。
- 迁移存量世界：`diff(世界现有 blob, template base)` → 导出 overlay，落库；世界不再存整块 blob。
- terrainAsset/version 语义随之调整（hash 基于合成结果还是仅 overlay？待定，P3 细化）。

### P4 — 收口
文档定稿、全绿、`merge --no-ff` 回 main（部署等老板）。characters/items 实例层 OUT-of-scope。

## 5. 存量 materialized 世界的迁移（一次性，最危险的一步）

现有 4 个 prod 世界都是全 materialize 的。迁移必须**幂等 + 可回滚**：
- 先 `VACUUM INTO` 全量快照备份（见 memory `data-backup-and-asset-storage`）。
- P2 迁移：清世界的 pois/portals/homes（低风险，读路径改了就冗余）。
- P3 迁移：逐世界 `diff(blob, base)` 出 overlay；**diff 为空**（世界地形==base）的世界最干净；
  w_2375 这种停在**旧 base**（51bd88bb）的世界要特判——它的 base 该锚到哪个 template 版本？
  （候选：给世界记 `baseSceneVersion`，overlay 相对那个版本；或统一重锚到当前 base + 把差异全塞进 overlay。P3 决策点。）

## 6. 决策点（老板 2026-07-21 拍板落定）

1. **terrain 冲突**：**孩子 tile 胜**。孩子碰过的 tile 恒用 overlay 值，作者对孩子没碰过的 tile 的改动照常流入。
2. **w_2375 旧 base**：overlay 相对**当前 base**，**不存 per-world base 版本**、不特判 w_2375。迁移 = `diff(世界现 blob, 当前 base)`，
   语义无损（compose(base, overlay) 逐 tile 还原世界现地形）；w_2375 只是差异较大 → overlay 较大，观感不变。
3. **terrainAsset / 版本语义**：客户端缓存键实测走 **`terrainVersion`（int）** 而非 `terrainAsset`（hash 只是 `version==0`
   的老服务端回退，见 `world.gd _apply_scene`）。故对外 **`terrainVersion = baseTerrainVersion + overlay_edit_count`**：
   base 改（作者改地形）或孩子编辑都让它变 → 客户端重拉；严格单调不复用 → 无缓存键碰撞；孩子编辑恰 +1 → `terrain_patch` 对齐。
   `terrainAsset` 保持 best-effort（不再逐 getScene 重算合成 hash），modern 客户端不依赖它。
4. **本次连 terrain 一起做**（P2+P3）：老板拍板一起做。P2 先解决 demonstrated 痛点（homes/POI 传播），P3 补 terrain。

## 7. 验收标准（可机器验证）

- P2：改 template 的 homes → **不重新 POST 任何玩家世界**，GET 每个存量世界该场景 `homes` 即刻反映新值。✅ `template_overlay_authored.test.ts`
- P3：孩子在世界改一片 tile → 作者改 template 另一片 tile → 该世界读到「作者的新 tile + 孩子的旧 tile」都在。✅ `template_overlay_terrain.test.ts`
- 全程 `cd server && npm test` + `npx tsc --noEmit` + `scripts/test-headless.sh` 绿。

## 8. 实现如何（as-built）

**P2（作者字段）**：`getScene/listScenes` 的 `pois/portals/homes` 一律取自 `#baseSceneMeta(sceneId)`（template 该场景行）；
template 世界读自己行；模板缺该场景 → 回退世界自己行。`#cloneScenes` 克隆到玩家世界时这三字段写 `'[]'`；
`#migrateScenesDropAuthoredFields` 清存量世界与 base 同名场景的冗余拷贝（模板独缺的保留 → 无损）。

**P3（地形）**：纯函数在 `terrain_overlay.ts`——`diffTerrain(child, base)`（逐 tile 比对，item/edge 存 id 字符串）、
`composeTerrain(base, overlay)`（per-tile-wins，id 就地 intern 进合成 palette，无校验不崩）。持久层：`scenes` 加
`terrain_overlay`(JSON,NULL=老式全量 blob) + `overlay_edit_count` 两列。`getSceneTerrain` 对 overlay 世界现算
`composeTerrain(base, overlay)`；`commitSceneTerrain`（`editSceneTerrain` 唯一写入口）重 diff 出 overlay + 计数+1；
`#cloneScenes` 克隆即 overlay 模式（空 overlay）；`#migrateScenesToOverlay` 存量全量 blob → overlay（只转有 base 的同名场景）。

**关键取舍 / 偏离本设计的地方**：
- **保留世界 `terrain` blob**（overlay 世界读走合成、blob 成惰性死数据）而非设计原文的「世界不再存整块 blob」。
  理由：不 null blob → 天然不与 `#migrateSceneTerrainBlobs`（`WHERE terrain IS NULL`）打架、无「base 消失致地形全丢」边界。
  存储非诉求、正确/安全优先。存储优化（真删 blob）留作后续。
- **版本用 `base_version + edit_count` 纯函数式**（非 write-on-read 的 reconcile 计数器），省掉热读路径的写。
- `characters/items` 实例层 base+overlay **明确 OUT-of-scope**（`character_defs` 已是全局共享层够用），未来另开 plan。

**未验证（留真机 playtest）**：客户端在真机上「作者改 base 地形后孩子重进世界拉到新地形」的端到端只在 server 侧
单测验证；device 级需导 APK/iOS 后开麦跑一遍（同 P2 的 homes 真机验证一样待办）。客户端代码零改（GET /terrain 合成 +
`x-terrain-version` 契约不变）。
