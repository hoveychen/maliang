# 角色实例层 base+overlay 设计评估

状态：**老板 2026-07-22 拍板路线 A（真 base+overlay），落地模型见 §9，进入实现（plan `char-instance-overlay`）。**
（原为评估草案，评估把角色实例层从「快照拷贝」换成 base+overlay 是否值得——见 §1-8；老板选了最彻底的 A。）
背景：本次评估源于 `world = template base + overlay` 重构（见 `template-overlay-arch-design.md`，已上线）——那次把
**场景地形 + 作者字段(pois/portals/homes)** 换成了 base+overlay，但**角色/物品实例层明确划在 OUT**。评估这一层要不要跟上。

## 1. 为什么考虑改（钉住 demonstrated 痛点，不发明需求）

**已发生、非假想的痛点**（本次 game-pilot 验证时实测，见 memory `village-homes-seeded-template-propagation`）：
- **存量旧世界缺整册故事**：prod 上 `w_c6a2` 缺《白雪公主》全部 8 角色；`w_2375` 缺 oz + 白雪 + 龟兔（13 角色）。
- **角色卡在旧场景**：`w_b825`/`w_c6a2` 的 7 村民 + 三只小猪 4 口停在旧 `village` 场景（主场景已是 `village_forest`）
  → 在主场景**压根渲染不出来**。同一只猪大哥：template 在 `village_forest`，w_b825 在 `village`（老快照）。
- **根因**：角色实例是**快照拷贝 + 单向 additive 补丁**——世界创建时整份拷 template 的角色行（含位置/场景），
  之后独立；作者事后改 template 的角色（挪场景/挪位/加新册）**不传播**给已存在世界（`#migrateWorldPlacements`
  只 ADD 世界还没有的角色、从不 UPDATE 已有的，且靠进世界时触发 + templateVersion 门控，漏一个条件就补不全）。

**新世界不受影响**（已验证）：新世界克隆当前 template → 27 角色全在、场景全对。所以这纯粹是**存量世界**的传播缺口。

**老板的直觉（本次评估的由来）**：角色的「位置/存在」本该也从一个 template 派生（读时合成），
而不是各世界存一份互不相通的快照。

## 2. 现状：角色三层存储（逐行核过 persistence.ts + prod 实测）

| 层 | 存哪 | 谁改 | 传播? |
|---|---|---|---|
| **定义**（name/长相/voiceId/abilities/storyArchetype） | `character_defs`(def_id, data) 全局一份 | 作者 | ✅ 读时按 defId 取，改一次全世界生效（已是共享层） |
| **实例**（position/sceneId/state/behaviorScript/memory/chatHistory/relationships/taskChain/resident） | `characters`(world_id, id, data) **每世界整份** | 建世界克隆 + 运行时玩法 | ❌ 快照拷贝后独立，作者改 template 不传播 |

- `getCharacter` = 合并 def + 实例 → 完整 Character；`saveCharacter` = 拆回 def + 实例。
- `cloneWorldInstances(template, 新世界)`：把 template 每条 `characters.data` 整份拷进新世界（只换 worldId、保 defId），
  含 position/sceneId → **快照**。
- `#migrateWorldPlacements`：additive，按实例 id 查重，只补世界缺的、绝不改已有 → 作者挪位/换场景不传播。

## 3. 核心难点：位置是 wander 高频漂移的，不能当 diff（prod 实测确认）

这是决定「能不能像地形那样简单 diff」的关键约束，已实测：同场景下角色的 live 位置持续漂移——
`小红帽` template (25,18) vs w_b825 (25,14)、`兔子` (22,18) vs (14,12)。角色 `behaviorScript` 带 `wander`，
每几秒改一次 position 并持久化。

**推论**：不能像地形 tile 那样「世界值 ≠ base 值就当孩子编辑（overlay）」。因为角色位置**几乎恒定在漂**，
naive diff 会让每个角色的 overlay 恒非空 → 传播收益归零，而且迁移时**分不清**哪是孩子有意挪的、哪是 wander 随机漂的。

**所以 base+overlay 对角色不能整份套用**，必须区分「作者摆放元数据」与「运行时可变态」：

