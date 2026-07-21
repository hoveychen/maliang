# 第一季册3《白雪公主》· 设计（s1-snow-white）

> 状态：设计定稿（2026-07-21，老板拍板互动形态）。上游：`season-1-outline.md §4 册3`、
> `s1-merged-scene-layout.md`（合并大场景）、`m2-story-director-design.md`（章回册管线）、
> `content-authoring-guide.md §4`（加册流程）、`realtime-game-primitives-design.md`（Stage SDK 玩法）。
> 本册是第一季**数学（数到 7）**的载体。

## 0. 老板拍板（2026-07-21）

- **数学互动不做"看完就走"的薄 visit**，改用**服务端脚本引擎（Stage SDK）做一关真·互动数数游戏**。
- **七个小矮人做完整 7 个真角色**（各有音色/性格，整册完结入住当跑腿大户）。
- **屋里七张小床做成实体布景**（scene_compose）；配碗走游戏道具（screenplay 现生成）。
- **先做 A（剧情里的一关数数游戏，闭环盖章），再做 B（常驻操场·多可重玩游戏）**。本册只做 A；
  B（`play_game` 触发的可无限重玩数数游戏集）留后续另开计划。

## 1. 为什么这么落（三条约束的交汇）

1. **数学要"隐形"（铁律 3）**：不做上课/答题/闯关测验。数到 7 藏在"帮七矮人数人头 / 一人一个碗"的
   照顾行为里，点点只在旁边陪着数、报数，不打分、不判错。
2. **零挫败（铁律 1）**：无倒计时、无失败态、点错不惩罚（点重复的矮人点点温柔提醒"这个数过啦"）。
   数不满 7 也能随时走开，回来从这关幕首重玩（章回状态机 `story_director` 幕首恢复语义）。
3. **不发明新系统（outline §5 + 加册纪律）**：玩法全用现成 Stage SDK 原语（`on('tap')` / `on('enter',region)` /
   `hud.score` 计数器 / `prop.create` / `narrate`）——足球/老鹰抓小鸡就是同款纯脚本玩法的活证据。

## 2. 场景：森林深处·七矮人操场（复用合并大场景分区）

合并大场景 `village_forest`（100 格）实机 z 轴约定（**以 `scripts/terrain_map.gd` 为准，与
`s1-merged-scene-layout.md` 的 z 方向相反**）：**z 小 = 村庄近端（家），z 大 = 森林深处（远）**。

- **白雪 gate 位**：村庄核心广场旁（`z<40` 近端带，广场 T_PATH rect `(16,12)-(39,31)` 内），
  搭话即触发——和小猪/小红帽同一入口语汇。降生 tile ≈ `(30, 22)`。
- **七矮人操场**：森林深处那块林中空地（现有 `poi_forest_deep` 名"森林深处"，tile `(30,86)` 附近）。
  地形骨架（草地空地）P2 阶段已画好留空（`terrain_map._paint_village_forest` 注释："外婆家/七矮人两处
  林间空地 = 草地留空"）。本册往这块空地填：**七张小床布景**（scene_compose）+ 七个矮人降生站位。
- **新增 POI `poi_seven_dwarfs` 名"七矮人小屋"**（`assets/terrain/village_forest.pois.json` append）：
  tile ≈ `(30,86)`，radius 16，别名 `["小矮人家","矮人小屋","七个小矮人"]`。给点点提示 + 未来 B 计划的
  `visit`/引路落点用；本册 A 的数数游戏在这块操场就地开演，不强依赖引路。
- **七矮人降生站位**：操场空地里排开，便于孩子逐个点 + 逐个走到（一一对应）。约 `(26..34, 83..89)` 带内。

## 3. Cast（白雪 + 七矮人，八个真角色）

音色全部取自 `voice_catalog`（`isKnownVoice` 门禁）、册内两两可辨、都不撞小仙子的 `zh-CN-YunxiaNeural`。
矮人名字用**性格描述小名**（避开迪士尼商标名，`visualDescription` 只写外观、画风由生图管线统一追加）。

