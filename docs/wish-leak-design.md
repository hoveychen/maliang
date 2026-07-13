# 心愿漏话（wish leak）——把「玩法说明」换成「让小朋友自己发现」

## 1. 要解决的问题

小朋友怎么知道这个世界里能造东西、能玩球、能让小仙子带路？现在只有两条路，两条都不好：

**病灶一：仙子在打广告。** `assets/voice/fairy/lines.json` 里 `guide_hint` 三条是赤裸的功能说明——「想去哪儿玩呀？告诉我，我带你去！」「这个世界大着呢，想去哪儿我都能带你去哦。」`fairy_idle_3` 也一样：「要不要去找小伙伴一起玩呀？」这是在**告诉**小朋友「你可以让我做 X」。听懂了也只是执行了一条指令，不是发现。

**病灶二：村民一句话都不主动说。** 村民只会在小朋友走近时挥个手、头顶冒个表情图（`world.gd:2421 _update_npc_notice`），完全无声。造物 / 造角色 / 造贴纸 / 玩游戏这些玩法，除了仙子那三句广告，小朋友没有任何线索。

要的效果是反过来的：**角色不经意漏出自己想做什么、在做什么，小朋友好奇了自己凑上去问，玩法是他「挖」出来的。**

## 2. 核心机制

每个村民揣一个**当下心愿**，小朋友在附近时会自言自语漏一句——只说自己想要什么，绝不说「你可以让我…」：

| 勾的玩法 | 漏话 |
|---|---|
| `create_prop` | 「我家门口空落落的…要是有棵会开花的树，该多好呀。」 |
| `create_character` | 「一个人搭积木好没意思…要是有个小伙伴陪我就好啦。」 |
| `create_sticker` | 「别人衣服上都有亮晶晶的小星星…就我这儿光秃秃的。」 |
| `play_game` | 「我捡到一个球！可是…一个人踢好像不好玩。」 |
| `guide_to`（仙子） | 「我昨天飞过一个地方，那儿的花会发光呢…可惜好远好远。」 |

两个让「发现感」真正成立的机关：

1. **已发现的不再提。** 小朋友第一次成功造出东西后，`create_prop` 进 `discovered`，全世界再没人漏造物的话。每一句漏话永远指向他还没玩过的东西——不啰嗦，且总是新的。
2. **心愿要兑现。** 他真的帮村民造了树，那个村民得**认出来**并激动感谢。少了这步，漏话就只是句怪话，小朋友做完了没人理他，满足感为零。

## 3. 关键设计问题：村民不会魔法

小朋友听见村民想要树，最自然的反应是**直接跟村民说**「我给你造」。但造物是**小仙子的能力**（`server.ts:127 seedFairy` 的 abilities），村民没有。村民 LLM 会说「好呀」然后什么都不发生 → 这是挫败，不是发现。

**不能靠加 prompt 规则硬拦**（「你要引导他去找小仙子」——那又变回强说明了）。

**解法：把心愿接进现有的委托系统（`tasks.ts`），复用它已经跑通的三段结构。** 小朋友对村民说「我帮你」，村民走现成的 `offerTask` 把心愿变成一条 `ActiveTask`（type=`wish`）。而 `ActiveTask` 是注入**所有**角色 prompt 的——包括始终跟在小朋友身边飞的小仙子。于是：

```
村民漏话「要是有棵树…」
  → 小朋友凑过去搭话
  → 村民 offerTask，心愿变成 activeTask（世界记住了这件事）
  → 小朋友随便在哪儿跟仙子说「造棵树」甚至只说「帮帮他」
  → 仙子 prompt 里有 activeTask，知道要造什么 → 真的造出来
  → 服务端判定心愿达成 → 盖章 + 村民用自己的声音道谢
```

链条只有「听见怪话 → 搭话 → 说我帮你 → 仙子造出来」，3 岁小朋友走得完。

**兜底：链断了也不亏。** 就算小朋友没搭话村民、只是听见漏话后自己跑去让仙子造了个别的东西——`create_prop` 照样进 `discovered`，漏话池照样换新的。发现感不依赖整条链走通。