| 字段 | 归类 | base+overlay? |
|---|---|---|
| **存在**（这个世界有没有这条实例） | 作者摆放 | ✅ base（新故事角色自动"在"于所有世界） |
| **sceneId**（角色属于哪个场景） | 作者摆放（孩子几乎不跨场景挪 NPC） | ✅ base（追平 village→village_forest） |
| **authored home/spawn tile**（作者摆的初始位） | 作者摆放 | ⚠️ 候选 base（但与 live position 冲突，见下） |
| **live position**（wander/走动后的当前位） | 运行时 | ❌ 每世界存（漂移态，不传播） |
| **memory / chatHistory / relationships** | 运行时（每孩子） | ❌ 每世界存 |
| **taskChain 进度 / resident（入住）** | 运行时（孩子玩出来的） | ❌ 每世界存（孩子 agency，必须保） |

→ **可行的核心模型**：角色的**「存在 + sceneId(+authored home)」读时从 template base 合成**，
**可变态(live position/memory/chat/relationships/task/resident)仍每世界存**（overlay=世界对该角色的运行时态）。
这恰好命中 demonstrated 痛点（新故事传播 + 场景追平），又不碰高频漂移的 position。

## 4. 待定决策点（留给 review）

1. **薄切范围**：是否**只做「存在 + sceneId」base+overlay**（最薄、直击痛点），authored home tile / position 都不碰？
   还是连 authored 初始位也 base 化（复杂：要把「初始位」和「live 位」拆成两个字段）？
2. **冲突/孩子 agency**：孩子把某 NPC「留下/入住/挪去别场景」算 overlay 覆盖 base——「孩子碰过」用什么标记？
   （地形是 tile-diff 自带；角色需要一个 per-(world,char) 的 override 标记，否则 wander 漂移会被误判成孩子编辑。）
3. **迁移存量世界（最危险）**：现有世界的实例已 diverge。
   - 存在缺口（w_c6a2 缺白雪）：base 合成天然补上——低风险。
   - 场景不一致（猪在 village）：迁移要不要把 sceneId 追平 base？追平=修复；但若某孩子**有意**把 NPC 挪去别场景，
     追平会冲掉——不过现状根本没有「孩子跨场景挪 NPC」的入口（待 §current 确认），故大概率可无脑追平。
   - live position：保留世界现值（不动），只补「存在 + 场景」。
4. **读路径改造成本**：`listCharacters`/`getCharacter` 要像 `listScenes` 那样改成「template base 角色集 ⊕ 世界 overrides」
   合成——这是热路径（每次进世界、每次对话解析都读角色），风险与工作量都在这。

## 5. 薄切分档（Rule 6：先证最薄一条竖切）

- **P-A（最薄，直击痛点，低风险）**：只让**「存在 + sceneId」**从 template base 派生——
  存量世界读角色集时，template 有、世界还没 override 的角色，用 def+authored 合成补上；sceneId 一律取自 template base
  （孩子无跨场景挪 NPC 入口时）。**这一档就修好「旧世界缺故事 + 猪卡 village」**，且不碰 position/memory/task。
- **P-B（野心档，高风险）**：authored 初始位也 base 化（拆 spawn vs live position），作者挪位能流到没被孩子动过的世界。
- **OUT**：memory/chat/relationships/taskChain/live position——本就该每世界独立，不进 base+overlay。

## 6. 风险

- **热路径**：角色读写是最热的路径之一（位置流、wander、对话意图解析、stage 演出、故事导演）。改读模型风险高于地形。
- **可变态语义微妙**：wander 漂移 vs 孩子有意改，必须靠显式 override 标记区分，否则传播失效或冲掉孩子改动。
- **迁移不可逆**：碰存量 live 世界的角色行。必须 VACUUM 备份 + 幂等 + 可证无损（存在/场景追平不动可变态）。
- **收益 vs 成本**：demonstrated 痛点只在**存量旧世界**（新世界已全对）。若这些旧世界是测试世界、真玩家都是新克隆，
  收益有限——可能「重克隆旧世界」比「改架构」更划算。**这是 review 要权衡的第一问。**

## 7. 三条路线（review 选一，成本/风险递增）

demonstrated 痛点只在**存量旧世界**（新世界已全对）。修法有三档，ROI 差别很大：

### 路线 C —— 一次性数据修复（最便宜，不改架构）★成本最低
写个一次性迁移/admin 脚本：遍历每个存量世界，(1) 把 template 有、世界缺的 story 角色**补进来**（用 def+authored placement），
(2) 把已存在实例的 **sceneId 追平 template**（已证 sceneId 是 authored-only、孩子无跨场景挪 NPC 入口 → 无损）。
不动 position/memory/task/resident。**这就修好「旧世界缺故事 + 猪卡 village」**，不碰热读路径。
缺点：治标——**将来**作者再改 template 角色，仍不自动传播（除非每次都手动跑脚本 / bump+重进）。

