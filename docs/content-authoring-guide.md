# 内容开发指南：往马良小世界里加新内容

> 面向开发者/作者。世界模板架构 v2 全量上线后，「加内容」的正确姿势变了——先懂**内容怎么到达玩家**，
> 再照每类内容的步骤做。本指南的每条流程都读码坐实（附 `文件:行号`），架构依据见
> [`world-template-instancing-design.md`](world-template-instancing-design.md)。

## 1. 心智模型（先懂这个，否则会白改）

角色数据拆两层（`server/src/persistence.ts`）：

- **共享定义层 `character_defs`**（`persistence.ts:574`，PK `def_id`）：全局身份——name / personality / voiceId /
  greetingStyle / appearance / abilities / storyArchetype。**改这里，全世界引用者当场生效，零迁移。**
- **每世界实例层 `characters`**（`persistence.ts:564`，复合 PK `(world_id, id)`）：放置+可变态——position /
  sceneId / state / behaviorScript / memory / chatHistory / relationships / resident。**每个世界一份。**

世界谱系：

```
default ──(ensureTemplateWorld 提升,只一次)──▶ template ──(cloneWorldInstances,新世界建立时)──▶ w_<playerId> / sandbox_<uuid>
```

- `default`：现兼任「模板内容来源」。首次访问只种点点仙子，**不种村民/故事**（`server/src/server.ts:307-312`）。
- `template`：由 default 提升（`ensureTemplateWorld`，`persistence.ts:1035`）。新玩家世界从它 clone 放置。
- `w_<playerId>`：每人一世界。玩家走完 onboarding、踏进游戏世界那刻由 `getOrCreateMyWorld` 建立
  （`server/src/server.ts:296`）。**onboarding 阶段不连任何世界**，只调无状态 `/onboarding/*`。
- `sandbox_<uuid>`：测试沙箱（`POST /admin/worlds/sandbox`）。作者验内容隔离用，验完 DELETE。

**你只构造完整的 `Character` 对象调 `store.addCharacter()`；不手动碰任一表**——`saveCharacter`
（`persistence.ts:986`）在一个事务里自动拆写定义层 + 实例层，新角色 `defId = 自身 id`。

## 2. 内容怎么到达玩家（全指南最重要的一节）

| 改动类型 | 到达新玩家世界 | 到达存量玩家世界 |
|---|---|---|
| **定义级**（改已有角色的长相/台词/性格/能力/音色） | ✅ 自动（共享定义引用） | ✅ 自动（同一份共享定义） |
| **放置级**（加新村民 / 加新册 / 挪 NPC / 加物件） | ✅ 建世界时 clone 带上 | ✅ 种进 template 后调 `POST /admin/template/bump-version`，存量世界下次进入 additive 补齐（见 §6） |

**两个坑（都坐实，务必记住）：**

1. **改 `default` ≠ 改 `template`**。`ensureTemplateWorld` 幂等：template 已存在就短路返回，**不会**把你对
   default 的新改动提升过去（`persistence.ts:1030-1036` 注释明写「不重复克隆覆盖作者对模板的编辑」）。
   prod 的 template 早已存在。**正解：放置级新内容直接种进 `template` 世界**（seed 端点接受任意世界 id，见下），
   别改 default 指望自动提升。
2. **存量世界补齐要显式 bump**：加了放置级内容后，只有**全新**世界（clone）自动拿到；存量 `w_<playerId>`
   要调 `POST /admin/template/bump-version` 自增版本触发 `#migrateWorldPlacements` 补入，下次进入才补齐
   （见 §6，该端点已就位）。

## 3. 加作者村民（NPC）

作者村民走 `forest_characters.ts` 的种子表，admin 端点手动触发（不是首访自动种）。

1. 往 `FOREST_CHARACTER_SEEDS`（`server/src/forest_characters.ts:27`）加一条：name / personality /
   visualDescription / voiceId / greetingStyle / position。（或另建同形种子表复用 `seedForestCharacters` 逻辑。）
2. 数据只写这张种子表——`seedForestCharacters`（`forest_characters.ts:79`）会 `generateSprite` 现生成立绘、
   构造 `Character`（`id: randomUUID()`，`abilities: [...BASE_ABILITIES]`）、`store.addCharacter` 自动落两层。
   幂等按**同名**跳过。
3. 种入：`POST /admin/worlds/<world>/seed-forest`（`server/src/server.ts:1137`，admin token，`?only=名字` 可限种）。
   **要让新玩家拿到就种进 `template`**；存量玩家世界补齐见 §6。

## 4. 加一整册故事（story book）

一册 = 代码常量 + 每幕手作剧本。改这些：

1. **定义册**：在 `server/src/story_books.ts` 写一个 `StoryBook` 常量（`id/title/sceneId/gateCastId/cast/chapters`，
   参考 `THREE_PIGS`，`story_books.ts:85`），**注册进 `STORY_BOOKS`**（`story_books.ts:177`）。角色 id 由
   `storyCharacterId(bookId, castId)` = `story_<bookId>_<castId>` 生成（`story_books.ts:183`），稳定、跨世界同 id。
