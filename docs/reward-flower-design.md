# 奖励经济改造：小红花代币 + 集邮簿 设计（草案 v1，待老板拍板）

> 状态：设计草案，未动生产代码。承接 main 现有的「贴纸奖励 + give 转赠」奖励系统，将其**整体替换**为「单代币小红花 + 集邮盖章」经济。
>
> 老板已拍板：
> ① 冷启动 = **初始送 3 朵花**（新存档预置 3 朵，够造一次物+一次角色还剩一朵试错）
> ② 盖章语义 = **纯累加 3→1**（每满 3 章升 1 花，不存在「断了清零」）
> ③ 排序 = **服务端先行**，UI/造角色扣费等 phone-menu、guided-creation 两个 worktree 合并后接入
> ④ 下一步 = 本设计文档发 wiki 归档，暂不开工

## 0. 现状（已读代码核实）

| 事项 | 现状 | 出处 |
|---|---|---|
| 奖励货币 | 8 种贴纸 `flower/apple/star/shell/ladybug/candy/clover/gem` | `server/src/types.ts` STICKERS |
| 背包存储 | `inventory: Record<stickerId, number>`，随世界持久化 | `persistence.ts` worlds.inventory JSON |
| 获得途径 | 完成委托 → `addSticker(worldId, task.rewardId)`（rewardId 是**随机**一种贴纸） | `tasks.ts:124` completeTaskOnEvent |
| 消耗途径 | **唯一** = `give_item` 转赠给 NPC（`removeSticker` 扣背包 + 写 NPC 记忆） | `server.ts:643` |
| 委托类型 | `deliver/bring/visit/gift`；其中 **gift = 请小朋友送我一张贴纸** | `tasks.ts` TaskType |
| 完成口播 | `praiseLine` 说「送你一个X贴纸」；`thanksLine` 转赠致谢 | `tasks.ts:77` |
| 造物品 | `create_prop` 意图 → `createPropAsync`（**免费**，无门槛） | `server.ts:477,706` |
| 造角色 | `create_character` 意图 → `createCharacterAsync`（**免费**；引导式在 guided-creation worktree 开发中） | `server.ts` / guided-creation-design.md |
| 客户端收集册 | 左下角面板，tab：贴纸(8格网格)/物品/设置 | `world.gd` album_panel、STICKER_ORDER |
| 客户端消耗 | `give_item` 转赠；收集册贴纸页展示 8 种数量 | `world.gd` |

**结论**：奖励货币、获得/消耗途径、委托类型、完成口播、收集册 UI 全都焊在「8 种贴纸」上。改造是把这一整条链换成单代币。

## 1. 目标 / 非目标

**目标**
1. 贴纸经济 → **单代币「小红花」**：删掉 8 种贴纸与 `give` 转赠玩法，`inventory` 只记小红花与盖章进度。
2. **集邮簿**：完成任一 NPC 愿望 → 盖 1 个章；**每满 3 章 → 换 1 朵小红花**（纯累加）。
3. 小红花**上限 9**（3×3 格）。
4. 小红花**可消费**：造物品(`create_prop`)、造角色(`create_character`) **各扣 1 朵**；0 朵时仙子温柔引导去完成愿望攒花。
5. **AIGC 出图**：几款「真·小红花」图标（非 emoji，幼儿园小朋友认得的那种小红花）+ 几款盖章样式。
6. UI：3×3 小红花格 + 集邮簿盖章进度，接入手机 HUD（见 §7 与在飞计划的衔接）。

**非目标（本期不做）**
- 小红花以外的第二货币 / 兑换商店（只做花与盖章两层）。
- 盖章的「连续/断则清零」难度机制（老板已否，纯累加）。
- 溢出后的小红花「继续攒/转存」高级机制（满 9 的处理见 §5 默认）。

## 2. 经济模型（核心）

```
完成 NPC 愿望(deliver/bring/visit)
        │
        ▼
  盖 1 个章  stampProgress++            ← 集邮簿
        │
   stampProgress == 3 ?
        │ 是
        ▼
  换 1 朵花  stampProgress=0；flowers=min(9, flowers+1)   ← 3×3 上限
        │
        ▼
  造物品 / 造角色  flowers-- (各扣 1)     ← 消费
        │ flowers==0 时
        ▼
  仙子引导：「去帮小伙伴完成心愿，攒够小红花就能再造啦」
```