### 路线 B —— 修好「自动传播」机制（中等，仍是 snapshot+additive）
在 C 的一次性修复之上，把 `#migrateWorldPlacements` 从「只 ADD 缺的」升级为「ADD 缺的 + UPDATE 已存在实例的
**authored-only 字段**（sceneId，也许 authored home）」，并让 `POST /admin/worlds/:id/seed-story` **自动 bump 版本**
（现在要手动调 `POST /admin/template/bump-version`，`server.ts:1238` 是唯一调用点，漏调就是这次缺故事的直接原因之一）。
这样作者加/挪 template 角色，存量世界下次进世界就补齐/追平。
缺点：仍是「进世界时触发」的推模型（没进世界的世界不更新）、仍非读时合成；但比路线 A 风险低得多。

### 路线 A —— 真 base+overlay（最彻底，最高风险）
`listCharacters`/`getCharacter` 改成「template base 角色集 ⊕ 世界 override」读时合成（对齐 scenes 的做法）：
存在 + sceneId 来自 base、可变态（position/memory/chat/relationships/task/resident）来自世界 overlay，
孩子「碰过」的角色用显式 override 标记盖过 base。作者改 template 立即对所有世界读时生效（真传播）。
缺点：碰**最热的读路径**（每次进世界/对话解析/stage 都读角色）、要引入 per-(world,char) override 标记、
可变态 overlay 语义微妙（wander 漂移不能算编辑）、迁移最复杂。

**倾向建议**：先做**路线 C**（一次性修复，直击 demonstrated 痛点、当天可交付、低风险），
并顺手做**路线 B 的 auto-bump**（seed-story 自动 bump，堵住"漏 bump"这个复发源）。
**路线 A 暂不做**——它是「将来作者频繁改 template 角色」才值的投资，而现在没有这个 demonstrated 频率；
且真玩家都在新克隆世界（已全对）。**这是 review 要拍的第一问：旧世界值不值得投 A 的架构成本，还是 C/B 够了。**

## 8. 确认过的代码地图（file:line，subagent 核 + 我复核）

- **实例 vs 定义分层**：`position`/`sceneId`/`state`/`behaviorScript`/`memory`/`chatHistory`/`relationships`/`taskChain`/
  `resident` 在 INSTANCE（`characters` 表，`types.ts:517-533`）；`name`/长相/`abilities`/`storyArchetype` 在 DEF
  （`character_defs`，`types.ts:496-507`，共享）。`resident` 明确在实例（`types.ts:532`），由 `storyRole.resident` 派生。
- **additive 只加不改**：`#migrateWorldPlacements`（`persistence.ts:1266-1294`）`if(existingIds.has(inst.id)) continue`
  （`:1281`）只补缺的、从不 UPDATE 已有；docstring `:1260-1261` 明说「挪已存在 NPC 不传播」。gate=`templateVersion`
  （`:1268`），只在 `getOrCreateMyWorld`（`server.ts:305`→`persistence.ts:1204`）世界已存在时跑。
- **bump 是唯一开关且唯一调用点**：`bumpTemplateVersion`（`persistence.ts:1250-1255`）只被
  `POST /admin/template/bump-version`（`server.ts:1238-1241`）调用。作者 seed 后漏调 = 不传播（本次缺故事直接原因之一）。
- **sceneId 是 authored-only（关键！base 化无冲突）**：运行时写 sceneId 只有 `setCharacterTile`
  （`persistence.ts:1985-1993`）——且带 scene-drag-guard（`:1988`「只在传入 sceneId == 当前场景才写」）→ **不能跨场景**；
  跨场景改 sceneId 只有 admin PATCH（`server.ts:432`）。**孩子没有跨场景挪 NPC 的入口** → 把 sceneId 追平 template 无损。
- **position 是 client wander 高频漂移**：wander 是 `behaviorScript` 命令（seed 时写，`story_seed.ts:60`），
  **客户端执行**并经 `positions_report`（`server.ts:3191`→`setCharacterTile`）回报持久化；服务端无 wander 位移逻辑。
  → position 恒漂，不能当 diff（§3 实测印证）。
- **seed 路径**：`seedStoryCharacters`（`story_seed.ts:24-76`）经 `POST /admin/worlds/:id/seed-story/:bookId`
  （`server.ts:1223-1230`，作者传 `:id='template'`）；position 取自 book（`story_seed.ts:61`）、sceneId=`book.sceneId`（`:62`）。
