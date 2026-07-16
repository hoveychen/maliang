# 小仙子引路（guide）设计

> 目标：孩子说「带我去风车那儿」「我想找小明」，小仙子能真的把他带过去——包括目标在**另一个场景**的情况。

## 1. 现状：她为什么带不了路

小仙子不会走路，不是遗漏，是**三层刻意封死**的设计：

| 层 | 位置 | 做法 |
|---|---|---|
| 服务端源头 | `server/src/types.ts:26,35` | `LOCOMOTION_ABILITIES`（move_to / follow / stop_follow / chat_with / deliver_message）对 `isFairy` 直接剔除 —— LLM 的 prompt 里连这些词都看不见 |
| 客户端行为脚本 | `scripts/world.gd:5569-5574` | `_run_behavior` 对 `is_fairy` 早返回，移动脚本一律丢弃 |
| 舞台演出 | `scripts/world.gd:5828,5860`；`server/src/screenplay_gen.ts:182` | `stage_move`/`stage_follow` 对她视作已到位；剧本选角把她过滤掉 |

`types.ts:28-34` 的注释讲清了动机：给她 `move_to`，LLM 就会说「好呀，我们去风车那儿」，然后人纹丝不动——孩子听见了承诺，看见的是原地发呆。**与其在下游拦，不如源头不给。**

这个决策是对的，本设计**不推翻它**。仙子依然不吃 `BehaviorExecutor`、依然不能当剧本演员。引路走一条独立通道。

此外还缺两块，是「找村民」的硬门槛：

- **花名册按场景取**（`server/src/voice.ts:77-80`），POI 地点表同理（`persistence.ts:795`）。孩子在村庄说「找小明」而小明在森林 —— LLM 的上下文里根本没这个人。
- **没有任何传送下行**。全仓 grep `teleport` / `warp` 零命中。换场景只能靠玩家自己走进 portal 半径（`world.gd:3349-3358` `_step_portal`），服务端 `enter_scene`（`server.ts:2675`）是**纯被动响应**。

## 2. 三个设计决策

### 决策 A：仙子在前面飞，孩子自己走 —— 不自动走玩家的 avatar

客户端其实**已经能自动走玩家**：`_stage_drive()`（`world.gd:6062`）会给 player 字典挂 `BehaviorExecutor`，`stage.moveTo(player, '风车')` 是真的会走。但那条路只在**演出**里存在，而演出**吞掉玩家输入**（`world.gd:5728-5742`）。

对幼儿产品，让孩子在一分钟里失去操控、看着自己的小人自动走过去，是把**玩法降格成过场动画**。所以引路不复用它：

> 仙子飞到前方 → 回头等 → 孩子自己走过去 → 她再飞下一段。

「跟着仙子走」本身就是玩法。而且孩子中途想停下看看别的，随时可以——她会等，或者飞回来催。

### 决策 B：跨场景不传送，把孩子带到 portal 门口

诱惑很大：加一条 `teleport` 下行，服务端喊一嗓子客户端就 `enter_scene()`（`world.gd:3652` 本来就是 public，纸手机「回家」app 就这么干的，`world.gd:3668`）。

但那样孩子会**突然被瞬移**，且完全不知道两个场景之间原来是连着的。而 portal 连通图已经建好了（13 场景 ~3 portal 双向边，BFS 可达性测试在 `test/test_portal.gd:99-111`）。所以：

> 引路把**跨场景**这件事翻译成**一串同场景引路**：这一段带你走到通往森林的门，你自己走进去（既有 `_step_portal` 照常触发），到了森林我接着带你走下一段。

零新增传送报文、零控制权剥夺，而且顺便教会了孩子世界的拓扑。

### 决策 C：新增独立 ability `guide_to`，只给仙子

不解封 `LOCOMOTION_ABILITIES`（那会让 LLM 又开始让她 `follow`、`chat_with`，全是她兑现不了的）。新增一个**只有她有**的能力：

```
guide_to  —— 带小朋友去某个地点，或去找某个角色。
            params: { location_name?: string, character_name?: string }
```

它和 `create_prop` / `play_game` 一样，**不是 BehaviorExecutor 的指令** —— 在 `voice.ts:116-161` 的分派处被**摘走**，转成 `VoiceResponse.guide` 下发，走客户端的引路状态机。这样 `_run_behavior` 的 `is_fairy` 早返回（`world.gd:5573`）一行都不用动。

## 3. 服务端设计

### 3.1 跨场景索引（新）

`voice.ts` 的 roster 保持不变（它服务于 `move_to`「小蓝跟我来」，那确实该限本场景——你没法命令一个不在场的人）。引路需要的是**另一份**上下文：

```ts
// IntentContext 新增
/** 全世界的角色/地点索引（含所在场景名）：只服务 guide_to——孩子要找的人可能不在眼前。 */
guideTargets?: { name: string; sceneId: string; sceneName: string; kind: 'character' | 'location' }[];
```

