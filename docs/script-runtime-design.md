# 剧本系统设计：TS 脚本运行时 + 舞台协议

> 2026-07-10 与老板共同拍板。目标：让多角色联动演小剧场（动态剧本），并支持现场"造一个游戏"（躲猫猫/老鹰捉小鸡），带 HUD 控制。

## 决策记录

| 决策 | 结论 | 理由 |
|---|---|---|
| 脚本语言 | **TypeScript**（不自造 JSON DSL） | 老板明确要求用 agent 天生熟悉的语言；自造 DSL 每次都要在 prompt 里教 schema，对 LLM 能力要求过高 |
| 执行场所 | **服务端 Node 沙箱**（路线 A） | 零新依赖（Node 26 原生 `stripTypeScriptTypes` + `node:vm`，已实测）；不碰 Android 构建链路；剧本能力升级不用重导 APK。Stage API 设计成场所无关契约，留将来平移端侧 JS 引擎的后路 |
| 架构关系 | **游戏运行时 ⊇ 剧场** | 剧场 = 只有顺序 await 的脚本；游戏 = 同一套能力 + 事件订阅/HUD/胜负。先建通用运行时，剧场是跑在上面的一类脚本 |
| 剧场生成 | **大纲先行 + 逐幕生成** | 一次 LLM 出大纲（幕列表+选角+道具），每幕开演前生成本幕脚本；小朋友可被选角，轮到时开麦提词 |
| 多人（同世界 2-6 人） | **纳入本期 Plan 1**（老板拍板提前） | 采用「单一模拟所有权 + 状态复制」，**不走确定性 lockstep**——随机数种子与 tick 时钟同步整个问题被架构消解，见下方多人架构节 |

## 架构总览

```
┌─ 服务端 ────────────────────────────────┐   ┌─ 客户端 (Godot) ──────────────┐
│  LLM 生成层                              │   │                               │
│   大纲(JSON mode) → 逐幕(TS 代码)         │   │  StageAgent (新, GDScript)     │
│        ↓                                │   │   ├→ BehaviorExecutor(已有)    │
│  ScriptRunner (新)                       │   │   │   move_to/follow/action   │
│   worker_threads + node:vm 沙箱          │◄──┤   ├→ TTS: say/narrate         │
│   只暴露 Stage SDK                        │WS │   │   (edge-tts 按角色音色)     │
│   超时/步数预算/断连终止                    │──►│   ├→ HudFactory (新)          │
│        ↓↑                               │   │   ├→ add_dynamic_prop(已有)    │
│  舞台协议: stage_cmd ↓ / stage_event ↑    │   │   └→ 相机/横幅(已有)           │
└─────────────────────────────────────────┘   └───────────────────────────────┘
```

- **ScriptRunner**（服务端新增）：每个活动剧本一个 worker，`vm.createContext` 只注入 Stage SDK 宿主对象。LLM 写的 TS 经 `node:module.stripTypeScriptTypes()` 剥类型后在沙箱执行。脚本 `await` 的每个舞台调用翻译成 `stage_cmd` 下发，客户端完成后回 `stage_event`(ack) 才 resolve —— **TS 的 async/await 天然就是编排语义**：顺序 = 依次 await，多角色并行 = `Promise.all`，同步点 = await 汇合。
- **StageAgent**（客户端新增）：`stage_cmd` 的总分发器。复用现有机制执行，完成回报 `stage_event`。新增的只有 HudFactory 和事件上报（靠近/计时/点击/到达）。
- **威胁模型**：脚本由自家 prompt 驱动 LLM 生成，非对抗性输入。`node:vm` + worker 隔离 + 超时/内存上限对这个模型足够；不承诺抵御恶意代码（如需，将来换 isolated-vm，SDK 契约不变）。

## Stage SDK（给 LLM 的 .d.ts，节选）

> 下面是拍板时的草案。**权威版本已落到 `server/src/screenplays/stage_sdk.d.ts`**（Plan 2 直接把它拼进 prompt），
> P8 用两个手写剧本磨过一轮，差异见文末「P8 API 手感回填」。