- **克隆是快照**：`cloneWorldInstances`（`persistence.ts:1103-1120`）整份拷 position/sceneId/state（`:1108-1111`）。

## 9. 路线 A 落地模型（老板拍板，实现依据）

**核心：读路径合成，写路径基本不动**（对齐 P3「保留 blob 换低风险」的取舍——降低碰最热路径的风险）。

### 9.1 读时合成
`listCharacters`/`getCharacter` = **template base 花名册 ⊕ 世界 overlay**：
- **base**（template 的实例行）提供：**存在**、identity(defId→定义)、**sceneId**、authored position（世界无 live 值时的落位）、behaviorScript。
- **世界 overlay**（世界自己的实例行）提供：**可变态**——live position、memory、chatHistory、relationships、taskChain、resident。
- **合成规则**（按 char id）：
  - 模板有该 char：identity + sceneId **取 base**；可变态取世界行（有则用，无则 base 默认）；position 取世界 live（有则用），否则 base authored。
  - 世界独有该 char（孩子造物 / 点点仙子，不在模板）：整行用世界自己的。
- `listCharacters(world)` = 模板花名册（每个 ⊕ 该世界可变态）∪ 世界独有 char。scene 过滤用**合成后的 sceneId**（= base 的）。

### 9.2 直接收益
- **存在传播**：新模板 char 自动"在"所有存量世界（读时从 base 合成，无需 clone/additive）。→ 修 w_c6a2 缺白雪。
- **sceneId 追平**：模板 char 的 sceneId 恒取 base（authored-only、孩子无跨场景挪 NPC 入口 → 无冲突）。→ 修猪卡 village。
- **作者改 template**（挪场景 / 加角色）→ 所有世界下次读**立即反映**，真传播。

### 9.3 写路径不动（关键低风险点）
`saveCharacter` / `setCharacterTile` 仍写世界整行。世界行的 identity/sceneId 成"死字段"（读时被 base 盖），
可变态字段照常被读。这与 P3 保留世界 terrain blob 同理——不动写、只在读合成，避免碰写路径的连锁风险。

### 9.4 无需数据迁移（部署即修）
存量世界的 gap（缺故事 / 错场景）在**读路径改了那一刻**自动修复：base 补齐存在、base 盖 sceneId、世界可变态保留。
**不动一字节世界数据**（VACUUM 备份仍做，防万一）。这是路线 A 相对 C/B 的一大优势：修复是结构性的、自动的。

### 9.5 clone/additive 变冗余但保留（本轮不动）
新世界仍 `cloneWorldInstances` 克隆模板 char（读合成对它们是 no-op，因世界行 == base）；`#migrateWorldPlacements`
additive 仍在（读合成让它多余，但无害）。**本轮不拆**（降风险）；未来可精简成"新世界零 char 行、全靠读合成"。

### 9.6 override 标记：MVP 不需要
- **sceneId**：base 恒胜、无孩子编辑入口 → 无需标记。
- **存在**：孩子无删 NPC 入口 → base 恒提供存在、无需"已删除"标记（世界独有 char 靠"世界有行、模板无"隐式区分）。
- **position**：世界有 live 值就用、否则 base authored——wander 一回报世界就有行，隐式区分，无需 touched 标记。
- （若将来要"作者挪 authored 位也流到没被孩子动过的世界"，才需拆 authored-pos vs live-pos + touched 标记 → OUT。）

### 9.7 风险与验收
- **风险**：碰最热读路径（scene entry / 对话意图 / guide / tasks / stage / 广播都读 char）；合成逻辑错 = 全局角色出错。
  必须保 kid-creation（世界独有 char）+ 点点仙子不被合成逻辑吞掉；guide/tasks/stage 消费 getCharacter/listCharacters
  的结果须仍正确。
- **验收（可机器验证）**：
  1. 新模板 char seed 进 template → 存量世界 `listCharacters` 立即含它（不 clone、不 bump、不重进）。
  2. 模板改某 char 的 sceneId → 存量世界读到的该 char sceneId 追平（修 village→village_forest）。
  3. 世界的可变态（memory/relationships/resident/live position）读合成后仍保留、不被 base 冲掉。
  4. 世界独有 char（孩子造物）+ 点点仙子照常存在、identity 正确。
  5. `cd server && npm test` + `tsc --noEmit` + `scripts/test-headless.sh` 绿。客户端零改（合成只在服务端读路径）。