| castId | 名字 | 性格 | voiceId | 外观要点（英文喂生图） |
|---|---|---|---|---|
| `snow` | 白雪公主 | 善良爱照顾人、逃进森林后把七矮人的家当自己家收拾 | `zh-TW-HsiaoYuNeural` | fair-skinned girl, black bob hair, red hairband, blue-and-yellow dress, gentle smile |
| `doc` | 博士 | 七个里最有主意、爱数数、戴小眼镜 | `zh-CN-YunyangNeural` | tiny old dwarf, round glasses, long white beard, brown pointed hat, small vest |
| `happy` | 乐乐 | 咧嘴大笑、蹦蹦跳跳 | `zh-CN-YunxiNeural` | chubby cheerful dwarf, big grin, green hat, rosy cheeks, short brown beard |
| `sleepy` | 困困 | 慢半拍、老打哈欠 | `zh-TW-YunJheNeural` | drowsy dwarf, half-closed eyes, blue nightcap, yawning, small yellow beard |
| `bashful` | 羞羞 | 害羞躲手指后面 | `zh-TW-HsiaoChenNeural` | shy dwarf, blushing, peeking over hands, purple hat, tiny beard |
| `sneezy` | 喷喷 | 老想打喷嚏、鼻子红 | `zh-CN-liaoning-XiaobeiNeural` | dwarf with big red nose, holding a handkerchief, orange hat, sneezy face |
| `grumpy` | 气气 | 嘴上凶、心里软 | `zh-CN-YunjianNeural` | grumpy dwarf, furrowed brows, crossed arms, red hat, big grey beard |
| `dizzy` | 迷糊 | 糊里糊涂、老站错队 | `zh-CN-shaanxi-XiaoniNeural` | goofy dwarf, wobbly stance, oversized floppy hat, silly smile, no beard |

`gateCastId = 'snow'`。全 cast `resident:false` 起，整册完结（尾声演完）翻 resident 入住，
七矮人成跑腿大户（挂角色专属数数类委托，加厚中后期供给——回应 master-plan §3.2 断环诊断）。

## 4. 章回结构（2 幕，仿《小红帽》2 幕骨架）

| 幕 | screenplay | 类型 | 互动 | 盖章/贴纸 | 完结 |
|---|---|---|---|---|---|
| 0 | `story_snow_count` | **互动演出**（数数游戏） | 无 task（演出本身即互动，见 §5） | `stampStyle:'medal'` + `sticker:'story_snow'` | 演赢→发盖章→自动接演尾声 |
| 1（尾声） | `story_snow_end` | 纯演出谢幕 | 无 | 无（尾声不盖章） | 演完→七矮人+白雪入住 |

- **幕 0 是"互动演出"**：白雪逃进森林的旁白 + 数数游戏在**同一个 screenplay** 里连着跑
  （旁白铺垫 → 玩数数 → 数满 7 → `stage.end` 赢）。它**没有 StoryInteraction**（不物化跑腿委托），
  奖励走 §5 的 performReward 接线（演出跑赢就盖章）。
- **尾声**照《小红帽》：点点请孩子"把白雪和七个小矮人的故事讲给他们听"（复述，`stage.prompt`，零挫败不打分），
  演完整册完结、八个角色入住。

## 5. performReward 接线：让"互动演出"跑赢就盖章（本册唯一公共逻辑改动）

**问题**：故事框架把**演出（`story_director` 里无 interaction 的幕，演完直接 settle，不发盖章）**
和**互动幕（`build`/`task`，走 `settleStoryInteraction` 发盖章）**分开了。数数游戏是"演出即互动"，
需要"演赢就盖章"，落在两者中间。

**方案（最小侵入，复用现成机制）**：

- **数据**：`StoryChapter` 加可选字段 `performReward?: { npcCastId: string; thanks: string }`。
  一个**无 interaction** 的幕带上它 + `stampStyle`（+可选 `sticker`）= "互动演出章，跑赢发奖"。
  尾声不带 performReward/stampStyle，照旧只入住不盖章（`story_content.test` 强制尾声无盖章）。
