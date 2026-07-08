# 记忆 + 会话(Visit) + 玩家实体 + SQLite 持久化 重构设计（草案 v2，待老板拍板）

> 状态：设计草案，未动生产代码。老板已定四点 + 两个放大范围的补充：
> ① 玩家必须有 ID（面向未来 MMO）② 持久化 JSON → SQLite。
> 本 v2 把这两块并入，范围从“记忆重构”扩为**三大块**。

## 0. 现状（已读代码核实）

| 事项 | 现状 | 出处 |
|---|---|---|
| 记忆结构 | `Character.memory: string[]`，无对象/类型/时间戳 | types.ts:95 |
| 记忆内容 | 只抽“关于小朋友”，无 NPC↔NPC、**无玩家维度** | openrouter_llm.ts:203 |
| 记忆抽取 | 每轮一次额外 LLM | voice.ts:191-221 |
| 会话概念 | 无（`session` 已被 VoiceSession 音频缓冲占用，会话概念改名 **Visit**） | server.ts:198 |
| chatHistory | 无 CAP，随 worlds.json 无限膨胀 | voice.ts:179 |
| relationships | 存在但**从未读写**，可复用 | types.ts:101 |
| 持久化 | JSON 全量重写 `worlds.json`；越大越慢 | persistence.ts:64-75 |
| **玩家 ID** | **前端无稳定玩家 ID**（`PLAYER_ID:="player"` 只是寻路占格常量 world.gd:25；profile.json 无唯一 id）；后端单 `'default'` 世界、无玩家维度 | world.gd:25 / server.ts:65 / player_profile.gd:9 |
| Node 版本 | **v26.4.0 → 内置 `node:sqlite` 可用**（零新依赖） | package.json |

## 1. 目标 / 非目标

**目标**
1. **玩家实体 Player + playerId 贯穿全模型**（面向 MMO 地基）。
2. **持久化迁移 SQLite**（`node:sqlite` 内置，零依赖），取代 worlds.json 全量重写。
3. Visit（会话）概念：进世界→离开为一段，作会话结束批量抽记忆的边界。
4. 记忆结构化：`(characterId, playerId)` 维度 + 分类型 + 分对象。
5. 抽取从“每轮一次”改“会话结束批量一次”。

**非目标（本期不做，但数据模型为其就绪）**
- 在线鉴权 / 账号密码 / 多设备同步：单设备先用前端生成的稳定 uuid 当 playerId。
- 多玩家同时在线的世界同步（真正 MMO 网络层）。
- 记忆向量检索。

## 2. 玩家实体（面向 MMO 的地基）

### 2.1 playerId 引入深度（**老板已定**）
**建完整 players 表 / 玩家实体体系**（一等公民，为未来 MMO 就绪），但：
- **身份来源 = device UUID**：前端“开始新游戏”时生成一个 UUID，即该玩家唯一 ID，存 profile.json，随每条消息上报。就是它，别无其他。
- **无任何玩家可见的鉴权流程**：不做登录/注册/账号密码 UI。玩家无感。
- **设备迁移（本期只预留，不实现）**：未来换设备靠 **QR Code + challenge** 的转移流程把旧 device UUID 的档案/记忆迁到新设备。schema 与 API 为此预留，本期不写迁移流程。
- MMO 演进：players 表结构已就绪；届时把“ID 来源”从 device UUID 换成服务端账号/QR 转移即可，记忆/Visit 模型不动。

### 2.2 Player 与记忆归属维度
MMO 下一个 NPC 会对**多个玩家各自**有记忆。所以记忆主体从“角色→小朋友”升为：
```
memory 属于 (owner_character_id, about_player_id)         # 该 NPC 对该玩家的记忆
        可选 about_character_id                            # NPC↔NPC 记忆（本期预留，主要产 about_player）
```
玩家档案（名字/昵称/形象）也上服务端 `players` 表（现在只在前端 profile.json）——MMO 必需，本期先把结构建好，前端仍可保留本地缓存。

## 3. SQLite 持久化

### 3.1 选型：`node:sqlite` 内置（**推荐，待确认**）
- Node 26 已稳定内置 `node:sqlite`（`import { DatabaseSync } from 'node:sqlite'`），同步 API，零新依赖，契合“能用标准库不引第三方”。
- 备选 better-sqlite3：生态成熟但引第三方 + 需原生编译。除非老板要，否则用内置。

