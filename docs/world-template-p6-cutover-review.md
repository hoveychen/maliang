# P6 现网切换评审：`default` 单世界 → 每人一世界（唯一破坏性步骤）

> 世界模板架构 v2 的最后一步（设计 `world-template-instancing-design.md` §8 P6）。
> P1–P5 已合本地 main（均未 push/未部署）。**本文是评审稿，不含任何代码改动**——目的是让老板在动手前
> 拍板迁移策略、灰度与回滚。执行须另起 worktree、单独走验收门。

## 0. 一句话

现网所有孩子的档案现在**挤在同一个 `default` 世界**里；P6 要把它按 playerId 拆成各自的 `w_<playerId>`。
难点**不在**「怎么建新世界」（P2 的 `getOrCreateMyWorld` 已能建），而在**「default 里哪些数据属于哪个孩子」
——有些表天生带 playerId 分区（好拆），有些是世界级共享、零玩家归属（拆起来有歧义）**。

## 0.1 老板澄清（决定性，2026-07-20）——P6 大幅降级

> **老板：「不存在活跃玩家。现在还在开发。你完全清掉玩家数据都没问题。（但是角色千万别清了）」**

这抽掉了 P6 的**整个复杂度来源**——本文 §1–§6 大量篇幅都在解「怎么无损保护存量孩子档」。**没有真实存量档要保护**，
于是：

- **玩家数据（A 类：钱包/委托/剧情进度/已发现/位置/背包）可直接清空**——它们是开发期测试数据，授权清掉。
  → 逐 player 拆分、灰度、复杂回滚**全部不需要**。
- **角色（`characters` 实例 + `character_defs` 定义）绝不能清**——这是硬约束。恰好架构就是这么设计的：default
  的角色内容**提升成 template 的共享放置 + 共享定义**（`ensureTemplateWorld`，已有），克隆时引用不变，天然保住。
- B/C 类的造物/地形归属难题**一并作废**——没有存量玩家世界要拆。

**降级后的 P6（见 §4′）几乎零代码、零破坏性**：部署 P1–P5 + 客户端铺 P3 → default 退居为 template 底，
新玩家各自建世界。**唯一还需谨慎的破坏性动作**是「部署会触发 prod 角色表结构迁移（P2 复合 PK + 拆定义/实例）」
——这正是**动角色表**的操作，而老板要求角色别丢。该迁移是**重构表结构、不删角色数据**，但必须先在 prod 快照的
本地副本上验证无损再部署（见 §6）。

> 下方 §1–§3 的数据分区坐实仍是准确的架构记录，保留备查；§4 起的「保护存量档」策略已被 §4′ 取代。

## 1. 现状坐实（读码，`server/src/persistence.ts` `#initSchema`）

把 `default` 世界里的数据按「能否按 playerId 干净拆分」分三类：

### A. 天生按 `(world_id, player_id)` 分区 —— 干净可拆
逐行把 `world_id='default'` 改写成 `world_id='w_<player_id>'` 即可，零歧义：

| 表 | 主键 | 内容 |
|---|---|---|
| `wallets` | `(world_id, player_id)` | 小红花/集邮/爱心钱包 |
| `player_tasks` | `(world_id, player_id)` | 当前委托链 |
| `story_progress` | `(world_id, player_id)` | M2 章回剧情进度 |
| `player_discovered` | `(world_id, player_id)` | 已发现玩法（「已发现不再提」） |
| `player_positions` | `(world_id, scene_id, player_id)` | 玩家位置 |
| `bag` | `(world_id, player_id, item_id)` | 背包持有计数 |

### B. 世界级放置层（玩家造物 characters 实例 / items）—— **不按创建者拆，随放置层整份快照**

> **老板拍板纠正（关键）：`creatorPlayerId` 只是「作者」（谁造的），不代表 ownership（谁现在拥有）。**
> 孩子会把自己造的东西**送给朋友**——所有权是流转的，而 `creatorPlayerId` 永远停在原作者。所以**绝不能**
> 用 `creatorPlayerId` 判断造物归谁、据此拆分。它保留原用途（B3 起名的「是不是本人造的」判据，`types.ts:367`），
> P6 拆分**不碰它**。

