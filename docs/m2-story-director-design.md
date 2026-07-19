# M2 主线剧情：StoryDirector 章回式短剧 + 首册《三只小猪》（设计）

> 状态：v1（2026-07-19）。总案（[[design/game-master-plan]] §5）路线图 M2 的实施设计。
> 计划 id：`m2-story-pigs`，worktree `.worktrees/m2-story-pigs`。
> 接线点已读码坐实（侦察 2026-07-19），文中带 文件:行号 的都核过。

## 1. 目标与边界

**做**：StoryDirector 服务端编排层（状态机 + 持久化 + 触发/演出/互动/奖励/入住五段接线）+
《三只小猪》全册手作内容。**不做**：LLM 现场编剧（只手作剧本）、第二册（管线通了再铺）、
学科挂点深化（M3）、演出真机延迟量测之外的性能工作。

设计原则照总案 §5.2 四条：章回只解锁不催促、手作剧本预烧台词、走开即收起回来重演、
互动幕只复用现有玩法（首册用 B1 积木造物）。

## 2. 现状纠正（两处与总案假设不同，读码坐实）

1. **演出台词不是预烧的**：现有 stage `say` 走 clientTts——`stage_begin` 随 actor 下发
   voiceId（stage_types.ts:9），客户端 `world.gd stage_say` 现场 edge-tts 合成。
   → 预烧是**新增机制**（§4.3 混合方案），不是「照现有路子」。
2. **演出没有暂停语义**：孩子在演出期被锁输入（world.gd `_stage_active`），走不开；
   离场只有「世界空 → kill worker」（server.ts:2662）和主动 abort。
   → 「走开自动收起」＝**幕级 abort + 回幕首重演**（§3），不做真正的 pause/resume——
   幕只有 5-10 分钟，重演成本可接受，且状态机简单一个数量级。

## 3. 数据模型与状态机

### 3.1 storyProgress（每世界每玩家）

新表 `story_progress(world_id, player_id, data JSON)` PK(world_id, player_id)，
照 `wallets` 先例（persistence.ts:415/1049，匿名键归一照 `#walletKey`）：

```ts
interface StoryProgress {
  books: Record<string, {          // bookId → 该册进度
    chapter: number;               // 当前幕（0 起）
    state: 'idle' | 'performing' | 'interacting' | 'rewarded';
    rewarded: number[];            // 已发过奖的幕（重看不重复发奖的口径）
    settled: boolean;              // 整册完结（入住已发生，幂等门闩）
  }>;
}
```

### 3.2 幕状态机（StoryDirector，新模块 `server/src/story_director.ts`）

```
idle ──搭话触发──▶ performing ──演出 done──▶ interacting ──互动完成──▶ rewarded
  ▲                    │ abort/断线/世界空                                │
  └────────────────────┘（回本幕 idle，重触发从幕首重演）                 │
  └──────────────── 下一幕 idle（chapter+1）／最后一幕 → 整册完结入住 ◀──┘
```

- **performing 不落库中间态**：开演时置 performing，演出 `stage_end(done)` 才迁
  interacting；abort/timeout/断线一律回 idle——重进世界永远停在幕首（总案 §5.5 的
  「断线中途恢复到幕首」）。
- **重看**：任何已 rewarded 的幕都可再触发（重演 performing→interacting→跳过发奖直接
  收场）；`rewarded[]` 是防重复发奖的唯一判据。
- **无倒计时无催促**：状态机没有任何时限字段；幕之间无解锁条件之外的顺序压力。

### 3.3 册定义（代码常量，`server/src/story_books.ts`）

```ts
interface StoryChapter {
  screenplay: string;              // SCREENPLAYS 注册名（story_pigs_1 …）
  interaction: StoryInteraction;   // 互动幕：复用现有玩法之一
  stampStyle: string;              // 本幕盖章款式
  sticker?: string;                // 本幕纪念贴纸（内置贴纸 id，addToBag 发放）
}
interface StoryBook {
  id: string;                      // 'three_pigs'
  title: string;
  sceneId: string;                 // village（首册）
  gateCharacter: StoryCastDef;     // 门口的故事角色（猪大哥）＝触发入口
  cast: StoryCastDef[];            // 全部故事角色（三只小猪；狼＝纯演出角色不入住）
  chapters: StoryChapter[];
}
```