- **盖章不是货币**，是「攒花进度」：`stampProgress ∈ {0,1,2}`，攒到 3 立即结算成 1 朵花并归零。集邮簿 UI 把它画成一排排盖章戳记。
- **小红花是唯一货币**：`flowers ∈ {0..9}`。造物/造角色是它的两个消费出口。
- **纯累加**：盖章只增不减、不会因中断清零（老板拍板）。

## 3. 数据模型

### 3.1 背包结构改造（`persistence.ts` worlds.inventory）

现状 `inventory: Record<stickerId, number>`。改为定长结构（仍存 JSON 列，兼容旧列名）：

```ts
interface Wallet {
  flowers: number;         // 0..9 小红花
  stampProgress: number;   // 0..2 当前未结算盖章数
  stampsTotal: number;     // 累计盖过的章数（集邮簿展示/成就用，只增）
}
```

- 新增 store 方法（替换 addSticker/removeSticker）：
  - `getWallet(worldId): Wallet`
  - `addStamp(worldId): { flowerGained: boolean; wallet: Wallet }` — 盖 1 章，满 3 结算 1 花（受 9 上限），返回是否升花。
  - `spendFlower(worldId, n=1): boolean` — 够扣则扣返回 true，不够返回 false 不动账。

### 3.2 迁移（旧存档）

旧存档 `inventory` 是 `{stickerId: count}`。迁移策略（**老板已拍板：方案 A**）：
- **方案 A（采用）**：清空旧贴纸，一次性置 `flowers = 3`（初始赠送数）、`stampProgress = 0`。简单、干净，反正贴纸玩法整体删除；幼儿园测试机基本没存量。
- ~~方案 B：旧贴纸总数折算小红花（每 3 张 = 1 花，capped 9）~~ —— 未采用。

## 4. 委托系统改造（`tasks.ts`）

1. **删除 `gift` 委托类型**（请小朋友送贴纸——贴纸没了）。保留 `deliver/bring/visit`。
   - `pickTaskCandidate` 去掉 `if (stickers.length>0) types.push('gift')` 与 gift 分支。
2. **`rewardId` 语义变更**：不再是「随机一种贴纸」。任一委托完成 = 盖 1 章。`rewardId` 可**改为盖章样式 id**（`stampStyle`，从几款 AIGC 盖章里随机挑一款，纯演出），或直接删字段。
3. **完成结算**：`completeTaskOnEvent` 里 `addSticker(rewardId)` → `addStamp(worldId)`；返回值带上 `flowerGained` 供上层决定口播。
4. **口播 `praiseLine`**：
   - 未升花：「太棒啦！这个盖章送给你！再帮两个小伙伴就能换一朵小红花啦！」（按 stampProgress 动态说还差几个）
   - 升花：「哇！集满三个盖章，换到一朵小红花啦！」
   - `thanksLine`（转赠致谢）随 `give` 玩法删除。

## 5. 消费门槛（`server.ts`）

- **造物品**：`createPropAsync` 入口前（`server.ts:706/752/816` 三处摘 propRequest 的地方，或在 `createPropAsync` 内首步）先 `spendFlower(worldId)`；失败则不造，改推仙子引导语（新增 `prop_denied` / 复用现有仙子 TTS）。
- **造角色**：`create_character_request` 分支（`server.ts` ~667）与 guided-creation 的 `done→createCharacterAsync` 处，同样先 `spendFlower`；0 花则不进造角色会话，仙子引导。
- **扣费时机**：建议在**确认要造的那一刻**扣（造物 = 摘到 propRequest 时；造角色 = 引导会话 done 决定造时），而非会话开始时——避免小朋友聊两句放弃也被扣。造失败（审核/生图失败）应**退还**（`addFlower` 回补），否则孩子会「白花一朵」。→ 需要一个 `refundFlower`。
- **0 花引导语**：仙子说「你的小红花用完啦，去帮小伙伴完成心愿，集满盖章换小红花，就能再造一个新朋友/新玩具啦！」

**满 9 花的溢出（老板已拍板：暂停升花）**：花满 9 时盖章仍可盖，但攒到 3 时若已满 9 则**不升花、stampProgress 停在 2 不清零**，等花被花掉低于 9 后立即补升。最不「浪费」，对幼儿最直觉（「格子满了先用掉」）。

## 6. AIGC 资产

| 资产 | 数量 | 用途 | manifest 位 |
|---|---|---|---|
| 小红花图标 | 2–3 款（同一朵花的不同姿态/大小档） | 3×3 格填充、手机 banner 计数、消费动画 | `reward_flower` / `reward_flower_lg` … |
| 盖章样式 | 3–5 款（小星星/笑脸/爪印/勋章风，幼儿友好） | 集邮簿每格盖章、完成委托弹出 | `stamp_01`..`stamp_0N` |