2. **写每幕剧本**：在 `server/src/screenplays/` 加手作剧本 `.ts`，**注册进 `SCREENPLAYS`**（`server/src/screenplays.ts:9`）。
   `StoryChapter.screenplay` 的名字要对得上，否则 `buildStoryStageOpts` 取不到会抛（`server/src/stage_debut.ts:86`）。
   SDK 命令面见 `server/src/screenplays/stage_sdk.d.ts`。
3. **贴纸/盖章款**（可选）：`stampStyle` / `sticker` 见 §5。
4. **种入**：`POST /admin/worlds/<world>/seed-story/<bookId>`（`server/src/server.ts:1149`）。同样**种进 `template`**。
   `seedStoryCharacters`（`server/src/story_seed.ts:24`）构造带 `storyRole:{bookId,castId,resident:false}` 的
   `Character`，拆写后 storyRole→def.storyArchetype、resident→实例行。

编排/开演由 `story_director.ts`（章回状态机，gate 角色搭话触发）+ `stage_debut.ts` 数据驱动，**加册无需改它们**。
册设计细节见 [`m2-story-director-design.md`](m2-story-director-design.md)。

## 5. 加玩法 / 主题 / 贴纸 / 造物

- **实时玩法脚本**：主路径是 LLM 从口语生成——`routeIntent` 识别 `play_game` → `screenplay_gen.ts` 生成真 TS
  剧本 → `checkScreenplay` typecheck → `StageDirector.startStage`（`server/src/screenplay_gen.ts:1-9`）。作者预置玩法=
  往 `screenplays/` 加剧本 + 注册 `SCREENPLAYS`（同 §4 步骤 2），会同时作 LLM few-shot 基线。
  设计见 [`realtime-game-primitives-design.md`](realtime-game-primitives-design.md)、[`script-runtime-design.md`](script-runtime-design.md)。
- **主题世界 / 建筑（PackRegistry）**：**近乎零 GDScript**——丢个 `assets/packs/<pack>/` 目录 + `pack.json`，再往
  `assets/packs/index.json` 加一行（`scripts/pack_registry.gd:8` 注释；现有 15 个 pack）。category：`baked`/`scatter`/`node`。
  设计见 [`world-themes-expansion-design.md`](world-themes-expansion-design.md) §6。
- **贴纸 / 造物类型**：⚠️ **不止改客户端 pack**——新增一个内置贴纸/造物还要在服务端 `server/src/items.ts` 的
  `BUILTIN_ITEMS`（`items.ts:22`）登记 `ItemDef` 并对齐 `renderRef` 前缀（`sticker:` / `furniture:` / 主题前缀）。
  「零 GDScript」只覆盖 PackRegistry 那层渲染绑定，不覆盖服务端 item 目录。贴纸设计见
  [`sticker-items-design.md`](sticker-items-design.md)、[`fairy-sticker-creation-design.md`](fairy-sticker-creation-design.md)。

## 6. 让放置级内容到达存量世界：`bump-version`

`bumpTemplateVersion()`（`persistence.ts:1101`）是 P5 additive 迁移的**唯一触发开关**，通过
`POST /admin/template/bump-version`（`server/src/server.ts` seed 端点区，admin token 门禁）暴露。

**作者流程（放置级新内容要到达存量世界）**：

1. 把新内容 seed 进 **template** 世界：`POST /admin/worlds/template/seed-forest`（或 `.../seed-story/<bookId>`）。
2. `POST /admin/template/bump-version` —— template 版本 +1，返回 `{ version }`。
3. 存量玩家世界**下次 `getOrCreateMyWorld` 进入**时，按版本落差跑 `#migrateWorldPlacements`，把它们还没有的
   放置**补入**（只加不改，绝不覆盖孩子改过的实例）。全新世界经 clone 本就带全，无需 bump。

**注意**：补齐是**被动**的——玩家下次进游戏才补，不是 bump 当下推给在线客户端（符合 P5「进入时迁移」设计）。
**只有放置级改动需要 bump**；定义级改动（改已有角色长相/台词/能力）走共享定义、当场全世界生效，无需 bump。

## 7. 验内容（沙箱隔离，不污染 default/template）

1. `POST /admin/worlds/sandbox` 开一个 `sandbox_<uuid>`（从 template clone）。
2. 客户端用 `MALIANG_WORLD=<sandboxId>` 指向它（`scripts/api.gd:163` bootstrap 覆盖钩子），或 harness 直接跑。
3. 种你的新内容进沙箱、跑整册/玩法验行为与隔离。
4. `DELETE /admin/worlds/<sandboxId>`（级联清理）丢掉。零污染。

## 8. 后台看到什么

管理台「世界」页调 `/debug/api/worlds` → `listWorlds()`（`persistence.ts:2042`，`SELECT id FROM worlds` 无过滤），
按 id 混排列出**每一个**世界：default / template / 每个 `w_<player>` / 每个 `sandbox_<uuid>`（无分组标签，玩家越多
行越多）。角色页是**每世界实例视角**（`listCharacters(world_id)`）；共享定义层 `character_defs` 后台不单独展示。