- **判定点复用**：`story_director` 对无-interaction 幕**已经**在 `#settleChapter` 里算了 `reward`
  （首次完成该幕 → `reward:true`、推游标、必要时 `settledNow`、给 `autoPlayNextChapter`）。
  改的只是**服务端 `startStoryAsync` 的 `completed` 分支**——当前它只处理 `settledNow`（入住），
  不发盖章、不自动接演。补上：
  1. `advance.reward` 且本幕有 `performReward`+`stampStyle` → `store.addStamp` + 发 `task_complete`
     报文（**合成一个最小 ActiveTask**：`npcId`=performReward.npcCastId 对应角色、`stampStyle`、
     `storyThanks`=performReward.thanks；客户端 `_on_task_complete` 只读 `npcId/stampStyle/task`，
     缺字段优雅降级——盖章飞进手机、委托人蹦跳庆祝照常）。带 `sticker` 则 `bagAdd` + 随报文下发。
  2. `advance.settledNow` → `settleStoryResidency`（入住，照旧）。
  3. `advance.autoPlayNextChapter` → 自动接演尾声（照 `settleStoryInteraction` 同款 fire-and-forget，
     孩子不必走回 gate 再搭话）。
- **收敛点**：把上面"从 advance 发盖章 + 贴纸 + 入住 + 自动接演"抽成一个 `emitPerformReward(...)`，
  供 `startStoryAsync` 的 completed 分支调用。**不重构** `settleStoryInteraction`（它是小猪/小红帽的
  承重路径，保持行为不变，只在旁边加一条演出章的发奖路）。

**为什么不加新 interaction kind**：演出章走 `story_director` 现成的 `completed` 判定链（reward/推进/
settle/autoChain 都算好了），只差服务端把盖章报文发出来——比新造 `minigame` kind + 线程化舞台结果回
`story_director` 侵入小得多。数数游戏做成幕 0 的 screenplay（演出本体即游戏），零新协议。

## 6. 数数游戏玩法：`story_snow_count`（点矮人 + 配碗，都零挫败）

一个 Stage SDK 互动 screenplay（异步函数体，全局 `stage`/`cast`）。演员 = 册 cast（白雪+七矮人）+ 小朋友。

**开场旁白（铺垫，非游戏）**：
- 点点/旁白：白雪被继母赶出城堡、逃进森林、来到七个小矮人的小屋；屋里乱糟糟，白雪想帮矮人们
  把家收拾好——先要**数清楚一共有几个小矮人**。

**第一关·点矮人数到 7**（`on('tap')` + `hud.score` 计数器）：
- 七个矮人在操场排开。点点："我们一个一个点点看，数数一共有几个小矮人呀？"
- 孩子每点一个**没数过**的矮人 → 该矮人做个小动作（`do('wave'/'jump'/...）` + 说一句自己的性格短语）→
  计数器 +1 → 点点报数"一 / 二 / …… / 七！"。
- 点到**已数过**的矮人：点点温柔提醒"这个我们数过啦，再点点别的～"（不计数、不惩罚）。
- 数满 7 → 点点："哇，一共有七个小矮人！"（第一关过）。

**第二关·一人一个碗（一一对应）**（**纯 tap**：再点每个矮人一次＝给他盛一碗）：
- 点点："数清楚啦！小矮人们饿了，我们给每人盛一碗饭吧，一个小矮人一个碗，一个都不能少哦。"
- 孩子每点一个**还没盛碗**的矮人 → 那个矮人乐呵呵接过碗（`do` + 道谢短语）→ 计数器 +1 → 点点报数。
- 点**已盛过碗**的矮人：点点"他已经有碗啦～"（不重复计数）。
- 七个都盛上 → 点点："七个碗都盛好啦，七个小矮人一人一碗，正正好！"（第二关过）。
- **不生成碗道具**：`prop.create` 走服务端造物管线（LLM 出规格、可能出图），7 个＝7 次慢调用，
  不适合流畅游戏。七个碗做**静态布景**摆在矮人餐桌上（P5 场景布景）；游戏里"盛碗"用矮人反应 +
  计数器 + 点点报数表达，一一对应靠"每个矮人各点一次盛一碗"教。

