# 画质 benchmark 重做：分幕加压故事 + 峰值稳态测档

## 背景 / 问题（真机坐实）

新平板首启走**内嵌 benchmark**（`IntroDirector._run_benchmark` → `Benchmark.make_embedded`），
藏在「建造小世界」注魔演出后面。三个毛病同一个根：

1. **测量在冻结的静态场景上做**。`_bench_freeze` 定格仙子 + 吞输入，`_bench_still` 在采样窗内
   停掉村民 `BehaviorExecutor`（wander + A\* 寻路）。idle 图集是 shader 时间驱动、照样播，但
   **A\* 寻路 / 村民走动 / 仙子逻辑全停**——而真机卡顿头号元凶就有「GDScript A\* 打摆」
   （见记忆 `tablet-perf-investigation`）。另塞的 12 个 `bench_` 负载角色**不注册占用、不给
   行为脚本 = 站着不动**，只压渲染不压寻路。
2. 冻结静态场景**比真实玩起来轻太多** → 「全最高档」基线 p95 很可能 ≤ 33.3ms 达标线 →
   贪心一看基线就达标 → **一档都不降，直接存全最高**（`benchmark.gd:212`）。
3. 弱机（华为 Mali-G76，真机档案 `graphics.source=user / actor_shadows=0 / prop_detail=0`
   ——老板手动关阴影+精细度救场，无 bench 元数据键，坐实是手改的）被全最高压垮 → 卡死、
   像进不去。而「看不到测试过程」= 内嵌路本就无测试 UI，只对着**静态**世界念旁白，画面跟
   loading 水彩撞脸。

**贪心算法本身是对的**（`test_benchmark_greedy` 合成数据四种机型全过）。坏的是**喂给它的
真机 p95 不代表真实负载**。现有 intro 也**没有真正的分幕建造**——世界在 `world._ready` 就
一次性全渲染好，旁白只是对着静态世界念「大地长出来 / 树冒出来 / 房子盖好」。

## 目标（老板拍板）

- **建造 intro = 可见的分幕负载坡**。小朋友在**观赏一个故事**（空地 → 长草木 → 升房子 →
  小伙伴蹦出来 + idle 动画），不是盯着 loading。
- 贪心在**活的**峰值场景上测（村民照常 wander/动画、仙子照常悬浮），不再冻结。
- 帧率目标：**稳 30（≤33.3ms）为目标，压不住才允许掉到 25（≤40ms）**——保画质优先，
  不为凑帧率白掉画质（沿用 `MIN_GAIN_MS` 门槛）。

## 设计

### 全局形状：故事分幕把负载堆到峰值，峰值处测档

内嵌路（`IntroDirector`）把「建造」真的演出来，每一幕加一层负载；到峰值幕才让点点「画大
魔法」= 在**满负载的活场景**上跑贪心定档。

| 幕 | 旁白（现成 `lines.json`） | 场景动作（负载） |
|----|--------------------------|------------------|
| 开场 | `intro_open_1` | 起手**极简**：props 隐藏（`set_props_shown(false)`）、地面影隐藏、无额外村民、镜头对着点点。 |
| 建造·地木 | `intro_build_1`「大地长出来，小树冒出来」 | 揭示 props + 地面影（`set_props_shown(true)` / `set_ground_shadows` 按目标档）——树木灌木冒出。 |
| 建造·热闹 | `intro_build_2` / `intro_partner_1`「小伙伴蹦出来」 | **逐个**生出负载村民（`EXTRA_CHARS` 个，几个一幕、错相位、带 idle 动画**且注册占用 + ambient wander**）——角色渲染 + 寻路 CPU 一起上。到此为峰值。 |
| 注魔·测档 | `intro_magic_1`「点点画个大魔法，让世界变清楚」 | 峰值已成形。跑**活场景**贪心定档：villager 照常 wander、仙子照常悬浮、只锁玩家输入。每砍一档＝世界「变顺 / 变清楚」，点点施法旁白盖住画质切换。 |
| 收尾 | `intro_ready_1` + （首次）教学 | 就地应用 levels + `save_all(source=bench)`、负载村民退场、解锁输入，转正。 |

