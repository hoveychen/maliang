# game-pilot 可复用流程中心（Flow Registry）设计

> 状态：**已获批（2026-07-22）**。三项岔路老板已拍板（见 §4）：A1=maliang-local；A2=MCP 子进程调 pilot_runner；A3=**一步到位**（含参数化 args_schema + flow 依赖）。审阅盘的是下面 §2 的需求清单（每条标注来源），不是散文。
> 关联：[game-pilot SKILL](../.claude/skills/game-pilot/SKILL.md)、harness-mcp（`server/tools/harness-mcp`）、
> `test/e2e/`（现有 `run(h)` 脚本 + `pilot_runner.py`）。

## 1. 背景 / 痛点（老板原话）

- 大量测试都需要**先过 onboarding、走特定前置流程**才能开始验真正要验的东西。
- 现在 agent **每次从头点一下、截图、点一下，几分钟才过 onboarding 进游戏**——因为 harness 没有"进世界"的复用 fixture（`harness.py` 只有 `wait_world` 等待、不导航）。
- 担心：agent 意识到慢之后**开始写代码作弊、跳过流程**，导致**回归测试被隐形丢弃**（覆盖悄悄缩水）。
- 期望：以后有**大量做各种事的脚本**，agent 能通过写 python 脚本扩展自己的能力；**脚本调用仍走 MCP**；有一个**集中的脚本中心**（新建），**也能在 harness web 面板里调用**。

## 2. 需求清单（逐条标注来源：明说 / 推导 / 我加的）

审阅时请对每条回「要 / 不要 / 改」。带 ⚠️ 的是**我加的**或有岔路的，尤其请拍板。

| # | 需求 | 来源 |
|---|---|---|
| R1 | 可复用的**前置流程**（onboarding→进世界、以及其它特定前置），脚本/agent 不必每次重走 | 明说 |
| R2 | 保留 **`run(h)` python 脚本 + SDK** 复用模型（现有 pilot_runner 那套），agent 可写新脚本扩展能力 | 明说 |
| R3 | **脚本调用走 MCP**：maliang-pilot 增 MCP 工具来列出/运行注册流程 | 明说 |
| R4 | **新建一个集中脚本中心（Flow Registry）**——不是 cws，是新做的 | 明说 |
| R5 | **harness web 面板也能调用**注册流程（列表 + 点即跑） | 明说 |
| R6 | onboarding 复用用**诚实 fixture**（走真输入/复用档案，不是后门瞬移）+ **旁路日志**（哪条流程被复用/跳过都记一条，绝不静默丢回归） | 明说 |
| D1 | 注册中心要有**发现/枚举机制**（manifest 或约定目录 + 每条 flow 的元数据：name/描述/tags/kind） | 推导(R3+R4 必然：按名调用得能查) |
| D2 | MCP 加 `list_flows` + `run_flow(name,args)`：查中心、跑流程、回结果+delta+旁路记录 | 推导(R3 的接口) |
| D3 | 提供一个 **`enter_world` 诚实 fixture**（第一个入库流程，也是最常见前置） | 推导(R1 的最常见前置) |
| D4 | flow 打 **`kind` 标签**（`setup` 前置夹具 / `regression` 被测流程）；每次运行发一条**覆盖记录**（用了哪条 setup、有没有 flow 被标记 skipped），落 trace + 回包 | 推导(R6 的落地) |
| D5 | serve_web 加 `/api/flows` + `/api/run_flow`，index.html 加"流程"栏（列注册流程 + 跑按钮 + 回包） | 推导(R5 的落地，复用现有 /api 结构) |
| A1 | 注册中心**范围** → **maliang-local**（活在本仓 `test/e2e/flows/`、harness 旁）。老板拍板。 | 我加的→已定 |
| A2 | `run_flow` **执行模型** → **MCP/web/CLI 都经 `pilot_runner.py` 子进程**跑 flow，单一执行路径。老板拍板。 | 我加的→已定 |
| A3 | flow **参数化 + 依赖** → **一步到位**：flow 带 `args_schema`，可声明 `depends`（前置 flow 链先跑）。老板拍板（否了先最小）。 | 我加的→已定 |

## 3. 架构（在需求获批后据此实现）