那 default 里已摆放的玩家造物到底归谁？现实是：**在 default 共享世界里，摆在世界地形上的造物 ownership
本就没被建模**——它们摆在共享空间、被共享地形矩阵的 palette 引用。真正 per-player 的「持有」只有 `bag`（A 类，
已能按 player 拆）。

结论（由 §1.C 老板定论推出，见 ⚠️）：**摆在世界里的造物随放置层整份快照复制**——不猜归属、不丢数据：

| 表 | P6 处理 |
|---|---|
| `characters`（实例） | 作者内容（村民/story/点点）是模板共享放置，每人一份（P5/clone 已能补）；玩家造的角色随放置层快照，每人一份 |
| `items` | 玩家语音造物随放置层快照复制（**必须**：地形矩阵 palette 引用它的 id，地形每人一份则它必须随之，否则引用悬空）；内置物是代码常量不落库、不迁 |
| `memories` / `chat_turns` | 按 `character_id` 跟随角色 |

### C. 世界级地形（scenes terrain）—— **老板定论：每个孩子独立一份**

> **老板拍板：「C 一定是每个孩子有自己的一份地形，毋庸置疑。」**

`scenes` 按 `(world_id, scene_id)`、无 player_id——default 里所有孩子编辑的是同一份共享地形。**不试图按孩子还原**
（本就无归属信息），直接**整份快照**：每个新世界拿一份 default 当前地形的完整副本，之后各自独立编辑。
（即设计 §4.1-3 的选项①。）因地形 palette 引用 items，B 类的摆放造物必须随此快照一起复制（见上表）。

## 2. 核心难点小结（老板两条纠正后，B/C 已收敛）

1. **A 类干净**：机械改 world_id 即可（含 `bag` = 真正的 per-player 持有）。
2. **B 类不再是缺口**：不按 `creatorPlayerId` 拆（它是作者非 owner）；摆在世界里的造物随放置层整份快照，
   每人一份。存量无归属造物的悬案**随之消失**（根本不依赖归属）。
3. **C 类不再有歧义**：老板定论每人一份地形 = 整份快照。
4. **真正剩下的变量：default 几个活跃玩家**。若实际单孩子单平板，P6 近乎「把 default 克隆成那一个
   `w_<player>` + 迁其 A 类档案」。**这决定工作量，必须先量（step 0）。**

**归约后的 P6 本质**：对 default 里每个（有 A 类档案的）player —— 建 `w_<player>`（自动铺模板作者放置 + 点点）
→ 复制 default 放置层快照（地形 + 摆放的 items + 玩家造 characters 实例）→ 迁该 player 的 A 类档案行。

## 3. Step 0（执行前置，非设计阶段可跳过）：实测 prod `default` 构成

不量就动手＝拿存量孩子档案赌。执行 P6 前先在 prod 只读量出（走 `/admin/backup` 拉快照到本地库离线查，
或加一个只读 `/admin/world-stats` 端点——**只读，不改 prod**）：

- default 世界里 **distinct player_id 数**（A 类各表 union）——**这是唯一决定工作量的数**：单玩家 → 近乎克隆重命名；多玩家 → 逐 player 拆。
- 各 scene 的 terrain 是否被改过（`terrain_version > 0`）——确认地形快照确有内容要带。

（不再需要「数无归属造物」——老板纠正后 P6 不按 `creatorPlayerId` 拆，放置层整份快照，归属不参与。）

**这两个数出来之前，下面的策略选择停在纸面。**

## 4′. 降级后的 P6（老板澄清「无存量玩家」后，取代 §4–§6 的存量保护策略）

无真实存量档要保护 → P6 = **让 default 退居为 template 底、新玩家各自建世界**，几乎零代码：

1. **提升 template**：`ensureTemplateWorld()` 把 default 的角色内容（村民/story/点点）复制成 template 的共享放置
   （不删 default 一个字节，角色定义共享引用）。P2 已实现，首次 `getOrCreateMyWorld` 自动触发，无需新代码。
2. **客户端各自建世界**：P3 已把 bootstrap 切到 `get_my_world(playerId)`；新装 P3 APK 的设备进来即建自己的
   `w_<player>`（自动铺模板作者放置 + 点点）。无需新代码。