互动幕 `StoryInteraction` 首册只需两种：`{ kind: 'build', blueprintId }`（B1 积木拼房，
帮小猪盖砖房）与 `{ kind: 'task', type: 'deliver'|'bring'|'visit', … }`（走 activeTask
形状，判定复用 completeTaskOnEvent 家族——零新完成判定，同 M1 链步物化纪律）。

## 4. 接线（全部走现有通道）

### 4.1 触发：storyGate 角色搭话

- 故事角色随世界 seed 落 roster（照 server.ts:293 种子角色先例，预生成立绘 hash 直接
  引用，见 §5）。带 `storyRole: { bookId, castId, resident: false }` 标记——**未入住的
  故事角色不进心愿/漏话/委托/社交供给**（wishFor/pickLeak/pickTaskCandidate/NpcGreeter
  对 storyRole 且未 resident 的角色早返回，防止狼在村里漏话）。gate 角色（猪大哥）例外：
  可搭话，搭话即触发。
- 意图分支照 `play_game` 先例：routeIntent prompt 给 gate 角色加 `start_story` 能力 →
  voice.ts:142-182 摘成 `response.storyRequest` → server.ts:3283 附近
  `startStoryAsync(...)`。孩子说「讲故事/演一个/这是什么」都归一到它；已在演出/已 settled
  册走普通对话。
- 场景 POI 加故事入口点（types.ts:231 形状），trigger 键给仙子一条预烧提示词
  （fairy_voice 现成路径 world.gd:1171），只提示不催促。

### 4.2 演出：直供 StageStartOpts，绕 LLM

`startStoryAsync` 照 `startGameAsync`（server.ts:1845）骨架，但**不走 generateScreenplay**：
剧本是手作注册的（SCREENPLAYS，screenplays.ts:9），选角不走 buildDebut 的 roster 随机——
直接按册 cast 的 characterId 组 `StageActorInfo[]`（stage_session.ts:12）。演出结束回调
`StageRunResult` done → StoryDirector 迁 interacting；abort/timeout → 回 idle。
一世界一场的现有约束（stage_session.ts:258）天然防并发章回。

### 4.3 台词：预烧优先、clientTts 兜底（混合）

- 剧本台词行带稳定 lineId（`<bookId>_<chapter>_<seq>`）。`gen_voice_lines.mjs` 现成管线
  为每册烧 `assets/voice/story_<bookId>/lines.json + <lineId>.wav`（角色音色查
  voice_catalog）。
- 客户端 `stage_say` 先查故事音包：命中播 WAV 即 ack；miss 回落现有 edge-tts 路径。
  播放器照 fairy_voice.gd 骨架（load_threaded 预载 + 零运行期 TTS）——新一个轻量
  StoryVoice 或抽公共骨架，实施时按代码量取小者。
- 收益：脱网可演、音质稳定；风险面收敛为「miss 兜底」一条路径。

### 4.4 互动与奖励

- interacting 态：把该幕 `StoryInteraction` 物化成 activeTask 形状下发（storyTask 标记
  `storyBookId/storyChapter`，同 M1 chainNpcId 先例）；build 类挂 B1 现有 create_build
  完成点。完成结算处（tasks.ts 三结算点 + build 落成点）发现 storyTask → 通知
  StoryDirector 迁 rewarded。
- 发奖全复用：`store.addStamp`（persistence.ts:1072）+ `task_complete` 报文原形状
  （server.ts:3051，客户端盖章庆祝零改）+ 纪念贴纸 `store.addToBag`（persistence.ts:837，
  内置贴纸 def 照 sticker_items 先例）。`rewarded[]` 判重，重看不再发。

### 4.5 入住（整册完结）