```typescript
interface Actor {
  readonly id: string;
  readonly name: string;
  readonly isPlayer: boolean;           // 小朋友本人也是 Actor，可被剧本调度
  moveTo(target: string | Tile): Promise<void>;   // 地点名/角色名/坐标，寻路走过去
  say(text: string, action?: 'wave'|'jump'|'spin'|'nod'): Promise<void>; // 用自己音色 TTS，说完 resolve
  do(action: 'wave'|'jump'|'spin'|'nod'): Promise<void>;
  follow(target: Actor): void;          // 持续跟随（客户端本地执行，不过网）
  flee(from: Actor): void;              // 持续逃离
  stop(): void;
}

interface Stage {
  actors: Actor[];                      // 当前世界所有角色（含 player 和小仙子）
  player: Actor;
  narrate(text: string): Promise<void>; // 旁白（小仙子音色），说完 resolve
  banner(text: string): void;           // 顶部横幅
  prop: {
    create(desc: string, near: string | Tile): Promise<Prop>;  // 复用语音造物管线
    place(id: string, at: Tile): Promise<void>;
    remove(id: string): void;
  };
  hud: {
    score(label: string): Counter;      // 计分板
    countdown(sec: number): Timer;      // 倒计时（归零触发 onDone）
    toast(text: string): void;
  };
  camera: { focus(a: Actor): void; overview(): void; dialog(a: Actor, b: Actor): void; reset(): void };
  on(ev: 'near', a: Actor, b: Actor, dist: number, fn: () => void): Unsub;  // 客户端检测，触发才过网
  on(ev: 'tap', a: Actor, fn: () => void): Unsub;
  sleep(sec: number): Promise<void>;
  prompt(actor: Actor, hint: string): Promise<string>; // 小朋友的戏份：横幅提词+开麦，返回他说的话
  end(result?: { winner?: string; praise?: string }): void;
}
```

### 示例 1 · 三幕小剧场（丑小鸭，剧场=顺序脚本）

```typescript
const [duck, mama, swan] = cast('丑小鸭', '鸭妈妈', '天鹅');   // 选角结果由生成层注入
await stage.narrate('从前，池塘边住着鸭妈妈一家。');
await Promise.all([duck.moveTo('pond'), mama.moveTo('pond')]); // 并行走位，都到齐才开演
await mama.say('我的孩子们要出壳啦！', 'wave');
const egg = await stage.prop.create('一颗大大的蛋', 'pond');
await duck.say('大家都笑我长得丑……');
await stage.narrate('冬去春来，丑小鸭长大了。');
```

### 示例 2 · 躲猫猫（游戏=事件驱动脚本）

```typescript
const seeker = stage.actors.find(a => !a.isPlayer)!;
const score = stage.hud.score('抓到');
await stage.narrate('躲猫猫开始！' + seeker.name + '当鬼，大家快躲好！');
await stage.sleep(10);                       // 藏的时间
seeker.follow(stage.player);                 // 追逐在客户端本地跑，不过网
stage.on('near', seeker, stage.player, 2, () => {   // 只有"抓到"这个判定过网
  score.add(1);
  stage.end({ winner: seeker.name, praise: '你藏得真好，坚持了好久！' });
});
const t = stage.hud.countdown(60);
t.onDone(() => stage.end({ winner: '躲藏方' }));
```

### P8 API 手感回填

两个手写剧本（`server/src/screenplays/hide_and_seek.ts`、`three_act_play.ts`）跑通端到端后，SDK 相对上面的草案改了三处：

1. **新增 `stage.params`** —— 开演时注入的旋钮（藏身时长、一局时长、判定距离、落点名）。草案里这些常量只能写死在脚本里，
   结果是难度不可调、测试要真等 10 秒藏身。剧本一律 `Number(stage.params.x ?? 默认值)` 读，不注入也能自己跑起来。
2. **新增 `stage.once(ev, …): Promise`** —— 一次性事件，首次触发即退订。草案只有 `on()` 回调，事件驱动的游戏脚本
   只能层层嵌套；`once` 让「布判定 → 放角色 → await 结果」写成直线，躲猫猫的两轮换鬼因此是顺序代码而非状态机。
   它同时消掉一个竞态：**先 `once()` 再下 `follow/flee`**，订阅消息先于命令抵达服务端，第一帧就不会漏判。
