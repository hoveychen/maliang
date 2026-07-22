# 物品定义全局共享设计

状态：**P1 设计，待老板 review**。老板要求：**所有物品定义全世界共享**——创造一个物品 = 全世界多了一个新物品，
孩子拿到的是这个物品的**一个引用**。与角色的 `character_defs`(全局定义) + 实例(per-world) 同构。

## 1. 需求（老板明确要求，非推断）

- **物品定义 = 全局共享层**（像 `character_defs` / builtin）。任何世界都能按 id 解析出任何物品的定义。
- **创造物品 = 全局新增一个物品定义**；孩子的世界只持有**引用**（摆放在地形 / 背包里，按 id 引用）。
- 底层动机与游戏「架构思维」种子一致（`docs/kids-thinking-*`：同一块积木能用很多地方=复用）；
  也补齐 base+overlay 架构的对称性（角色 def 已全局共享，物品 def 也该如此）。

## 2. 现状（subagent 逐行核 + 我复核）

- `items` 表：`id TEXT PRIMARY KEY, world_id TEXT NOT NULL, data`（`persistence.ts:711-716`）。
  **PK 是 `id` 单列**（已全局唯一）；world_id 只是个过滤列 + 创造来源。
- 物品 id = `randomUUID()`（`server.ts:2340/2401/2478` 经 `creationItemDef`）→ **全局唯一，跨世界不可能撞**。
- `getItemDef(worldId, id)`（`persistence.ts:1409-1416`）：先 builtin，再 `WHERE id=? AND world_id=?` ← **world-scoped 就卡在这个 AND**。
- `itemResolver(worldId)`（`:1425-1427`）= 闭包 worldId 的 getItemDef。调用点：`server.ts:549`(validateTerrainItems)、
  `1691`、`terrain_edit.ts:169`(tile 编辑)、`debug_api.ts:251`、`persistence.ts:1502`(迁移)。
- `listWorldItems(worldId)`（`:1419-1422`）：`WHERE world_id=?`，喂给 scene_entered/world_info 的 `items:[...BUILTIN, ...listWorldItems]`。
- 创造流：`upsertItem(def)`(world-scoped) → `bagAdd` → `item_created`；摆放走 `item_place` → `editSceneTerrain`(terrain itemRef) + `bagTake`。
- 背包 `bag(world_id, player_id, item_id, count)`（`:719-725`）、地形 palette itemRef——**都只按 id 引用物品**（已是"引用层"）。
- **clone 不复制 items**（`cloneWorldInstances` 只 characters+scenes，`:1103-1120`）。
  ★subagent 点出的 crux：克隆场景的 palette 若引用了 world-scoped 物品 id，目标世界解析不出该 def——正是本次要修的。
- `ItemDef.worldId`（`types.ts:336`）：null=builtin，非空=某世界造物。**唯一让 def world-scoped 的字段**（+ provenance `creatorPlayerId`/`recipient`）。

## 3. 目标模型：全局 item 注册表 + per-world 引用

- **定义层（全局）**：物品 def 按 id 全局解析（builtin + items 表任一行，**不再按 world_id 过滤**）。
  因 id 是全局唯一 PK，`SELECT WHERE id=?` 无歧义。
- **引用层（per-world，不变）**：摆放=地形 palette itemRef；持有=bag——都只存 id 引用。孩子"拿到引用"就是这层。
- **world_id 变成"创造来源"记账**（谁先造的），不再是解析过滤条件。**无需 schema/数据迁移**（行照留、PK 是 id、读时不再过滤）。

## 4. 改动点（小、集中在读路径）

1. **`getItemDef(id)` 全局化**：去掉 `AND world_id=?` → `SELECT ... WHERE id=?`。builtin 优先不变。
   `itemResolver` 变成全局（worldId 参数保留兼容调用点、但解析不再用它）。
   → 这是让 def"全局共享"的**承重改动**：任何世界引用任一物品 id 都能解析。crux 自动修（克隆场景引用的造物 def 全局可解析）。
2. **scene_entered / world_info 的 `items[]` 载荷**：从 `listWorldItems(worldId)`（本世界**造的**）改为本世界**引用到的**物品
   （该世界各场景 terrain palette 的 id ∪ 该世界 bag 的 id），按全局注册表解析。
   - 保证客户端拿到它要**渲染/持有**的每个 def，含未来跨世界引用（好友共玩/作者在 template 摆造物）。
   - 今天"造的==引用的"故行为等价；改成引用制是为了"全局共享"真正成立。
3. **`upsertItem`**：基本不动（创造仍记 creating world_id 作 provenance；builtin id 仍拒）。
4. **迁移**：无需数据迁移。存量 w_b825 的 2 个造物（小房子/火箭）读时即全局可解析。

## 5. 不会发生的事（澄清"共享"不等于"泄漏"）

全局解析 def **不等于**把物品塞进别人世界。孩子 B 的世界只**引用**（摆放/背包）B 自己的物品(+builtin+克隆场景物)，
故 scene_entered 只发 B 引用到的 def，A 的造物 def 虽全局可解析但**不被 B 引用 → 不下发、不渲染**。
"共享"体现在：def 存在于全局、任何世界**若引用**即可解析——为未来好友共玩/作者摆造物铺路，今天无视觉变化。

## 6. 风险

- **低**：核心是 `getItemDef` 去掉一个 world 过滤（解析变成超集，只会解析出更多 id、绝不更少）→ terrain 校验/解码
  （`server.ts:549`/`terrain_edit.ts:169`）仍正确（校验的是"id 存在"，全局找得更全）。
- 载荷改动（items[] 引用制）碰 scene_entered——需 decode 该场景 terrain 取 palette（scene 入场不频繁，可接受）。
- 客户端零改（仍收 `items[]` def 列表，不关心服务端从哪取）。

## 7. 验收（可机器验证）

1. 全局解析：world A 造的物品 id，在 world B 用 `getItemDef(id)`/itemResolver 能解析出同一 def。
2. 无泄漏：world B 的 scene_entered `items[]` 只含 B 引用到的物品（+builtin），不含 A 的造物。
3. 克隆场景 crux：一个 world-scoped 物品被某场景 palette 引用，克隆到新世界后仍能解析（def 全局）。
4. 引用层不变：bag/terrain 仍按 id 引用；孩子造物→摆放→背包链路照常。
5. `cd server && npm test` + `tsc --noEmit` + headless 绿；客户端零改。

## 8. 薄切分档

- **P2**：`getItemDef`/`itemResolver` 全局化（去 world 过滤）+ 单测（跨世界解析）。承重改动，直接让 def 全局共享。
- **P3**：scene_entered/world_info `items[]` 改引用制（本世界 palette∪bag 的 id 全局解析）+ 单测（无泄漏 + 引用到的都在）。
- **P4**：收口 + 全绿 + merge + 部署（VACUUM 备份；无数据迁移）。