镜头：注魔测档期间可用 `focus_override` 做一次**慢速定轨巡游**（每次测量窗轨迹一致 → 负载在
各 trial 间可比），顺带扫出真实观感；小世界铺完后移镜头**不重铺 chunk**，故巡游几乎不加成本，
纯粹为「让画面活起来、别像冻帧」。v1 可先固定俯瞰不巡游，留作打磨。

### 核心修复：活场景稳态测量（替代冻结）

`benchmark.gd` / `world.gd` 改动：

1. **不再在采样窗冻结村民**（核心）：删掉 `_bench_still` 的设置（`benchmark.gd:191`）与
   `_step_executors` 的门禁（`world.gd:2227`）。村民全程 wander（A\* + 走动）计入 p95。
   这才是旧口径真正欠测的那笔——静态场景无逐帧 CPU 尖峰、p95 假性达标；一动起来才暴露卡顿。
2. **负载角色变「活」**（核心）：`_spawn_load` 生出的 `bench_` 角色**注册占用 + 挂 ambient
   wander**（复用 `_start_ambient_wander`），使峰值同时压渲染与寻路，贴近真实热闹世界。退场时
   对称 `unregister`（现状「不注册占用、不给行为脚本」是静态负载，正是欠测源头之一）。
3. **仙子保持定格**（测量中性，非欠测源）：仙子是 billboard，**位置冻不冻结，每帧照样绘制、
   帧成本不变**——所以定格它对 p95 无影响，反而避免「解冻→ambient 语音 / POI 撞点点施法旁白」
   的麻烦。故 `_bench_freeze` 对 `_update_fairy` 的定格**保留**，语义即「注魔期凝神」。仙子视觉
   是否活起来是 P2 编排的观感选择，与测量无关。
4. **只锁玩家输入**：保留 `_bench_freeze` 吞掉玩家点击/手势（`_unhandled_input`），防小朋友测试
   时拖动世界干扰负载。`_bench_freeze` 收窄为「输入锁 + 仙子定格」两件事，`_bench_still`（村民
   静止）整条删除。
5. **达标线不变**：`TARGET_FRAME_MS = 33.3`（瞄准 30fps）。压不住时贪心按 `MIN_GAIN_MS`
   门槛 / `MAX_MEASURES` 预算交出最优档（可能落在 25fps 附近）＝「允许掉到 25」。

贪心决策逻辑（`_advance` / `_begin_round` / `_try_next`）**原样保留**——它已被证明正确，改的
只是「喂进去的 p95 来自活场景」。活场景 wander 引入的帧时抖动被 2.4s 窗口 + p95 + 1.5ms 收益
门槛吸收；砍一档昂贵开关（Mali 上实时阴影实测 ~2.5×）的收益远大于抖动。

### 内嵌 vs 独立两条路的分工

- **内嵌**（首启）：`IntroDirector` 拥有分幕建造与负载堆叠（隐藏→揭示 props、逐个生村民），
  到峰值幕创建 `Benchmark.make_embedded(world)`，Benchmark **不自己铺负载**（故事已铺）、
  **不冻结**、只在活的峰值上测。测完负载村民退场由谁负责需明确（建议 Benchmark 记下自己没
  spawn、退场交给 IntroDirector；或 Benchmark 统一 spawn/despawn 但由 IntroDirector 脉冲驱动
  `spawn_load_step()`）——**实现时定，写进 P2**。
- **独立**（设置页「重新检测画质」/ `Benchmark.pending`）：无故事。Benchmark 自己 spawn 负载
  （现成，改为**活的** wander 角色）、保留奶油底遮罩 + 进度条、活场景测。独立路本就不冻结
  （freeze 是 embedded 专属），只需把 12 个静态负载角色改活 + 确认不设 `_bench_still`。

### 版本口径