### 3.2 schema 草案（一库多表，取代 worlds.json）
```sql
players(     id TEXT PK, name, nickname, gender, color, sprite_asset, created_at )
worlds(      id TEXT PK, inventory JSON, active_task JSON )
characters(  id TEXT PK, world_id, is_fairy, name, personality, voice_id,
             appearance JSON, state, behavior_script JSON, position JSON,
             abilities JSON )
memories(    id PK, owner_character_id, about_player_id, about_character_id NULL,
             text, kind, ts )                      -- 取代 Character.memory[]
chat_turns(  id PK, character_id, player_id, role, text, ts )  -- 取代 chatHistory[]，可按 CAP/时间裁剪
props(       id TEXT PK, world_id, spec JSON, tile JSON NULL, state )
visits(      id PK, world_id, player_id, started_at, ended_at NULL )
```
- 复合结构（inventory/appearance/behavior_script 等）先存 JSON 列，够用；高频查询的（memories/chat_turns）拆行便于分页/裁剪/后台展示。
- assets 维持文件系统内容寻址（assets/ + 现有机制），**不进 DB**（BLOB 进 DB 无收益，文件寻址已很好）。

### 3.3 迁移
- 启动时若存在旧 `worlds.json` 且 DB 为空 → 一次性导入（characters/props/inventory/task 照搬，`memory:string[]` 逐条包成 `memories{kind:'event', about_player: <默认玩家>, ts:0}`，chatHistory 导入 chat_turns）。
- 导入完把 worlds.json 改名 `.migrated` 备份，不删。
- WorldStore 对外 API 尽量**保持签名不变**（getCharacter/saveCharacter/listCharacters…），内部换 SQLite 实现，最小化 voice.ts/server.ts 改动。

## 4. Visit（会话）

- **边界**：WS 连接寿命==世界场景寿命==一次进世界到离开（三者物理重合）。开始=首条 `world_info`；结束=`leave_world`（前端正常退出显式发，**老板已选**）+ `socket.close` 兜底掉线。
- **身份**：`(worldId, playerId, startedAt)`，绑 worldId+playerId 而非 socket，兼容未来重连。
- **内容**：会话内累积各角色对话增量 `pendingByCharacter`；结束时对每个有增量的角色批量抽一次记忆。长会话超阈值（~20 轮）中途 flush 兜底掉线全丢。

## 5. 记忆抽取 / 注入改造
- **抽取**（extractMemory）：输入单轮→**整段会话增量（多轮）**；输出 `string[]`→`[{text, kind, about_player|about_character}]`。kind 枚举：`identity|preference|promise|event|relation`。**老板已选**本期主要产 about_player（关于玩家）的记忆，NPC↔NPC 预留。
- **注入**（routeIntent memoryLine）：按 (about_player=当前玩家) 取该 NPC 对这个玩家的记忆注入；未来多玩家时天然只取当前玩家的。

## 6. chatHistory 治理
- 老板已选“**改 SQLite**”：chat_turns 独立表后，天然可按玩家/角色分页、按 CAP 或时间裁剪，不再全量重写。
- 抽完记忆的旧 turn 可裁剪（记忆已提炼）；后台需要回看则查 chat_turns 分页。

## 7. 后台（只读观测）
DB 化后后台就是只读查询：players→worlds→characters→memories(按 kind/player 分组)+chat_turns 分页+visits 记录。可作为迁移后的验证工具。

## 8. 分期（老板拍板后立 TASKS.md + worktree；范围已扩大，拆细）
- **P1** SQLite 地基：引入 `node:sqlite`，建 schema，WorldStore 内部换 DB（对外 API 不变），worlds.json→DB 一次性迁移，单测（迁移等价 + 旧 API 行为不变）。
- **P2** 玩家实体：players 表 + playerId 贯穿；前端首启生成稳定 playerId 存 profile.json 并随消息上报；world_info/voice_* 带 playerId；单测。
- **P3** 记忆模型：memories 表 + MemoryItem(kind/about_player/about_character)；加载迁移旧记忆；注入按当前玩家取；单测。
- **P4** Visit + 会话结束抽取：server 建 Visit（world_info 开始 / leave_world+close 结束），pending 增量，flush 批量抽；accumulateMemory 由每轮改 flush；前端加 leave_world；单测（省调用 + 结构正确 + 掉线兜底）。
- **P5** chat_turns 迁移 + 裁剪 + 注入回归：chatHistory→chat_turns，CAP/裁剪，回归不伤连贯。
- **P6** 只读后台（可并入或另立 PRD）。
- **P7** merge --no-ff 回 main。

## 9. 主要取舍
1. **playerId 深度**：一等公民贯穿但单设备来源(A) vs 完整账号体系(B)。→ 推荐 A：MMO 就绪、不过度实现。
2. **SQLite 库**：node:sqlite 内置(零依赖) vs better-sqlite3。→ 推荐内置。
3. **WorldStore 迁移**：保持对外 API 签名不变，内部换实现 → 最小化上层改动、可回滚。
4. **assets 入不入库**：不入，维持文件寻址。
5. **范围**：三大块串行（P1 DB→P2 玩家→P3-5 记忆会话），每块独立可测、可中途停。