3. **`stage.prompt()` 返回字符串**（草案承诺、实现原本返回 `{ text }`）—— 已按草案改，剧本可以直接把孩子说的话拼进剧情。

还有一条**节奏**上的教训：`stage.prop.create()` 要真跑一趟 LLM + 生图，几十秒卡在幕中间，演出就断了。
所以三幕小剧场现在一件道具都不造（原语覆盖挪进了 `screenplay_e2e.test.ts` 的单测）。等造物能**预热**——
开演前把整场的道具一次性造好，幕间只管 `place()` 落位——再把蛋和镜子加回来。生成层出大纲时就该把道具清单
交给造物管线预造，这和「幕间小仙子报幕掩护逐幕生成延迟」是同一个道理。

### 运镜的抽象层级：脚本说意图，宿主负责取景（2026-07-10 老板拍板）

真机第一次试演暴露了两件事：镜头压根没实现（`stage_agent` 里 camera 是空转 `_ack`），以及实现之后
`overview` 用了**写死的拉远距离**，三个村民散在 150 单位宽的村庄里，镜头飞到几何中心时画面里一个人都没有。

老板由此定下一条原则：**取景不该是脚本的事**。LLM 实时生成剧本时不可能知道演员离多远、地图多大、
屏幕多宽。所以 `stage.camera.*` 只能是一组**预设镜头意图**——`overview`（把这场戏的所有演员框进画面）、
`focus(a)`（贴一个人）、`dialog(a,b)`（双人构图）、`reset`（还给孩子）——具体拉多远、抬多高、
演员走动时如何持续跟，全部由客户端宿主按当前演员位置逐帧算。脚本只负责说「现在该看谁」。

推论：**不要**给 SDK 加 `camera.moveTo(x, y)` / `camera.setZoom(n)` 这类数值型接口，那是把取景责任
推回给 LLM。要加新镜头就加新的**具名意图**（如 `camera.chase(a)` 追逐视角、`camera.wide()` 大远景），
每一个都在宿主里实现成一套构图规则。

还有一条给生成层的硬约束：剧本是**异步函数体**，不是模块。没有 import/export、没有 `require/process/setTimeout`，
全局只有 `stage` / `cast` / `console.log`。`server/test/screenplay_typecheck.test.ts` 就是照这个约束对 d.ts 编译的，
Plan 2 可以直接复用它校验 LLM 的产物。

## 舞台协议（WS 消息）

- 下行 `stage_cmd`：`{ type:'stage_cmd', cmdId, actorId?, op, args }`。op 与 SDK 方法一一对应；`moveTo/say/do/narrate/prop.create` 等有完成语义的携带 cmdId 等 ack。
- 上行 `stage_event`：`{ type:'stage_event', kind:'ack'|'near'|'tap'|'timer'|'prompt_result', cmdId?, ... }`。
- 生命周期：`stage_begin`（客户端锁交互模式，进"观演/游戏"状态）/ `stage_abort`（任一侧终止：脚本异常、超时、小朋友说"不玩了"、断连）/ `stage_end`（正常收场+奖励结算钩子）。
- 高频行为（follow/flee/wander）是**设置型命令**：下发一次，客户端持续执行，不逐帧过网。规则判定（near 等）由客户端检测、事件触发才上行，WS 往返 ~100-200ms 对"抓到了/换鬼"级别的判定无感。

## LLM 生成层（Plan 2）

1. **意图识别**：`routeIntent` 扩一类 `screenplay` 意图（"我们来演丑小鸭吧"/"我们来玩躲猫猫"）。
2. **大纲**（JSON mode，沿用现有校验+兜底模式）：幕列表、选角（现有角色映射到戏中角色，**小朋友可占一角**）、道具清单（缺的现场 `prop.create`）。
3. **逐幕生成**：每幕开演前生成该幕的 TS 函数体（prompt 携带 .d.ts + 大纲 + 前幕摘要）。校验 = strip 后 `new vm.Script()` 编译，语法错自动重试一次，再败则该幕降级为纯旁白讲述（演出不崩）。
4. **小朋友的戏份**：`stage.prompt()` 横幅提词+开麦，ASR 结果回填剧情（下一幕生成时带上他说的话）。
5. 幕间小仙子报幕/串场，掩护逐幕生成延迟。