负载从「冻结静态」变「活的分幕峰值」→ p95 变 → **必须 bump `BENCH_VERSION` 2→3**，两处：
`scripts/device_profile.gd:15` 与 `server/src/device_profile.ts:17`（跨语言靠注释互相看住）。
服务端众包按 `(gpu, bench_version)` 聚合，旧 v2 样本（全最高、冻结口径）自然作废、不污染 v3。

### 揭幕 / 兜底（治「卡在 loading」）

- 「卡住」根因是全最高冻死真游戏，测准即治。但补一道保险：内嵌路 `world_ready` 目前只靠
  `IntroDirector._run` 早发、**无超时兜底**（探子确认此路无 `_watch_world_ready` 安全网）。
  benchmark 循环已由 `MAX_MEASURES` 兜底不会无限，intro 转正也总会到达；保持现状即可，但
  P3 要 headless 验证「benchmark 段异常也能走到转正、不卡揭幕」。
- 家长长按 skip（`IntroDirector.skip`）：分幕建造中途被跳 → 立即揭示全部 props/村民（别停在
  半成品）、中止定档、`Benchmark.pending=true` 留待下次快速定档（现状语义保留）。

## 验收标准（可验证）

- headless：`test_benchmark_greedy` 保持全绿（算法未动）；`test_intro_benchmark` 改期望——
  采样期**不再**有 `_bench_still` 静止窗、村民在测档期**活着**（executor 在 step）、props 经历
  隐藏→揭示、负载村民 spawn 后 despawn、转正到底、`source=bench`。
- headless：新增/改「独立 benchmark 场景」测——负载角色活着、无 `_bench_still`。
- `scripts/test-headless.sh` 全绿、`cd server && npm test && npx tsc --noEmit` 全绿。
- **真机（老板域，合并前验收门）**：华为 Mali-G76 清档重跑——(a) 看得见分幕建造故事、不是
  loading；(b) 贪心**真的砍了档**（不再全最高）、`BENCH done` 日志 p95 反映活负载；(c) 定档后
  正常进游戏、稳在 25-30fps、不卡死。抓 `adb logcat -s godot | grep BENCH`。

## 硬化补丁（benchmark-noise-harden，真机验证后）

首轮合并后华为 Mali-G76 真机实测暴出一个新问题，记录在此：

- **现象**：benchmark 报「砍完 prop_anim → 32.6ms（30fps）达标」，但实际进游戏同一设置 = **43.5ms
  （23fps）**，低于 25-30 目标带。
- **根因**：**注魔期的镜头慢巡 + 村民 wander 让相邻 trial 的采样窗落在不同取景 → p95 抖 ±18ms**。
  BENCH 日志里出现物理上不可能的负收益（`ground_shadows/xray trial gain = -18ms`），坐实噪声。
  那个 32.6ms 是个幸运低样本（真实 prop_anim-off ≈ 基线 45ms），贪心戚到它就误报达标、**提前收手**
  （只砍一档，其实该继续砍够档才真到 30fps）。
- **修复**：**注魔测档整段把焦点钉死**（`_run_benchmark` 里 `focus_override = focus_logical` 一次、
  不再逐帧巡游）——各 trial 取景一致才可比。村民仍 wander（CPU 负载照旧计入）。给观感的「点点带
  镜头慢巡」**挪到 `_spawn_friends`（小伙伴逐个蹦出的建造幕）**：那段镜头绕环慢移、有生气，但不落在
  测量段。噪声一稳，贪心会自然继续砍够档、真到 25-30。
- 教训：活场景测量的可比性，敌人不是「动」，是「取景变」。村民动（CPU 负载）没问题，镜头动（GPU
  取景）才是噪声源——测量段冻镜头、别冻村民。

## 不做 / 留后续

- 不重写 chunk 流式铺设（逐块一帧已够，props 用 `set_props_shown` 组开关分幕即可）。
- 镜头巡游 v1 可省（固定俯瞰），作打磨项。
- 负载角色数 `EXTRA_CHARS=12` 沿用；真机若发现峰值不够代表真实世界，调这个常量 + bump 版本。