```
┌─ Flow Registry（新，maliang-local） ───────────────────────┐
│  test/e2e/flows/                                            │
│    registry.json      ← 清单:每条 {name,desc,tags,kind,     │
│                           script,args_schema}               │
│    enter_world.py     ← run(h) 诚实 fixture(setup)          │
│    <更多 flow>.py     ← agent 陆续写入                       │
│  registry.py          ← 加载/校验清单 + 按名解析            │
└────────────────────────────────────────────────────────────┘
        ▲ 按名查/跑                    ▲ 按名查/跑
┌───────┴─────────┐          ┌─────────┴──────────┐
│ MCP: list_flows │          │ serve_web:         │
│      run_flow   │          │  /api/flows        │
│ (mcp.ts 新增)   │          │  /api/run_flow     │
└───────┬─────────┘          │  index.html 流程栏  │
        │                    └─────────┬──────────┘
        └──────── 都经 pilot_runner 跑 ─┘  ← 单一执行路径
                   │
              run(h) + harness.py SDK → 游戏 debug TCP 口
```

**诚实 fixture + 旁路日志（R6 落地）**：
- `enter_world` 走**真输入**（真点菜单进入、真过 onboarding），只在有可复用档案时**复用档案跳过重复导航**——不引入瞬移/seed 后门（守住 harness-redesign「源头不给后门」理念）。
- 每次 `run_flow` 回包带 `coverage`：`{used_setup:[...], skipped:[...], bypassed_regression:bool}`，并追加进 trace。**任何被跳过的流程都显式出现在这里**——回归缩水会被看见，不会静默。

## 4. 岔路决议（老板 2026-07-22 拍板）

- **A1 注册中心范围 → maliang-local**：活在本仓 `test/e2e/flows/`，harness 旁；不做跨项目通用。
- **A2 `run_flow` 执行模型 → MCP 子进程调 `pilot_runner.py`**：MCP/web/CLI 三个入口都经同一个 `pilot_runner` 跑 flow，单一执行路径、不重复实现。
- **A3 参数化 + 依赖 → 一步到位**：flow 带 `args_schema`（可传参），可声明 `depends`（前置 flow 链先跑）。

**registry.json 每条 flow 的元数据（据 A3 定稿）**：
```jsonc
{
  "name": "enter_world",
  "desc": "真过 onboarding 进世界(有档案则复用跳过重复导航)",
  "kind": "setup",              // setup 前置夹具 | regression 被测流程
  "tags": ["onboarding", "prereq"],
  "script": "flows/enter_world.py",
  "args_schema": {},            // {argName: "类型/说明"};run_flow 按此校验+传入
  "depends": []                 // 前置 flow 名列表;runner 先按拓扑序跑完 depends 再跑本体
}
```
`run(h)` 签名扩成 `run(h, **args)`（无参 flow 照旧兼容）。依赖链由 `pilot_runner` 按 `depends` **拓扑序**先跑；setup flow 需**幂等**（如 enter_world 先查 `world_id` 已非空则记 `reused` 跳过导航）。

## 5. 分期落地（全量范围，薄竖切推进节奏）

- **P1 注册中心内核 + 依赖/参数**：`flows/registry.json`（上述 schema）+ `registry.py`（加载/校验/按名解析 + `depends` 拓扑排序 + 环检测）+ `enter_world.py` 诚实幂等 fixture（真输入进世界；已在世界则记 `reused`）。`pilot_runner` 扩成：按注册名跑、先跑 `depends` 链、按 `args_schema` 校验并传参、汇总 `coverage`。验：headless 跑 `enter_world` 真进世界；一个 `depends:[enter_world]` 的 flow 会先跑 enter_world。
- **P2 MCP 面**：mcp.ts 加 `list_flows`（回注册表）+ `run_flow(name,args)`（子进程调 pilot_runner，回 result+delta+`coverage{used_setup,skipped,bypassed_regression}`）。node:test。验：fresh agent 用 MCP `run_flow enter_world` 真进世界、回包带 coverage。
- **P3 web 面**：serve_web `/api/flows`+`/api/run_flow`（经 pilot_runner）+ index.html “流程”栏（列注册 flow、带 args 的弹输入、跑按钮、展示 coverage）。验：面板点 enter_world 真进世界。
- **P4 SKILL.md**：写清「优先 `run_flow` 复用注册流程别手搓重走 / 写新 flow 入库约定（name+kind+args_schema+depends）/ 旁路日志=不许静默跳回归」。
- **P5 迁一条真链证全模型 + 收口**：把 `naming_e2e` 登记为 `regression` flow、`depends:[enter_world]`、参数化「造物名」——证依赖+参数+coverage 全链。收口 merge --no-ff。

## 6. 非目标（防范围蔓延）

- 不做跨项目通用注册中心（除非 Q1 选它）。
- 不引入进世界的 seed/瞬移后门（与 R6 冲突）。
- 不动游戏客户端/服务端业务代码（纯 harness 工具层）。
- 不做 flow 的可视化编排/DAG（真有需要再议）。