**收场**：白雪道谢（"谢谢你帮我把家收拾好、把小矮人都数清楚！"）→ `stage.end({ praise: '数得真棒！' })`。
`stage.end` 一发即"演赢"（`StageRunResult.status==='done'`）→ 触发 §5 的 performReward 发盖章。

**为什么全程 tap（实机坐实，不是猜）**：`scripts/world.gd:3117` 观演/游戏态**吞掉一切玩家输入**
（点击移动/进对话/手势/缩放），**唯独 tap** 例外——`world.gd:3126` 把点击命中的演员 id 送
`_stage.on_local_tap`→tap 订阅。故事演出与 play_game 走同一条 `_stage_active` 路、**无区别**。
故：**演出期间孩子能点角色、但不能走动 avatar**。数数游戏**必须纯 tap**（点矮人数数、再点矮人盛碗）；
"走到矮人身边"（`on('enter')`/`on('near')`+走位）走不通——那条一开始就排除，不是待验风险。

**零挫败保证**：无倒计时、无 `hud.countdown`、无失败分支；重复点只温柔提醒不扣分；
中途走开 → 舞台 abort（`status!=='done'`）→ 幕首恢复，重触发从头玩，不发重复奖。

**⚠️ P6 仍需坐实**：故事演出 stage 里 tap 订阅确实把点击回调进 screenplay（与 play_game 同路，
`_stage_active` 不分故事/游戏，理应通）——harness/真机点一遍七个矮人，确认计数真走到 7 再收官。

## 7. 纪念贴纸 souvenir：`story_snow`（四处同口径）

照 `content-authoring-guide.md §4` 步骤 4 的四处同口径（缺一 `sticker_items.test` 就红）：
① 服务端 `items.ts` `BUILTIN_ITEMS` append `{ ...sticker('story_snow','小矮人的碗'), souvenir:true }`；
② 客户端 `assets/terrain/builtin_items.json` append 逐字段一致的同一条；
③ `assets/packs/stickers/pack.json` append `story_snow` → `res://assets/stickers/story_snow.webp`；
④ `server/tools/story_stickers.manifest.json` append 一行（id `story_snow` + prompt：七个小碗摆成一圈/一个小矮人的木碗），
   跑 `gen_ui_assets.mjs` 出 webp。图案主题贴合"数到 7 / 七个碗"。

## 8. 落地顺序（对应 TASKS.md s1-snow-white 的 P1-P6）

story_content.test 对**已注册**册强校验剧本+语音+贴纸，故 **SNOW_WHITE 注册进 STORY_BOOKS 推迟到 P5**
（剧本/语音/贴纸齐了才注册），每个 P 边界保持全绿：
P1 本文档 → P2 performReward 接线（+mock 册单测）→ P3 两个 screenplay + 注册 SCREENPLAYS →
P4 语音包预烧 + 贴纸四处 → P5 注册册 + scene 七床布景 + POI → P6 seed+bump+整册验证+merge。

## 9. 完结判定（可验证，对齐 outline §7）

- 数数游戏端到端：搭话白雪 → 演白雪逃进森林 → 点满 7 个矮人 → 配满 7 个碗 → `stage.end` →
  **盖章飞进手机**（performReward 生效）→ 自动接演尾声 → 复述 → **七矮人+白雪入住**。
- 数学种子：数到 7 + 一一对应（七矮人 ↔ 七个碗）在游戏里被真正操作，不是旁白念一句。
- 零挫败：全程无倒计时/失败态；走开再回从幕首重玩、不重复发奖（`rewarded[]` 判重）。
- 服务端/headless：`npm test`（story_content 本书全绿 + performReward 演出章发盖章单测）+ `tsc` 全清。
- 真机三问（outline §5.5）：数数这一关坐得住吗？走开再回困惑吗？七矮人搬进村里有惊喜吗？

## 10. 不在本册范围（后续计划）

- **B·常驻操场多可重玩游戏**：`play_game` 触发的可无限重玩数数游戏集（收集七果/归位七床/更大数）。
  另开计划，复用本册的七矮人 roster + 操场场景。
- **找零/凑数用小红花面额延伸数感**（outline §4 提到）：涉及经济系统，本册不做。