最后一幕 rewarded → `settled=true`（幂等门闩）→ cast 中 `resident:false` 的小猪们翻
`resident:true`（狼标记 `noResidence` 不入住）：从此各供给面（心愿/漏话/委托/社交）放行，
并照 server.ts:2178 先例 `ensureTaskChain(...)` fire-and-forget 长专属委托链——
「小猪住进村里带着盖房系列委托」即 M1 链的直接复用（模板链外加册内定制链，实施时二选一，
优先册内定制：题材连续性是入住惊喜感的一半）。角色本体 seed 时已在 roster，入住不新建。

## 5. 首册《三只小猪》内容（village，3 幕 + 尾声）

| 幕 | 演出（手作 screenplay） | 互动 | 奖励 |
|---|---|---|---|
| 1 盖草房 | 猪小弟搭草房，狼来吹倒，逃到猪二哥家 | visit：去看看草房废墟 | 章 + 贴纸「草垛」 |
| 2 盖木房 | 狼吹倒木房，两只猪逃到猪大哥家 | deliver：把「快来砖房」带给猪小弟 | 章 + 贴纸「木板」 |
| 3 盖砖房 | 三只猪合力+狼吹不倒+烟囱掉锅里逃走 | **build**：B1 积木拼砖房帮小猪 | 章 + 贴纸「砖房」 |
| 尾声 | 谢幕短演出（三只猪道谢） | — | 整册完结 → 三只小猪入住 |

- 剧本走 stage_sdk 现有能力（say/moveTo/do/narrate/banner/camera），不为剧情发明新原语；
  `checkScreenplay` typecheck 过是注册门禁（realtime-primitives 纪律）。
- 狼：纯演出角色。立绘走生成管线但外观描述写「憨萌不吓人」——4 岁向，吹房子演成鼓腮帮
  滑稽戏；不入 roster、不留在场景（幕间由剧本收场）。
- 角色立绘/图标：预生成一次入内容寻址资产库（tools 脚本，港区 403 走首尔两段式），
  seed 引用 hash——不是每世界现生成（成本与确定性）。

## 6. 分 P（TASKS.md 计划 id: m2-story-pigs）

- **P1 服务端·故事地基**：StoryBook/StoryProgress 类型 + story_progress 表（照 wallets
  先例）+ StoryDirector 状态机纯逻辑（stage 启动函数注入，可 mock）；单测（全迁移路径/
  abort 回幕首/重看不重复发奖/settled 幂等）。
- **P2 服务端·触发与演出**：storyRole 标记 + 各供给面早返回 + gate 搭话 start_story 意图
  分支 + `startStoryAsync` 直供 StageStartOpts + stage 结果回调接线 + 世界空/断线清场；
  单测。
- **P3 内容·三只小猪**：cast 档案 + 立绘/图标预生成（工具跑一次入库）+ seed 接线 +
  3 幕 + 尾声手作 screenplay（checkScreenplay 门禁）+ 台词 lines.json + 预烧 WAV；
  单测（剧本注册/资产清单齐全校验）。
- **P4 服务端·互动奖励入住**：storyTask 物化与结算接线（含 build 完成点）+ addStamp/
  task_complete/纪念贴纸 + 入住翻 resident + ensureTaskChain；单测（幕闭环/重看跳奖/
  入住后供给面放行）。
- **P5 客户端**：故事音包播放（StoryVoice，miss 回落 clientTts）+ POI 仙子提示词 +
  headless 全链（触发→演完→互动→盖章→整册→小猪进 roster 且开始漏话）。
- **P6 验收门**：server 全测 + tsc + headless 全套 + 预烧资产核数；呈老板「可以合并了」
  摘要 → merge --no-ff。真机三问（一幕坐得住吗/走开再回来困惑吗/入住有惊喜吗）留老板
  与女儿按 [[design/alpha-playtest-manual]] 实测（Alpha 门）。

**总验收（可验证）**：headless 上从触发到入住全链绿；重看任一幕不再发奖（单测）；
断线重进停在幕首（单测）；入住后小猪出现在 npc_wishes 供给里（单测）。
