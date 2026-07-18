# 村民主动社交：走过来打招呼 + 送小红花

## 起因

现状村民对玩家有两条「注意到你」的机制，都**不会主动走过来**：

1. **心愿漏话**（`scripts/npc_wish_voice.gd`）：玩家走进听力半径才偷听到村民自言自语，村民原地不动。
2. **注意到玩家**（`world._update_npc_notice`）：玩家近旁时村民**原地**转头、挥手、头顶弹小表情，不出声、不走动、不分对象。

本设计给「注意到玩家」升一档：符合**性格 × 熟识度**条件的村民会**主动走过来、停在玩家旁、面向玩家打招呼**，外向的再**送一朵小红花**。让世界从「路过被动挥手」变成「有村民迎上来」，给小朋友被村子接纳的暖意。

## 三个决策

- **性格类型**：复用既有 `greetingStyle`，不加新字段。外向(`warm`/`playful`) 主动迎**陌生人**；内向(`shy`/`gentle`) 只迎**熟人**。
- **熟识度**：分级 `stranger → acquaintance → friend`，靠**实质互动**升级——聊过天=点头之交，完成过它的心愿/委托=朋友。单纯挥手、被送花**不**升级。
- **一期范围**：走过来打招呼 + 送小红花。**不**做「邀请一起玩小游戏」。

## 服务端（权威：熟识度 + 派生 + 下发）

- **熟识度存储**：`Character.relationships`（曾是死字段，只初始化 `{}`）重定义为 `Record<playerId, RelationshipState>`，
  `RelationshipState = { chats, wishesDone, gifted, lastSeen }`（`server/src/types.ts`）。整对象随 Character JSON 落库，
  老档 `{}`/历史值由 `social.coerceRelationship` 容错，无需迁移 pass。
- **派生**（`server/src/social.ts`，不落库、下发时现算）：
  - `deriveSocialType`：`warm/playful → extrovert`，`shy/gentle → introvert`，缺省按 id 稳定哈希（`greetings.styleForCharacter`）。
  - `deriveFamiliarity`：`wishesDone>0 → friend`；`chats>0 → acquaintance`；否则 `stranger`。
- **打点**（`store.recordVillagerBond`，改后必 `saveCharacter`）：
  - 聊完天：`endSessionVisit` 遍历这次会话聊过的每个村民 +chats。
  - 完成心愿/委托：`tasks.ts` 三处 `addStamp` 旁 +wishesDone（`completeWishOnAbility`/`completeWishRefine`/`completeTaskOnEvent`）。
- **下发投影**（`server.projectCharacterFor(character, viewerPlayerId)`）：按玩家视角给 Character 附加 `socialType` + `familiarity`。
  接入 `scene_entered`（批量，viewer=当前玩家）、`character_spawned`（新角色对谁都陌生，viewer=''→stranger）、`gen_complete`。仙子不参与。
- **一期取舍**：familiarity 只在角色**被下发时**刷新（进/换场景重发），同一场景内聊天后不即时反映——够用，
  且省掉一条实时 `character_bond` 报文与客户端接线。若日后要即时反映，再补单播。

## 客户端（空间权威：走位 + 表现）

- **调度器** `scripts/npc_greeter.gd`（`NpcGreeter`，仿 `NpcWishVoice` 抽成独立可测模块）：纯调度，
  返回 action 让 `world.gd` 执行，不碰节点/走位。
  - **资格** `greet_eligible(social_type, familiarity)`：外向×陌生 / 内向×(点头之交|朋友)。
  - **全局单槽**：同一时刻至多一个村民主动迎接（`_greeter`），配每村民长冷却 `CD_MIN..CD_MAX` + 全局 `GLOBAL_GAP` 错峰。
  - **状态机**：`approach`（下 follow 走向玩家）→ `arrived`（进 `ARRIVE_DIST`，面向+挥手+出声+送花）→ `release`（停留 `DWELL` 后收尾）；
    够不着超时 `giveup`；被玩家点对话/叫停（`greet_hijack`）中途放弃。
- **走位复用 follow**：`world._run_behavior(node, {commands:[{type:"follow", params:{target_name:"玩家"}}]})`。
  follow 跟移动中的玩家、到 `FOLLOW_NEAR`(3.4) 自停并保持——所以「到达」后**不取消** follow，靠它把村民钉在玩家旁；
  只在 `release`/`giveup` 才取消 + `_resume_ambient` 恢复闲逛。
- **胶水** `world._update_npc_greetings(delta)`：每帧标注 `greet_free`（可被新拉去迎接）与 `greet_hijack`（活跃迎接者被抢），
  喂 `NpcGreeter.update`，按返回 action 驱动 follow / 面向(`paper_face`)+挥手(`paper_action="wave"`)+气泡 / 收尾。
- **打招呼出声**（P3）：到达后经 `villager_hail` 走服务端 `greetCharacter`（招呼词池 `greetings.GREETING_STYLES` + 村民音色），
  不开对话会话、不进 FSM；客户端挂村民身上 3D 定位音（复用 `NpcWishVoice` 播法）。
- **送花**（P4，仅外向）：到达后 `send_villager_gift(worldId, villagerId, playerId)`，服务端防刷加花（`refundFlower`，capped `MAX_FLOWERS=9`），
  单播钱包更新；客户端复用 `_spawn_burst` + `_fly_reward_to_album` 飞花庆祝。

## 硬约束

- **仙子不参与**：她不会走路（见 CLAUDE.md），`projectCharacterFor`/`NpcGreeter` 对仙子早返回。
- **不扎堆**：漏话已有 `GLOBAL_GAP=14s` 全局节流；主动迎接自带全局单槽——同一时刻只有一个村民在社交。
