# 玩家形象 onboarding 重做——从「四道固定题」到「点点引导的个性化创作」

> 设计文档，未动生产代码。重做 `scripts/onboarding.gd` 的玩家 avatar 创建流程。
> 教育设计承接 [[kids-thinking/overview]] 系列（A1 试用·还差一点 / A3 对比选择 / B1 分解式提问）。
> 技术底座复用 guided-creation（`server/src/adapters/openrouter_llm.ts:guideCreation` 一族）。

## 1. 要解决的问题（四个病灶，全部实锤取证）

1. **千篇一律**：现在是硬编码 4 题（性别/颜色/动物/兴趣，`scripts/onboarding.gd:38-66`），
   答案组合总共 2×4×4×4 = 128 种。全国小朋友挤在 128 个模板里，还都「抱着同一只玩偶」。
2. **答案不落服务器**：全部只写设备本地 `user://profile.json`（`player_profile.gd`）。
   进世界时 `upload_dict()` 只上报 name/gender/color 子集做 presence——`likes`/`interest`/自我介绍
   原文**根本不上传**（`player_profile.gd:104-119`）。服务端没有玩家档案实体，点点在世界里
   永远不知道这孩子喜欢什么。
3. **生图 prompt 无 LLM 思考**：描述是客户端字符串模板
   `"一个可爱的%s形象，穿着%s的衣服，抱着一只%s玩偶，一看就很喜欢%s"`（`player_profile.gd:45-49`）
   ——「手上拿东西」不是生图模型跑偏，是**模板亲手写进去的**。答案原样插值，中间零 LLM。
4. **零教育设计**：4 题全是偏好题（怎么选都行、选完即扔），生成后只有 ✓采纳/↻盲重掷。
   没有「需求→做→试→改」的任何一拍，与 kids-thinking 系列的两颗种子完全绝缘。

## 2. 核心机制

把「答题→生图」改成**两拍创作**：先「点点引导的多轮个性化对话」攒外观属性，
再「照镜子·改一改」完成试→改闭环。生图描述全程由 LLM 合成，答案全量落服务器。

### 2.1 新流程（页序）

| # | 页 | 变化 |
|---|---|---|
| 1-3 | 故事页 ×3 | 照旧 |
| 4 | **名字页（前移）** | 现有 intro 页原样搬到对话前——先知道名字，后面点点才能喊着「朵朵」引导，个性化的地基 |
| 5 | **引导式形象对话（新，3~5 轮）** | 点点动态提问 + 图标选项卡 + 开放语音，替代固定 4 题 |
| 6 | **照镜子·改一改（新）** | 生成出来后点点问「这是你吗？有没有哪里想变一变？」，孩子说改哪里→增量重生成，≤2 次必收尾，替代 ✓/↻ 盲盒 |

### 2.2 引导式形象对话（治病灶 1 + 4）

照抄 `guideCreation` 的会话形状（一次问一个属性、2-4 张图标卡、开放语音可跳出选项、
属性累积、够了就 done、反悔兜底），换成 avatar 专用的类别与 LLM prompt：

- **属性类别库**（`avatar_options.ts`，形状照 `creation_options.ts`）：
  `gender`（锚定轮，固定第一问，生图必需）、`hairstyle` 发型、`outfit` 衣服风格
  （运动服/小裙子/背带裤/恐龙连帽衫…）、`color` 主色、`motif` 最喜欢的图案元素
  （星星/恐龙/花朵/足球/彩虹…）、`accessory` 小配饰（发卡/帽子/围巾/眼镜…）。
- **个性化的来源有三**：
  ① LLM 按对话动态挑下一问（不再全国同一套题序）；
  ② **开放语音优先**——孩子说「我要会发光的头发！」不必落在卡上，LLM 归一进 attrs
  （`updatedAttrs` 机制现成）；
  ③ 类别库每类 6~10 项、每轮只摆 2-4 张卡，LLM 结合已知属性挑**搭配得上的**候选。
- **done 判定**：性别 + ≥2 个外观属性即可造；孩子说「就这样」立刻造；超 5 轮强制 done。
  3 岁坐不住，宁短勿长。
- **教育种子（B1 分解 + A3 合用，轻量版）**：
  - 问题按**部件**问（头发→衣服→图案→配饰）——「一个形象是由部分组成的」，
    分解-组合的种子藏在题序结构里，不上课。
  - 问句尽量带**功能场景**（A3 的「合用」感，但仍无对错）：
    「魔法森林里要跑要跳还要爬树，穿什么最方便呀？」——把「你喜欢哪个」往
    「哪个更合用」拧半圈。所有选项照旧都对、都夸，零挫败。
  - 点点只问不给答案（人设硬约束，`docs/fairy-persona-design.md`）。