## 4. 实现

### 4.1 服务端

**`server/src/wishes.ts`（新）** —— 静态心愿库，形状照抄 `greetings.ts`（零 LLM 成本、可单测、确定性）：

```ts
export interface WishDef {
  ability: string;        // 勾的玩法
  leaks: string[];        // 漏话（自言自语，绝不含「你可以」）
  context: string;        // 注入该村民 routeIntent prompt 的背景（"你一直盼着门口有棵会开花的树"）
  thanks: string[];       // 兑现时的感谢（走 pushPraiseTts，村民自己的音色）
}
export const WISHES: Record<string, WishDef>;
export const IDLE_DOING: string[];  // 心愿池耗尽后的纯氛围自语（"我在数天上的云…一朵，两朵…"）
```

- **认领**：村民按 `characterId` 稳定哈希从「未被玩家发现的能力池」里认领一个心愿（同一村民对同一玩家永远同一个心愿，直到该能力被发现）。纯函数 `wishFor(characterId, discovered)`，不落库。
- **`Player.discovered: string[]`**：玩家已发现的玩法。在 `create_prop` / `create_character` / `create_sticker` / `play_game` / `guide_to` **成功**的那几个代码点写入。
- **`TaskType` 加 `'wish'`**，`ActiveTask` 加 `wishAbility` / `wishText`。完成判定不走客户端 `task_event`（服务端自己就在造物成功的那个代码路径上），新增 `completeWishOnAbility(worldId, playerId, ability, store)`，复用 `addStamp` + `pushPraiseTts`。

### 4.2 声音：距离衰减（老板的硬要求）

漏话不是对话，是**环境音**。全音量播 = 一屋子人在聊天房喊话。

- 客户端 `scripts/npc_wish_voice.gd`（新）：每个村民一个 **`AudioStreamPlayer3D`** 挂在角色节点上 → 天然距离衰减（`unit_size` / `max_distance` 调参）。远处只是隐约听见一句嘟囔，走近了才听清——这本身就是勾好奇心的一部分。
- 合成走现成的客户端 edge-tts（`_speak_line` 那条路，用村民自己的 `voiceId`）→ **零服务端 TTS 成本**。
- **绝不占用 `_tts_player`**：那是对话通道，`_tts_player.playing` 直接决定开麦门禁（`InteractionFsm.tts_busy`）。漏话若占用它会闭麦——小朋友想搭话的那一刻正好说不了话，恰好毁掉整个机制。

### 4.3 调度（防噪音）

漏话必须**稀**。一个村民每两分钟嘟囔一句，路过时听见半句——这才叫不经意。

- 可听半径内（`AudioStreamPlayer3D` 的衰减自然收敛）+ 该村民不忙（不在对话/不在演出）
- 每村民冷却 120s；跨角色全局间隔（与 `FairyVoice.GLOBAL_GAP` 互斥，不叠声）
- `InteractionFsm.player_engaged()` 期间一律闭嘴（照抄 `_fairy_ambient` 的门禁）

### 4.4 仙子台词库去广告

`assets/voice/fairy/lines.json`：`guide_hint` 三条 + `fairy_idle_3` 改写成心愿式，重跑 `server/tools/gen_voice_lines.mjs` 预制 WAV。

**保留 intro 的手势教学**（`intro_walk_ask` 点地走路 / `intro_talk_ask` 对着话筒说话）。那是**操作**教学，不是玩法说明——3 岁小朋友不教不会点地。本设计针对的是玩法说明。

## 5. 验收

- 服务端单测：心愿认领对同一 id 稳定；已发现能力不再被认领；池耗尽回落 `IDLE_DOING`；`completeWishOnAbility` 只匹配对应 ability 且盖章一次。
- headless：漏话调度（冷却/全局间隔/engaged 闭嘴）；`AudioStreamPlayer3D` 挂在角色节点上且不碰 `_tts_player`。
- 真机（老板）：距离衰减手感——走近听清、走远只剩嘟囔；漏话密度不烦人。