对应 store 侧新增：

- `store.listCharactersAll(worldId)` —— 已有 `listCharacters(worldId, sceneId?)`（`persistence.ts:1024`，sceneId 缺省即全世界），**直接可用**，只需过滤掉仙子自己。
- `store.listLocationsAll(worldId)` —— 现有 `getLocations()`（`persistence.ts:795`）是 scene-scoped，需新增一个带 sceneId 的全量版。POI 存在 `Scene.pois`（`types.ts:145`），遍历 scenes 即可。

prompt 里注入一行：`可以带小朋友去的地方和人：风车(村庄)、小明(森林)、灯塔(海边)…`

### 3.2 portal 寻路（新）

服务端目前**没有** portal 图的寻路代码——BFS 只活在 `test/test_portal.gd` 的测试断言里。新增：

```ts
// server/src/scene_graph.ts（新文件）
/** 在 portal 图上找从 from 到 to 的最短场景路径。返回逐跳的 portal 落点；不可达返回 null。 */
export function routeScenes(store, worldId, from, to): SceneLeg[] | null
export interface SceneLeg { sceneId: string; portalTile: [number, number]; toScene: string }
```

纯 BFS，边来自 `Scene.portals`（`types.ts:125-131`，`{tile, radius, toScene, toTile}`）。13 个场景、~40 条有向边，规模上可以每次现算，不做缓存。

### 3.3 引路计划（下行）

```ts
// VoiceResponse 新增
guide?: GuidePlan;

export interface GuidePlan {
  /** 找人还是找地方——决定到达时的收尾（找人：让他打招呼；找地方：仙子说「到啦」）。 */
  targetKind: 'character' | 'location';
  targetName: string;
  /** 目标所在场景与落点。character 的 tile 只是**下发时的快照**，客户端到场后按名字重解析。 */
  targetScene: string;
  targetTile: [number, number];
  /** 从玩家当前场景到目标场景的逐跳 portal；同场景时为空数组。 */
  legs: SceneLeg[];
}
```

分派处（`voice.ts` 与现有 4 个 create_*/play_game 摘取并列）：

```ts
const guideCmd = intent.behaviorScript.commands.find((c) => c.type === 'guide_to');
if (guideCmd) {
  const plan = planGuide(store, worldId, session.currentScene, guideCmd.params);
  if (plan) response.guide = plan;
  else response.replyText = /* 兜底：由 LLM 已生成的口头回应改写，或用「我也不知道他在哪呀」 */;
  intent.behaviorScript.commands = intent.behaviorScript.commands.filter((c) => c.type !== 'guide_to');
}
```

**不可达 / 找不到人时不发 guide**，只留口头回应——绝不能出现「好呀跟我来」然后没人动，那正是 `types.ts:28` 当初要防的病。

## 4. 客户端设计

### 4.1 引路状态机（复用 POI 飞行骨架）

仙子已经会「飞向一个点、说句话、再飞回来」：`_fairy_poi` + `_step_fairy_poi`（`world.gd:882-915`）。引路是它的推广版，新增 `_fairy_guide`：

```gdscript
var _fairy_guide := {}  # { plan, leg_idx, waypoint: Vector2, state, nudge_t, elapsed }
```

`_update_fairy`（`world.gd:846`）的分支优先级（现有是 对话 > POI > 跟随）改为：

```
对话中  >  引路中  >  POI 提醒  >  跟随玩家
```

引路中每帧：

1. 算当前 leg 的 **waypoint**：若还有未走完的 portal leg → 该 portal 的 tile；否则 → 目标点（`targetKind == 'character'` 时用 `_resolve_char_pos(name)`（`world.gd:5597`）**动态重解析**，因为村民会自己晃）。
2. **领飞**：仙子朝 waypoint 飞，但距玩家距离封顶（复用 `POI_FLY_CAP` 的思路，值另调大些）——她永远在孩子视野内，不会飞没影。
3. **回头等**：飞到封顶位置后停住悬浮，播「跟我来呀」类台词（`fairy_voice`，需在 `lines.json` 加一组引路词）。
4. **催促 / 追回**：孩子 `NUDGE_INTERVAL`（~8s）没靠近 → 仙子飞回玩家身边说一句再重新起步。孩子跑反了也不取消，只是重新起步。
5. **到达 waypoint**：
   - portal leg → 什么都不做，既有 `_step_portal()`（`world.gd:3349`）会在孩子走进半径时自动 `enter_scene`。`_fairy_guide` 需在场景切换中**存活**（`enter_scene` 的清理路径要放行它），进新场景后 `leg_idx += 1` 继续。
   - 最后一段 → 到达收尾。
