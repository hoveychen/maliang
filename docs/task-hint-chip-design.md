# 委托可见性：chip 改头像可点 + 点点提示 + 「不想做了」放弃

设计者：本会话（老板 2026-07-15 拍板）。落地计划见 TASKS.md `task-hint-chip`。

## 背景与目标

小朋友接了委托后，现在只有右上角一个**文字** chip（目标图标+短名 ⇒ 盖章图标）能看出手上有活。四个缺口：

1. chip 是文字，不是委托人头像；幼儿园孩子不识字。
2. chip 不可点——没有主动「问点点该怎么办」的入口。
3. 忘了委托没有任何主动提醒（常驻 chip 是唯一被动线索）。
4. 说「不想做了」没有放弃委托的路（`guide_stop` 只停引路）。

**老板拍板的三个取舍：**
- 点 chip → 点点**提醒 + 问「要我带你去吗」**（符合点点「只提议、用问句」人设），孩子点头再引路。
- 提示走**点点对话通道**（追问「该怎么办」、说「不想做了」都在对话里自然识别）。
- 说「不想做了」→ 点点**暖暖确认一句**再清委托，不扣任何东西（本来就没盖章）。

## 关键地基（已核实，让范围缩了一大圈）

- ✅ **点点/村民的 routeIntent prompt 里已注入进行中委托**（`openrouter_llm.ts` 的 `taskLine`，`ctx.activeTask`），
  还明写「小朋友问起就温柔提醒」。→ 老板要的「追问该怎么办」**底层已通**，只缺入口。
- ✅ `describeTask`（`tasks.ts`）已按四类委托描述清楚，wish 类明说「只有小仙子的魔法才能帮它实现」。
  → 点点对 wish 类不会乱提带路，会自然说「我们一起把它变出来」。
- ✅ `guide_to` 已能带去目标角色/地点（跨场景），`send_voice_transcript(world, charId, text)` 能给点点发合成转写。
- ✅ **点自己 = 跟点点说话**（`_tap_pick` 的 `_pick_player` 分支 → `_approach_npc(fairy)`），进对话即开麦——追问白拿。
- ✅ `_set_active_task(null)` 会清空 `active_task` 并隐藏 chip。

**所以「带路只是跑腿类分支」**：点击=向点点发「这个任务怎么做呀」，点点 LLM 拿着 `taskLine` 里的委托类型自己分叉：
跑腿类（deliver/bring/visit）提带路 → `guide_to`；心愿类（wish）提「一起造/一起玩」，不带路。

## 改动（4 个 P-task）

### P1 服务端 —「不想做了」+ 提示分叉

- `IntentResult` 加 `abandonTask?: boolean`；`VoiceResponse` 加 `taskCleared?: boolean`。
- `openrouter_llm.ts`：
  - JSON 输出规范加 `"abandonTask"`。
  - `taskLine` 增补一句：小朋友说「不想做了/算了/不帮他了」→ 置 `abandonTask=true` + 温柔应一句。
  - 解析：`if (raw.abandonTask === true && ctx.activeTask) result.abandonTask = true;`（仅有进行中委托时认）。
- `mock.ts`：`routeIntent` 在 `ctx.activeTask` 存在时，反悔词命中 → `abandonTask=true`（确定性）。
- `voice.ts` 响应组装：`intent.abandonTask && activeTask` → `setActiveTask(null)` + `response.taskCleared = true`
  （优先于 offerTask/activeTask 回带分支）。
- 单测：识别放弃→清委托+置 `taskCleared`；无进行中委托时不误触发。

### P2 客户端 — chip 改委托人头像 + 纯图标 + 可点

- chip 变可点按钮（`gui_input` 或包一层 Button），点击回调进 P3。
- 去文字，改为：**委托人头像**（npc 立绘缩略）+ 类型图标 + 目标线索图标：
  - deliver：委托人头像 + `ic_chat` + 目标角色头像
  - bring：委托人头像 + `ic_handshake` + 目标角色头像
  - visit：委托人头像 + `ic_pin`（地点无头像）
  - wish：委托人头像 + `ic_wand`（想要的东西＝找会魔法的）
  - 末尾保留 `⇒ 盖章图标`（奖励线索）
- headless 冒烟（chip 重建不崩、可点回调触发）。

### P3 客户端 — 点击入口

- 点 chip → 选中点点（复用「点自己」路径）+ `send_voice_transcript(world, fairyId, "这个任务怎么做呀")`。
- 点点带 `taskLine` 上下文回话（跑腿提带路/心愿提一起造），进对话即开麦 → 追问白拿；说「不想做了」→ 接 P1 清 chip。
- headless。

### P4 全套回测 + merge --no-ff 回 main（验收门）。真机手感留老板。

## 不做（守边界）
- 不给点点加走路能力（她只引路，硬约束见 CLAUDE.md）。
- 不改盖章/结算逻辑（只动「怎么看见委托、怎么问、怎么放弃」）。
- 放弃委托不扣花、不盖章、不惩罚——只是清掉当前委托。