- 画风统一走项目现有「去 emoji + AIGC 图标」管线（同 guided-creation P3 的图标生成管线，可复用）。
- **与 phone-menu P5 对齐**：phone-menu 已预留 AIGC manifest 条目占位，本项目的小红花/盖章资产并入同一批生成。

## 7. 客户端 UI（Godot）与在飞计划的衔接

**⚠️ 与两个在飞 worktree 计划高度耦合，必须协调，不能各写各的：**

### 7.1 `phone-menu`（手机 HUD 改造，worktree 开发中）
- banner 已规划「小红花数(代笔占位)」→ **本项目让它成真**：banner 读 `wallet.flowers` 实时显示。
- 4×4 app 网格里的「贴纸」app → 改为 **「小红花 / 集邮簿」app**：进去是 3×3 小红花格 + 集邮盖章进度。
- 「物品」「设置」app 不动。
- **衔接方式**：本项目**不重写** phone HUD 骨架，只往 phone-menu 定义的 app 容器里填小红花/集邮内容 + 接 banner 数据。→ **建议 phone-menu 先落地，本项目再接**（见 §8 排序）。

### 7.2 `guided-creation`（引导造角色，worktree 开发中）
- 造角色的**扣费门槛**要接进 guided-creation 的 `done→createCharacterAsync` 分支（§5）。
- **衔接方式**：本项目在服务端提供 `spendFlower/refundFlower`，guided-creation 的造角色落地处调用。→ 谁先合并谁留 hook，另一方接。

### 7.3 收集册现状清理
- 删掉贴纸页 8 格网格与 `STICKER_ORDER`、`give_item` 相关交互（长按 NPC 送贴纸那套）。
- `world_state` / `task_complete` / `give_result` 消息里的 `inventory` 字段 → 换成 `wallet`（flowers/stampProgress）。

## 8. P-task 分解建议（含与在飞计划的排序）

> 排序关键点：**服务端经济核心（P1）可独立先做**；**UI（P4）依赖 phone-menu 落地**；**造角色扣费（P3）依赖 guided-creation 落地**。故建议服务端先行，UI 待两个 worktree 合并后接入。

- **P1** 服务端经济核心：`Wallet` 结构 + 迁移；`getWallet/addStamp/spendFlower/refundFlower`；改 `tasks.ts`（删 gift、rewardId→stampStyle、addStamp、praiseLine）+ 单测（盖章累加、满 3 升花、满 9 溢出、扣费不足、退还）
- **P2** 消费门槛接线：造物 `createPropAsync` + 造角色入口先扣费、失败退还、0 花引导语；删 `give_item` 分支；`world_state`/`task_complete` 下发 `wallet` + 单测
- **P3** 造角色扣费接进 guided-creation（依赖该 worktree 合并；若未合并则本项目留 `spendFlower` hook）
- **P4** 客户端 UI：小红花/集邮 app 内容（3×3 花格 + 盖章进度）接进 phone-menu HUD；banner 小红花计数；删收集册贴纸页与 give 交互；headless 冒烟（依赖 phone-menu 合并）
- **P5** AIGC 资产：小红花 2–3 款 + 盖章 3–5 款（并入 phone-menu/guided-creation 图标生成管线）+ 填 manifest + 校验
- **P6** 全套回测（含新单测）+ 真机手感调参（盖章/升花动画反馈）+ merge --no-ff 回 main（老板验收门）

## 9. 决策记录

**已全部拍板（老板）**
1. 冷启动 = **初始送 3 朵花**。
2. 盖章语义 = **纯累加，每满 3 章换 1 花**，无「断则清零」。
3. 排序 = **服务端 P1–P2 先行**；UI/造角色扣费待 phone-menu、guided-creation 两个 worktree 合并后接入（§8）。
4. 先出本设计文档、发 wiki 归档，暂不开工。
5. 满 9 花溢出 = **暂停升花、stampProgress 停在 2**，花掉低于 9 后立即补升（§5）。
6. 旧存档迁移 = **方案 A：清空贴纸 + 给初始 3 花**（§3.2）。
7. 造物/造角色 = **各扣 1 朵**（同价）。
8. 盖章款式 = **每次随机挑一款**（纯演出，不影响经济）。

无遗留开放项。