6. **到达收尾**：仙子说「到啦到啦，就是这里～」（预制台词 `guide_arrive`），清空 `_fairy_guide`。

   > **实现时的修正**：原设计写的是「找人时自动触发与目标角色的招呼」。落地时否掉了——自动进对话会开麦、切近身相机，等于**替孩子决定他要跟这个人说话**，与「引路全程不夺操控权」的主旨自相矛盾。现在到达即收尾，孩子自己点村民开口。

### 4.2 取消 / 挂起

| 情形 | 处理 |
|---|---|
| 孩子进对话（点了仙子或村民） | 引路**挂起**（她停在原地听，现有对话分支优先级更高）；退出对话后继续 |
| 新的 `guide_to` 下来 | 覆盖旧计划 |
| 孩子说「不去了」 | **双保险**（老板 2026-07-13 拍板）：① 客户端 UI 一点即停；② 给她 `guide_stop` 能力，LLM 听懂「不去了」也能下发取消 |

**取消入口不能和「点她进对话」打架**：引路中点她本体 = 照常进对话（引路挂起，聊完继续）——孩子引路途中想跟她说话是正当需求，不能剥夺。所以取消走一个**独立的可见入口**。

> **实现时的修正**：原设计是「她头顶挂一个可点的停止气泡」。落地时改成了**独立的 HUD 按钮**（`guide_stop_button`，屏幕顶部居中，文字「不去了」）。两个原因：① 头顶气泡和她本体挤在同一个 3D 身位上，幼儿的手指必然误触，一半的时候会点进对话；② 3D 拾取还得新拉一条 `Area3D` + 输入路由，而气泡本来就会被角色和地形遮挡。HUD 按钮位置固定、任何时候都点得到。对话中自动收起（`_sync_guide_button`），退出对话回来。
| 开演（stage_begin） | 取消引路（演出要吞输入） |
| 总时长超 `GUIDE_TIMEOUT`（~3 min） | 放弃，说一句「我们下次再去吧」 |
| 断线重连 | 引路计划是**客户端状态**，重连即丢失，孩子重说一次。第一版不做服务端持久化 |

### 4.3 不碰的东西

- `_run_behavior` 的 `is_fairy` 早返回（`world.gd:5573`）—— 一行不动
- `stage_move`/`stage_follow` 的仙子早返回 —— 一行不动
- `LOCOMOTION_ABILITIES`（`types.ts:26`）—— 一行不动
- 玩家 avatar 的控制权 —— 全程在孩子手里

## 5. 分期

| P | 内容 | 验收 |
|---|---|---|
| **P1** | 服务端：`guide_to` / `guide_stop` 能力 + `ABILITY_DESC` 条目 + prompt 规则行 + mock 关键词分支 + `voice.ts` 摘取分派 + `GuidePlan` 类型。**同场景**：目标限当前场景的 POI / 角色，`legs` 恒为空。单测 | 说「带我去风车」→ 服务端出 `guide`，`legs: []`，targetTile 对得上 POI |
| **P2** | 客户端 `_fairy_guide` 状态机（领飞 / 回头等 / 催促 / 到达收尾）+ 「停止」气泡取消入口 + 引路台词入 `lines.json` + headless 测试 | headless：下发 guide → 仙子朝目标方向移动、玩家走近后状态机推进到到达；点停止气泡即清空 |
| **P3** | 跨场景：`scene_graph.ts` BFS（**限 2 跳**）+ 跨场景 `guideTargets` 索引 + portal leg 推进（含 `enter_scene` 中 `_fairy_guide` 存活）+ 单测 & headless | 村庄说「找小明」（小明在森林）→ 带到 portal → 孩子走进去 → 森林里接着带到小明身边 → 小明打招呼；3 跳目标被拒并出口头兜底 |
| **P4** | 兜底打磨（不可达 / 目标消失 / 超时 / 开演取消 / 目标村民走动追击）+ 全套回测 + merge | server 单测 + headless 全绿；真机手感留老板 |

老板 2026-07-13 定：**P1-P4 一次做完**（不做 P1+P2 的中途发版），避免同场景协议先上线后被跨场景倒逼返工。

## 6. 已拍板的取舍（老板 2026-07-13）

1. **取消引路 = 双保险**：客户端「停止」气泡（一点即停）**并且** `guide_stop` 能力（LLM 听懂「不去了」）。见 §4.2。
2. **目标村民不钉住**：最后一段动态重解析他的位置（复用 `_resolve_char_pos`，`world.gd:5597`），他跑仙子就追。世界保持活的；极端情况靠 `GUIDE_TIMEOUT` 兜底。**不新增「冻结某角色」的控制通道。**
3. **跨场景引路限 2 跳**：`routeScenes` 返回的 `legs.length > 2` 时**不发 guide**，仙子改口「太远啦，我们先去近的地方吧」。3-5 岁孩子的注意力扛不住 3-4 跳 portal 的长途跋涉。这条是 `planGuide` 的硬约束，写进单测。