## 多人架构：为什么不需要同步随机数和 tick 时钟

多端一致有两条经典路线，我们选后者：

**路线甲 · 确定性 lockstep**（被否）：所有端跑同一份模拟，靠「同种子 RNG + 同步逻辑 tick + 逐帧一致的运算」保证不发散。问题：跨设备浮点结果不一致、现有移动/寻路全是 `_process(delta)` 帧率相关 + `WorkerThreadPool` 异步寻路完成时机不定——要一致就得把整套移动重写成固定 tick + 定点数，成本巨大且脆弱；而儿童沙盒对"两台平板上小鸭子位置差 3 厘米"零感知，为不需要的精度付全价不值。

**路线乙 · 单一模拟所有权 + 状态复制**（采用）：每个 actor 在任一时刻**恰好只有一个模拟者**，其他端只渲染复制来的状态——既然没有两份并行模拟，就**不存在发散，也就不需要确定性**。老板问的"大部分执行还是得 client 做"正是这个设计：高频行为（follow/flee/wander/寻路）确实在客户端本地跑，但每个 actor 只在**一个**客户端上跑。

具体规则：

- **所有权**：玩家 avatar = 自己的客户端（输入零延迟）；NPC = 服务端指派的 host 客户端（默认首位进入者，断线自动重指派）；道具落位 = 服务端仲裁（`prop_place` 已有先例）。
- **位置复制**：多人/剧本会话期间，各端把自己拥有的 actor 位置以 5-10Hz 经服务端转发（`positions_report` 的提频版），远端用 ~200ms 缓冲插值渲染。平时维持现有 5s 节流。
- **规则判定单点化**：`on('near')` 等规则由**服务端**对复制位置求值——单一判定点，天然无双端分歧；100-400ms 的判定延迟对"抓到了/换鬼"级别的事件无感。
- **随机数**：剧本层随机（谁当鬼、剧情分支）发生在服务端脚本里，天然单源；端上表现层随机（wander 抖动、气泡节奏）纯装饰、各端各随机即可，无需同步。
- **时钟**：不需要逻辑 tick 同步。只做一次性**服务端时间偏移握手**（连接时多次采样取偏移），用于倒计时 HUD 双端读数一致和插值时间戳。
- **规模目标**：同世界 2-6 人（家庭/幼儿园小组），WS 中继、无 interest management。百人级真 MMO 不在目标内，也不为它预留复杂度。

## 风险与兜底

- **脚本运行时错误**：worker 内 try/catch，单幕失败降级旁白，整场失败 `stage_abort` + 小仙子圆场（"今天先演到这里啦"）。
- **超时/失控**：每条 cmd ack 超时（如 30s）视为卡死；脚本总时长预算（如 10min）；worker 可强杀。
- **断连**：连接断开即杀 worker，客户端 `stage_abort` 恢复自由活动。剧场不做断点续演（重新点戏即可）。
- **`stripTypeScriptTypes` 是 experimental**：与服务端自身的 TS 直跑同风险等级；API 变动时用 `--experimental-strip-types` 同源实现兜底。

## 落地计划

- **Plan 1 `script-runtime`**：运行时+舞台协议+客户端 StageAgent+HUD 原语+**多人基建**（world 连接分组/广播、位置流插值、NPC 所有权、加入退出鲁棒性），用两个**手写**脚本（躲猫猫、三幕小剧场）端到端验收——先让真实脚本磨 API，再交给 LLM 写。依赖：位置流建立在 `char-position-sync`（另一在飞 plan，已到验收门）合并之上。
- **Plan 2 `screenplay-gen`**（Plan 1 合并后启动）：意图识别、大纲、逐幕生成、小朋友选角提词、报幕串场。