3. **（可选）清开发期玩家数据**：default 里的 A 类行（钱包/委托/进度/发现/位置/背包）是开发期测试数据，
   老板授权可清。**清理边界硬约束：只删 A 类那 6 张按 `(world_id,player_id)` 分区的表里 `world_id='default'`
   的行；`characters` / `character_defs` / `items` / `scenes` 一律不碰**（角色/造物/地形保住）。
   实现方式二选一，执行前定：(a) 加一个 admin 端点 `POST /admin/worlds/default/purge-player-data`（dry-run 默认，
   `apply=true` 才真删，仿现有 `/admin/integrity/fix` 的安全姿势）；(b) 对 prod 快照的本地副本手跑 SQL、验证后
   再对 prod 执行。**建议 (a)**：可复用、可 dry-run、有审计日志。若嫌孤儿数据无害（default 不再接客），
   这步甚至可跳过。
4. **default 是否彻底退役**：切换后新客户端都走 `w_<player>`，default 只作 template 的内容来源。可保留（无害）
   或后续单独清理，非 P6 必须。

**降级后 P6 的真实工作量**：主要是「部署 P1–P5 + 铺 P3 APK」+ 可选的 (3) 清理端点。破坏性只剩 §6 的 prod
角色表结构迁移（部署即触发），那条**必须**照做验证。灰度/回滚（§5/§6 前半）因无存量档而大幅弱化。

---

## 4. 迁移策略（两选一 + 边角安置）〔历史稿：为「有存量玩家」设计，已被 §4′ 取代，保留备查〕

每个孩子的 `w_<player>` 内容 = **模板作者放置 + 点点**（`getOrCreateMyWorld` 自动铺）
**+ default 放置层快照**（地形 + 摆放的 items + 玩家造 characters 实例）**+ 该 player 的 A 类档案**。

### 策略甲：批量拆分（一次性，停机/低峰窗口）
遍历 default 的 A 类各表得到 player 集合；对每个 player：`getOrCreateMyWorld` 建世界（自动铺模板作者放置），
复制 default 放置层快照（地形 + items + 玩家造 characters），再把该 player 的 A 类行改写 world_id 迁入。
全程 per-player 事务 + 断点续跑。
- 优点：切换点单一、可控、切完即干净。
- 缺点：需要一个明确的迁移执行时机 + 停写窗口。

### 策略乙：懒迁移（首次进入触发）
保留 default；玩家设备（装了 P3 APK）首次以 `w_<playerId>` 进入时，若该世界不存在，除铺模板放置外
**再从 default 复制放置层快照 + 搬这个 playerId 的 A 类档案**。
- 优点：无停机、自然灰度（一个孩子上新 APK 才迁一个）。
- 缺点：default 长期悬着；「搬一次」的幂等/中断恢复要仔细。

**倾向**：先量 step 0。若**单/极少玩家** → 策略甲（一把梭，最简单）。若**多玩家且要平滑** → 策略乙
（借 P3 APK 铺开的节奏自然灰度）。

### 边角安置
1. **作者共享内容**（村民/story 角色/点点）：不是「谁的」——它们是模板放置，每个新世界经 clone/P5 补各一份。
   迁移时**不要**把 default 里的作者角色实例「分给某个孩子」，那会串味（放置层快照要**排除**作者内容，
   只带玩家造物；作者内容走模板铺设那条路）。
2. **摆在世界里的玩家造物**（characters/items）：随放置层快照，每人一份（老板：不按 creator 归属，creator≠owner）。
   ⚠️ 这带来一个诚实的副作用——若 default 现在多孩子共处、地上摆着 A 造 B 也造的东西，**拆后每个孩子的
   世界都会拿到全部这些造物各一份**（快照即复制）。对单/少玩家无感；多玩家则每人世界初始会「继承」大家
   共同摆过的东西。**这是否可接受，需老板确认**（替代：只带该 player `bag` 里的 + 无归属摆放归档，但那样
   地形 palette 引用会悬空，得连带清 palette，工程更重）。
