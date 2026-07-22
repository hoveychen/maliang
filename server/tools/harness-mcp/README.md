# maliang-harness-mcp

MCP 服务器：让 Claude 拿到**原生工具**驱动马良小世界，桥接到**游戏客户端**的 debug TCP 命令口
（`scripts/debug_cmd_server.gd`，仅 debug 构建）。零依赖——MCP stdio 传输就是逐行 JSON-RPC 2.0，
手写实现（`src/mcp.ts`）+ `node:net` TCP 客户端（`src/tcp_client.ts`）。Node ≥23 原生跑 `.ts`。

> 注意：连的是**客户端** TCP 口（默认 8578 桌面 / 8577 真机经 `adb forward`），**不是**游戏服务器
> 的 WebSocket（`ws://127.0.0.1:8080/ws`）。先起一个桌面 debug 实例（见 `.claude/skills/game-pilot/SKILL.md`）。

## 工具

| 工具 | 作用 |
|---|---|
| `observe` | 一次读全：`state` + 可用 `actions` |
| `access` | 无障碍元素列表（3D 实体 + 2D 控件，各带稳定 id/屏幕矩形/动作） |
| `actions` | 当前可用动作扁平表（按 `action_id` 挑一条给 `do`） |
| `state` | 结构化状态快照 |
| `do` | 执行动作 id（真输入优先；回包含 `execution`/`settled`/`delta`/新 `actions`） |
| `say` | 对当前对话对象说一句 |
| `wait_until` | 轮询 state 直到字段满足 `truthy`/`equals`/`gte` 或超时 |
| `screenshot` | 截当前帧（JPEG，headless 无视口会报错） |
| `list_flows` | 列可复用流程中心(Flow Registry)注册的 flow：`{name,desc,kind,tags,args_schema,depends}` |
| `run_flow` | 按名跑注册流程（经 `pilot_runner` 子进程,先跑 `depends` 链）：回 `{ran,coverage,delta,duration}` |

`list_flows`/`run_flow` 经 `pilot_runner.py` 子进程跑（`src/flow_runner.ts` 桥），与 CLI/web 同一执行路径；
流程定义在 `test/e2e/flows/`（`registry.json` + `<name>.py`），细节见 game-pilot SKILL.md「前置复用」节。

## 注册（自行选一种；本仓不落 `.mcp.json`）

**A. `claude mcp add`（推荐，项目级）：**

```bash
claude mcp add maliang-pilot \
  --env MALIANG_HARNESS_PORT=8578 \
  -- node server/tools/harness-mcp/src/mcp.ts
```

**B. 手写 `.mcp.json`（放到你自己的项目/用户配置里）：**

```json
{
  "mcpServers": {
    "maliang-pilot": {
      "command": "node",
      "args": ["server/tools/harness-mcp/src/mcp.ts"],
      "env": { "MALIANG_HARNESS_PORT": "8578" }
    }
  }
}
```

真机把 `MALIANG_HARNESS_PORT` 设 8577，并先 `adb forward tcp:8577 tcp:8577`。

## CDP 式双栏 web 控制面板（人可驱动）

零依赖：`node:http` 服务一张 vanilla HTML 面板 + JSON API，复用同一个 `tcp_client.ts`。

```bash
MALIANG_HARNESS_PORT=8578 node server/tools/harness-mcp/src/serve_web.ts --web-port 8600
# 浏览器打开 http://127.0.0.1:8600
```

- **左栏**：实时视窗截图（`/api/shot.jpg`，不降采样→与 `screen_rect` 1:1）+ 无障碍元素矩形叠加
  （SubViewport 元素紫框标注：真 tap 到不了）。
- **右栏**：「可复用流程」栏（列注册 flow、点「跑」复用前置、展示 coverage）+ 当前可用动作列表，点 `do`
  即执行（真输入优先）；需参数的动作/流程（如 `say` / 带 `args_schema` 的 flow）会弹输入框。

API：`GET /api/observe`（state+actions+elements）、`GET /api/shot.jpg`、`POST /api/do {action,args}`、
`GET /api/flows`（列注册流程）、`POST /api/run_flow {name,args}`（按名跑,回 ran/coverage/delta）。

## 测试

```bash
node --test test/*.test.ts      # tcp_client + delta（零依赖，秒级）
```

`npm run typecheck`（`tsc --noEmit`）需要 `@types/node`——在装了依赖的环境里跑；本 worktree 未装依赖时
以 `node --test`（原生类型剥离 + 运行）+ 对真实实例的 stdio 冒烟为准。