### 2.3 LLM 合成外观描述（治病灶 3）

done 时**不再**由客户端拼模板，服务端 `describeAvatar(attrs, dialog)` 用 LLM 把属性+对话
汇成一段**纯外观**中文描述，prompt 写死硬规则：

- **双手空着、自然下垂或小动作**，绝不手持/怀抱任何物品；
- **头顶留空**（老板 2026-07-15 追加）：绝不戴帽子/皇冠/头盔——双手与头顶是贴纸装扮的
  锚点槽（character-anchors 三槽），形象自带头顶物会跟孩子贴上去的贴纸打架；配饰库也
  相应无任何头顶物（发卡/蝴蝶结=别在侧边头发或胸前，连帽衫兜帽垂在脑后）；
- 喜好一律**转译为衣服上的元素**：喜欢恐龙 → 恐龙图案连帽衫/衣服上的小恐龙刺绣，
  不是抱恐龙玩偶、也不是恐龙头套；喜欢踢球 → 球衣图案/运动鞋，不是抱着球；
- 只描述这一个孩子形象本身：不出现第二个角色、宠物、背景道具；
- 输出交给现有 `buildSpritePrompt` 拼 `SPRITE_STYLE_SUFFIX`（绿幕/朝右/贴纸风约束不变，
  `server/src/adapters/sprite_style.ts`）。

设置页「换形象」现在与 onboarding 共用客户端模板（`onboarding.gd:478-479`）——一并切到
这个服务端合成端点，模板函数 `avatar_description()` 退役。

### 2.4 照镜子·改一改（A1「试用·还差一点」移植到 avatar）

现在的 generate 页是 ✓/↻ 二选一：↻ 是完全盲重掷（同一个描述再掷一次骰子），孩子学到的是
「不满意=再抽一次」。改成 A1 的「试→定位维度→改」：

- 形象出来后点点问：「叮——变好啦！这是你吗？有没有哪里想变一变呀？」
- 孩子**说**想改哪（「头发要长一点」「衣服要蓝色的」）或点「就是我！」直接采纳；
- 服务端 `refineAvatar(description, childRequest)` 用 LLM 把增量**合并进描述**（只动孩子点名
  的维度，其余保持），重生成；
- **≤2 次必收尾**：第 2 次改完无论如何都欢呼采纳（终止性写在数据里，照 A1 的
  `refineTries` 闸）。「就这样」每一轮都可选，没有任何「不对」的反馈。
- 教育判断（非实测）：这是「做→试→改」在 onboarding 里最自然的一拍——孩子第一次
  体验「我说得越清楚，改出来越像我想的」。

### 2.5 服务端玩家档案（治病灶 2）

新增玩家档案存储（`store.savePlayerProfile`），onboarding 完成时全量上报：

```ts
interface PlayerOnboardingProfile {
  deviceId: string;            // 键——现有 upload_dict 已带 device 字段
  name: string; nickname: string;
  avatarAttrs: AvatarAttrs;    // 结构化答案（发型/衣服/图案/配饰/主色/性别）
  visualDescription: string;   // LLM 合成的最终外观描述
  refineNotes: string[];       // 照镜子环孩子提的修改（个性化金矿：「头发要长一点」）
  spriteAsset: string; anchors?: CharacterAnchors;
  createdAt: number;
}
```

- 价值：管理台可见每个孩子的档案；世界里点点/村民的 LLM prompt 注入喜好
  （「你不是最喜欢小恐龙嘛」——**当期接线**，老板已拍板：世界会话建立时按上报的
  device 查档案，把 名字/喜好图案/refine 原话 摘要注入对话类 LLM 的 system prompt，
  guideCreation 的 recentCreations 注入方式是现成先例）；换设备恢复的地基。
- 隐私边界：只存结构化属性 + 文本，**不存录音**（本就只传端侧 ASR 文本，音频不上行）。
- `user://profile.json` 照旧写（离线可玩的根基不动），服务端是副本不是依赖。

## 3. 关键设计问题

### 3.1 会话载体：HTTP 多轮，不是 WS

guided-creation 的 `CreationState` 挂在世界 WS `VoiceSession` 上，但 onboarding 发生在
进世界之前，现在是纯 HTTP（`/onboarding/intro` 无状态，`server.ts:666-667` 注释）。
**推荐：无状态 HTTP 多轮**——客户端每轮 `POST /onboarding/avatar-chat` 带
`{dialog[], attrs, childInput}` 全量，服务端跑一轮 `guideAvatar` 返回
`{replyText, question, optionIds[], updatedAttrs, done, description}`。
不复用 WS 会话管理，只复用 LLM 模式与选项库形状。代价是每轮多传几百字节对话历史，
换来服务端零会话状态、断线/杀进程天然无兜底负担（与现有 onboarding 架构一致）。