3. **地形**：老板定论——每个新世界一份 default 当前地形的整份快照。
4. **匿名 playerId**（`types.ts:111` 老客户端/直连调试的匿名键）：这些不是真孩子，归 `legacy` 或直接不迁。
5. **点点**：每个新世界靠 `getOrCreateMyWorld` 的 makeFairy 保证有一只，不从 default 搬。

## 5. 灰度

- 策略乙天然灰度：APK 铺开进度 = 迁移进度。**先在测试沙箱（P4 的 `sandbox_`）跑一遍整册验隔离**，
  再挑 1 台真机（一个孩子）升 P3 APK，观察其 `w_<player>` 数据完整（钱包/委托/造物/剧情进度/地形都在），
  确认无误再扩。
- 策略甲：先对 prod 快照在**本地/staging 库**跑完整迁移脚本 + 全量校验（拆后各世界数据 = 拆前该玩家在
  default 的数据），通过再对 prod 执行。

## 6. 回滚预案

- **切换前必做全量备份**（`VACUUM INTO` 快照，见记忆 `data-backup-and-asset-storage`）——这是回滚的地板。
- 策略甲：迁移脚本**只增不删原始 default 行**（把数据**复制**进新世界，default 原样留着），验收通过后再另跑
  一个显式的 `cleanup default` 步骤。出问题＝把客户端 bootstrap 指回 default（`MALIANG_WORLD` 或回退 P3
  客户端），default 数据没动，即时回滚。
- 策略乙：default 始终不动，回滚 = 停发 P3 APK / 客户端 fallback 到 default。
- ⚠️ **P2 复合 PK 迁移一并随下次 deploy 落 prod**（memory 标注的未部署风险项）：P6 部署即触发 prod 角色表
  结构重建，虽幂等+测试覆盖重开，但**回滚不了 schema**——务必在备份之后、且先在 prod 快照的本地副本上
  验证一次 `#migrateCharactersCompositePk` + `#migrateCharactersToDefsInstances` 在**真实 prod 数据**上无损。

## 7. 客户端联动（已在 P3/P4 就位，P6 不新增客户端代码）

- P3 客户端 bootstrap 已走 `get_bootstrap_world(playerId)`：`MALIANG_WORLD` 覆盖 > `get_my_world`。
- **装 P3 APK 到真机 = 该设备触发切换**（它会去要 `w_<playerId>` 而非 default）。故 **P6 拍板前，别把 P3
  客户端铺到孩子的平板**——否则设备会先于服务端策略就绪去建空的 `w_<player>`，与存量 default 档脱节。
  （这条 memory `world-template-instancing-p2p4` 已记，P6 执行时复核。）

## 8. 验收标准（执行 P6 时对照）

1. step 0 两个数已量、策略与边角安置（尤其 §4 边角 2 的多玩家副作用）已经老板拍板。
2. 切换前 prod 全量备份已生成、且在本地副本上验证过 P2 迁移在真实数据上无损。
3. 拆后抽样校验：任取一个存量玩家，其新世界的钱包/委托/剧情进度/已发现/位置/背包
   **= 拆前他在 default 的那份**（逐表对拍）；作者共享内容各世界各一份、不串味；地形快照在、palette 不悬空。
4. 回滚演练过一次（把 bootstrap 指回 default 能恢复）。
5. 全套 server 测试 + tsc 绿；沙箱整册跑通验隔离。

## 9. 待老板拍板的开放问题

1. **prod default 实际几个活跃玩家？**（step 0，决定甲/乙、也决定边角 2 的副作用严不严重）
2. **迁移策略甲（一次性）还是乙（懒迁移随 APK）？**
3. **§4 边角 2 的副作用可接受吗**：多玩家时，放置层整份快照会让每个孩子的世界初始都继承「大家共同摆过的
   造物」各一份。接受（简单、不丢、不串主）？还是要「只带自己 bag 的 + 连带清悬空 palette」（工程更重）？
4. 是否要为 step 0 加一个只读 `/admin/world-stats` 端点（vs 拉全量 backup 离线查）？

（原「无归属造物怎么安置」「地形整份 vs 模板底」两问已由老板纠正/定论解决，不再是开放项。）