### 3.2 每轮 LLM 延迟怎么藏

`guideCreation` 单轮 1~3s。掩护：点点的 replyText TTS（edge-tts 首包 212ms）念上一轮的
回应/夸奖时，下一问已在路上；图标卡逐张弹入动画本身吃掉 ~1s。兜底：单轮 8s 超时
→ 静默回落到静态题库顺序出题（见 3.3）。

### 3.3 离线/失败回落：保留旧路径当降级

现有固定 4 题 PAGES 路径**不删**，降级链：LLM 对话不可用（离线/超时/审核失败）→
回落静态题序（从 `avatar_options.ts` 每类取前 4 项当卡，客户端本地拼简化描述——
模板去掉「抱着玩偶」措辞）。onboarding 是第一印象，宁可退到平庸也绝不卡住小朋友
（与现有「离线放行占位形象」同一条底线）。

### 3.4 图标资产从哪来

发型/衣服/图案/配饰 4 类 ×6~10 项 ≈ 30 张新图标，走现成 `generateCreationIcons`
管线（`/admin/creation-icons` 先例，统一画风 + die-cut 白边）。颜色类继续用纯色块
（现有 `_option_button` 已支持）。生成清单校验照 guided-creation P3 的做法。

### 3.5 重生成成本与预取

照镜子环最多 3 次生图（首次 + 2 次 refine）。首次照旧在名字页说话时后台预取
（`_start_avatar_prefetch` 机制保留，只是描述来源从本地模板换成对话 done 的产物）。
refine 重生成无法预取，孩子要真等 ~1min——点点垫场词 + 现有生成中动画兜住
（guided-creation 造角色同款等待，已验证 3 岁能接受）。

### 3.6 为什么不做 B1 式「部件树形象」

形象立绘是一张 AIGC 整图 + vision 锚点，不是可拆组合体。把 avatar 做成零件树
（发型/衣服独立贴片叠加）意味着换装系统级重做，且美术缝隙风险高（B1 文档 §3.1 的
反面路线）。本期教育种子只借 B1 的**提问结构**（按部件问）与 A1 的**试改环**，
不动渲染架构。将来若做换装再议。

## 4. 实现（预估分 P，待老板拍板后立 plan）

- **P1 服务端**：`AvatarAttrs` + `avatar_options.ts` 选项库 + `guideAvatar`/`describeAvatar`/
  `refineAvatar` 三个 LLM 接口（mock + openrouter 双实现，照 `guideCreation` 先例）；
  单测（属性累积/done 判定/超轮强制 done/描述含「双手空着」约束词/refine 只动点名维度）。
- **P2 服务端**：`POST /onboarding/avatar-chat`（无状态多轮）+ `POST /player/profile` 落库
  + 管理台档案页只读展示；`/player-sprite` 加 refine 入参；单测。
- **P3 图标资产**：4 类 ~30 张图标批量生成 + 校验清单。
- **P4 客户端**：onboarding 对话页（复用 `VoiceCapture`/`VoiceWave`/图标卡 UI 三件套）+
  名字页前移 + 照镜子页 + 降级链 + 设置页「换形象」切服务端合成；headless 冒烟。
- **P5 服务端喜好接线**：世界会话按 device 查档案 → 喜好摘要注入点点/村民对话类
  LLM prompt（照 `recentCreations` 注入先例）；单测（有档案注入/无档案不注入）。
- **P6** 全套回测 + 真机手感（延迟/轮数/refine 语感/喜好被点点提起）+ merge --no-ff
  （老板验收门）。

## 5. 验收

- **服务端单测**：guideAvatar 同一输入 mock 确定性；done 后描述非空且不含「抱着/拿着/手持」
  字样（结构化断言防回归）；refine 保持未点名属性不变；超 5 轮必 done；档案落库可查。
- **生成质量抽查**：同一批 10 组不同对话 → 10 段描述两两不同（多样性）；生成图 vision
  抽查双手不持物（复用 `ensureFacingRight` 的 vision 通道加一问，仅测试脚本用不进生产链）。
- **headless**：对话页出卡/点卡/语音归一；LLM 超时回落静态题序不卡页；照镜子环 2 次后
  必进世界。
- **真机（老板）**：全流程手感——轮次长度 3 岁坐不坐得住、refine 说「头发长一点」改出来
  像不像、离线降级无感。
