---
name: game-pilot
description: 用 AI 当玩家驱动马良小世界——替代真人完成点击/说话/拖动/手机操作,感知游戏状态并闭环执行任务。Use when 老板要求"替我玩一遍/跑一遍造物(起名/对话/引路/背包/贴纸)流程"、"驱动游戏到X状态"、"游戏里帮我看看/截个图"、"自动化验收某条游戏链路",或任何需要程序化操控 maliang 客户端(桌面或真机)的任务。
---

# game-pilot：AI 驱动马良小世界

控制通道 = 游戏内 debug TCP 命令口（`scripts/debug_cmd_server.gd`，仅 debug 构建）。**两个客户端接同一个口、能力完全一样**（同一套 access/actions/do 协议）——按场景挑：

- **★ MCP 原生工具（推荐，agent 交互驱动首选）**：已注册为 `maliang-pilot`（local scope，在你 `~/.claude.json` 里、**不进 repo**）。直接 tool call `observe/access/actions/state/do/say/wait_until/screenshot` + 流程中心 `list_flows/run_flow`，不用拼 Bash、不用自己解析 stdout JSON。**若这些工具不在你的工具集里**（本会话早于注册启动，或换了机器/checkout），先按下方「MCP 注册」注册、开新会话再用。
- **★ 动手前先 `list_flows`**：进世界等前置有现成可复用流程，别每次从头点菜单/onboarding 摸几分钟——见下「前置复用：Flow Registry」。
- **Python CLI（脚本化 / 回归 / MCP 没注册时）**：`python3 test/e2e/pilot_cli.py [--port P] [--trace DIR] <子命令>`，回 JSON。**命令面与 MCP 对等（同名子命令）**，flow 引擎也在同一 CLI（`list-flows`/`run-flow`），外加 `run-script` 逃生口跑 `run(h)` 脚本（完整 Harness，legacy/device 手势只在这）。用于回归脚本、trace 回放、以及 MCP 没注册时。

下文命令示例以 CLI 写法给出；**MCP 就是同名工具**（`observe`/`access`/`actions`/`state`/`do`/`say`/`wait_until`/`screenshot`，参数一致），语义完全相同，照搬即可。

## 0. 接入（先起实例，再连口）

| 目标 | 做法 | 端口 |
|---|---|---|
| 桌面带窗（能截图，演示/目视首选） | `MALIANG_HARNESS_PORT=8578 /Applications/Godot.app/Contents/MacOS/Godot --path <repo> &`（Bash run_in_background） | 8578 |
| 桌面 headless（只驱逻辑，截图会报 no viewport image） | 同上加 `--headless` | 8578 |
| Android 真机 | 主 checkout 导 debug APK 装机（scripts/export-apk.sh），`adb forward tcp:8577 tcp:8577` | 8577 |
| 离线模式（不打生产） | 起实例时加 `MALIANG_API_BASE=http://127.0.0.1:1`——但**离线进不了在线世界**：只有 4 个本地种子村民、ws 不通、造物/对话发不出去。要完整玩法必须在线（默认连 PROD） | — |

⚠️ 8577 常被 adb/iproxy 转发占走，桌面实例一律 8578；8579 是 headless 回测专用，别占。

## ★ 推荐主路径：access → actions → do（无障碍/真输入模型）

新模型把游戏里**一切可交互物统一成稳定 ID + 可用动作**，动作**默认走真输入**（tap 元素投影屏幕矩形 /
真走路 / 真长按），无真路径才回退 handler，并回报实际路径。不带业务理解也能摸索——**先 `actions` 看有哪些
可做，挑一条 `do`**：

```
pilot_cli.py access [--texts]   # 元素列表：3D 实体(npc/fairy/remote/player/poi/portal/prop)+2D 控件，
                                #   各带 id / kind / on_screen / screen_rect / world.tile / 该元素的 actions
pilot_cli.py actions            # 当前可用动作扁平表：{action_id,kind,target_id,label,enabled,reason_disabled,
                                #   execution(tap|walk|long_press|gui|voice|handler),screen_rect,args_schema}
pilot_cli.py do <action_id> [--arg k=v]   # 执行；回包带 execution(实际路径)/settled/delta(相对上次 state)/新 actions
```

**action_id 形如**：`talk:npc:pig_boss`、`press:btn:/root/…/确认`、`enter_portal:village_forest@24,24`、
`walk:poi:poi_pond`、`pickup:prop:30,46`、`press:btn:/root/…/@Button@`(造物卡也是 press——按 label 选)、`say`、`confirm:confirm_accept`、`phone:open`。

**关键语义**：
- `do` 对**异步动作**（走路/进场/造物/手机）**等落定才回包**（`settled:true`），回包里 `delta` 是相对上一份
  `state` 的增量——一次往返就知道"做了什么、现在能做什么"，不用每步单独查。
- `execution` 报**实际走的路**：`tap`=真触屏投影矩形（元素 `on_screen` 时）、`walk`=真寻路、`long_press`=真长按、
  `handler`=元素在屏外/SubViewport 无真路径时的回退。off-screen 是常态（世界会滚），回退不是 bug。
- 元素 `enabled:false` + `reason_disabled`（`off_screen`/`mic_closed`/`blocked_by_overlay`…）先看这个再 `do`。
- **teleport 已降级为纯调试瞬移**，不在 `actions` 里——导航一律 `do walk:…`/`do enter_portal:…` 真走。

legacy 命令（`tap`/`click`/`talk-npc`/`phone`/`pick`/`scene`/`teleport`…）**已从 CLI 砍掉**——命令面与 MCP 对等。
capability 全经 `actions`→`do`（把"看到→走过去→点中"走全，暴露旧后门跳过的盲区：命中测试、遮挡、遮罩吞点击）；
真正的盲坐标/设备手势只在 `run-script` + 完整 Harness SDK 里。

**MCP 注册**（`server/tools/harness-mcp`，零依赖 Node ≥23 原生跑 `.ts`，10 工具桥到同一个 debug TCP 口）：本仓
**不落 `.mcp.json`**（不污染 repo），用 **local scope** 注册到你自己的配置：

```
claude mcp add maliang-pilot --scope local --env MALIANG_HARNESS_PORT=8578 \
  -- node <repo绝对路径>/server/tools/harness-mcp/src/mcp.ts
```

真机把端口设 `8577` 并先 `adb forward tcp:8577 tcp:8577`。注册后 `claude mcp list` 应见
`maliang-pilot ✔ Connected`（Connected = MCP 进程握手健康，**不代表游戏已连**——先起桌面 debug 实例再驱）。
⚠️ **注册在当前会话不生效，下一个会话才加载**（MCP 工具在会话启动时枚举）。
⚠️ **headless `claude -p` 默认不加载任何 MCP**（实测新 `-p` 会话连 fleet 的 MCP 都看不到）——`-p`/被 dispatch 的
无头场景必须显式 `claude -p --mcp-config <json> --strict-mcp-config …`（json 格式见本目录 README 的 B 节）。
交互式 TUI 会话才自动加载 local scope 注册。**验证方式**（已实测通）：起桌面实例后
`claude -p --mcp-config <json> --dangerously-skip-permissions "用 maliang-pilot 的 observe 读状态"`——
agent 会直接 tool-call `mcp__maliang-pilot__observe`、零 Bash/python 回退。
工具与 CLI 子命令对应：`observe`=state+actions 一次读全、`access`/`actions`/`state`/`do`/`say`/`wait_until`
同名、`screenshot`=`shot`，另加 `list_flows`/`run_flow`（流程中心，见下节）。细节见该目录 README。

## ★ 前置复用：Flow Registry（先看有没有现成流程，别手搓重走）

**痛点**：大量验证都得先过 onboarding、走特定前置才能开始验真正要验的。每次从头点菜单/等加载几分钟很费；更糟的是图快去写代码跳流程，会**把回归悄悄丢掉、覆盖缩水看不见**。流程中心把这些前置收成**可复用、可组合、带覆盖记录**的 flow。

**用（跑现成流程）**——动手前先列，有就复用，别重走：
```
list_flows                          # MCP 工具 / CLI: python3 test/e2e/pilot_cli.py list-flows
run_flow  name=enter_world          # MCP 工具；带参: run_flow name=naming_e2e args={"name":"小火箭"}
python3 test/e2e/pilot_cli.py run-flow enter_world [--args '{"name":"小火箭"}']   # CLI 等价
```
- `run_flow` **先按 `depends` 拓扑序跑前置链**再跑本体：如 `enter_world`（诚实真输入进世界，已在世界则记 `reused` 跳过导航）是最常见前置，声明 `depends:[enter_world]` 的 flow 会自动先把你带进世界。
  - **首次设备/没角色档**：`enter_world` 会诚实报错（菜单分流进 onboarding、语音建角色，它不做）。这时用 `onboarding`（同为 `setup`，provides 同一组世界就绪条件）——它 monkey 跑过完整建角色：菜单→绘本→说名字(`say`)→点 ✓ 确认→形象对话点卡→照镜子按 ✓ 收尾→落档进世界。已有角色则记 `reused`（幂等）。带参 `run_flow name=onboarding args={"name":"小马"}`。
- 回包带 **`coverage`**：`{used_setup:[...], skipped:[...], bypassed_regression}`——**旁路日志**。哪条前置被复用、有没有真跑到回归都显式可见；`bypassed_regression=true` = 这次只做了 setup、没真验回归。**绝不静默跳回归。**
- **`list_flows` 每条带 `available:{ok,reasons}`**（按当前游戏 state 算，对齐 action 的 `enabled`/`reason_disabled`）：`ok:true`=现在能跑、`false`=当前不可跑(reasons 是人话原因，如「世界未就绪」)、`null`=游戏没连上。**先看 available 再挑**，别对着不可跑的 flow 空跑。
- web 面板（`serve_web.ts`，见 README）右栏「可复用流程」栏也能点「跑」，带参弹输入、展示 coverage。
- MCP/web/CLI 三入口**都经 `pilot_cli.py`（`list-flows`/`run-flow`）子进程**跑——单一执行路径，同一份注册表。

**写（新 flow 入库）**——摸索出一段可复用交互后，落成 flow 而不是散在脚本里：
1. `test/e2e/flows/<name>.py` 暴露 `def run(h, **args): ...`（抛 `HarnessError`/`AssertionError` = 失败）。
   **★ flow 收到的 `h` 是 `MonkeyHarness`（玩家 SDK，不是 god 脚本）——诚实是类结构层面的**：这个类**根本不含**
   `teleport`/`scene`/`reset_budget`/`pick`/`accept`/`talk_fairy`/`talk_npc`/`click_ui`/`phone`/`pickup`/盲坐标
   `tap`/`drag`/… （不是「调了报错」，是压根没定义——访问即 `AttributeError`）。它只有**用户真能做的操作** + 感知 + 等待：
   `state`/`access`/`actions`/`observe`/`screenshot`（眼睛）、`do`（真 tap 投影矩形/真走路/真长按）、
   `say`/`say_when_open`/`inject`（真说话+语音通道）、`wait_*`。想造物就像孩子一样 `actions`→`do` **真 tap 卡**
   （按 label 找 `press:btn` 去 `do`）、`say` 真说话、`do confirm:confirm_accept` 真 tap 采纳——无从瞬移或 id 直选。
   （完整 `Harness(MonkeyHarness)` 子类才加回 legacy/debug op，只给 **`--script` 逃生口**与真机/摄影脚本；`--flow`
   注册流程走 `MonkeyHarness`。范例见 `flows/enter_world.py`、`naming_e2e.py` 的 `run()`。）`setup` 型要**幂等**。
2. 在 `test/e2e/flows/registry.json` 登记一条：`{name, desc, kind, tags, script, args_schema, depends}`。
   - `kind`：`setup`（前置夹具，幂等）| `regression`（被测流程）。
   - `depends`：前置 flow 名列表，runner 按拓扑序先跑（有环会被检测报错）。
   - `requires`（可选）：本体开跑前需满足的**条件键**（`in_world`/`online`/`villagers_ready`/`vc_ready`，全从 state 算）。runner 在 deps 跑完后**硬校验**——未满足带人话原因抛错（不是散在 flow 里手写 raise）。`list_flows` 也据此算 `available`。
   - `provides`（可选，setup 用）：这条 setup 跑完会**建立**哪些条件键（如 `enter_world` provides `in_world`/`online`/`villagers_ready`）。让 `list_flows` 的 `available` 乐观计入依赖效果（naming_e2e 在菜单也显示可跑，因为 enter_world 会先建立世界）。
   - `args_schema`：`{argName:"说明"}`，`run_flow` 按此**校验+传参**（未声明的键会被拒）。
3. 别新造进世界的导航——直接 `depends:[enter_world]` 复用。别为图快写代码跳过回归——用 flow + coverage 让复用/跳过**显式可见**。

## 1. 循环纪律（感知→决策→动作→核对）

1. **每步动作后都要核对落地**：读 `state` 里对应字段（进场了就等 `scene_id` 变、开了手机就看 `phone_open`），不要发完就当成功。
2. **一切交互经 `actions`→`do <id>`**：CLI 已砍成与 MCP 对等，legacy 盲坐标/专用子命令（`tap`/`click`/`talk-npc`/`phone`/`pick`/`scene`/`teleport`…）**都没了**。capability 全经 `do <action_id>`：进对话 `do talk:npc:<id>`/`do talk:player`、点按钮 `do press:btn:<path>`（发真触屏、会被遮罩正确吞掉，暴露"真孩子点不点得动"）、造物点卡 `do press:btn:<卡path>`、采纳 `do confirm:confirm_accept`、进场 `do enter_portal:<scene@x,y>`、走到 POI `do walk:poi:<id>`。**真正的盲坐标手势/任意点走路只剩 `run-script`+完整 Harness SDK 一条路**（`h.tap()/h.drag()/h.teleport()/h.reset_budget()` 等只在脚本里）。
3. **SubViewport（手机屏）内元素**：`access` 回包里 `viewport != "root"` 的元素照样有稳定 id、用 `do press:btn:<path>` 点中（真投影/回退 handler）；纯滑动翻页这类手势 CLI 没有，需要就写 `run-script`。
4. **说话有门禁**：`say` 回 `fed:false/gate_closed` = 对方在说话或没开麦。先 `wait --key speaking --falsy`（对方 TTS 放完）再重说；反复 say 会堆积 ASR 队列。看 `state.fsm_state`/`mic_open` 判断当下能不能说。
5. **`say` 自动补 `inject`**（后台 say 发现 ASR 不是 ScriptedAsr 会先自动切换，不必手动 inject）；但仍须**进世界后**才说（menu/标题页无 active VoiceCapture，say 会报错）。onboarding 页有 VC，可以说。
6. 连测被 45min 冷却门拦住 → 写个 `run-script` 调 `h.reset_budget()`（`reset-budget` 子命令已砍，能力在完整 Harness SDK）。
7. **等状态、别卡时长（action-based）**：动作触发的动画/异步用**状态谓词**等它落定，不要 `sleep <固定秒数>` 硬赌——`wait --key speaking --falsy`（等对方说完，真 `speaking` 位，比墙钟猜稳）、`wait --key <字段> --truthy|--falsy`（如 `--key phone_settling --falsy`、`--key transitioning --falsy`）、或本身就阻塞到落定的命令（`do`）。卡 sleep 的脚本会在动画参数一改就整批 flake。
8. **落定失败先看 `settle_reason`**：`do` 异步动作超时回包带 `settled:false` + `settle_reason{predicate,note,读数,waited_sec}`——说清「为什么没落定」（没走到/没进对话/场景没变/造物没推进），照它排查别瞎猜。`do press:btn:<path>` 用精确 path 消歧。

## 2. 感知

- `observe`：`state` + `access` + 截图三合一（headless 时截图字段是 shot_error，正常）。回包带 `flows_hint`——跑链路前先 `list-flows`。
- `state` 关键字段：`fsm_state`（EXPLORE/LISTENING/RECORDING/THINKING/SPEAKING/CREATION/COOLDOWN）、`mic_open`、`player_tile`、`npcs`（名字+tile）、`bag_items`、`wallet`、`active_task`、`in_creation`+`creation_options`、`naming_item`、`phone_open/phone_app`、`placing/place_legal`、`play_blocked`、`banner_text`（对方正在说的话）、`ws_open`。
- `access --texts`：无障碍元素（3D 实体 + 2D 控件，各带稳定 id/屏幕矩形/可用动作 + 可读文本），挑一条 `do`。
- `shot --out /tmp/x.jpg`：带窗实例直接回传 JPEG（真机也走 TCP 回传，不依赖 adb pull）。

## 3. 标准流程配方

**进世界（别手搓！）**：直接 `run-flow enter_world`（诚实真输入进世界，已在世界记 `reused`）。首次设备/没角色档用 `run-flow onboarding`（monkey 跑完整建角色，幂等）。**这就是 Flow Registry 的意义——进世界/前置有现成 flow，别每次从菜单点起。** 真要手动：`access` 找 kind=button（menu 只有一个全屏进入钮）→ `do press:btn:<path>` → `wait --key ws_open --truthy` 等就绪（冷缓存最多 120s）。

**对话**：找点点说话 `do talk:player`（点自己=`_tap_pick`→点点，**可靠**；`do talk:fairy` 直点精灵会打不中——太小/悬浮/跟玩家重叠，现已自动改点玩家矩形）→ 等对方招呼放完（`wait --key speaking --falsy`）→ `say "..."`（自动 inject）确认 `fed:true` → 轮询 `state.banner_text` 看回复。找村民 `do talk:npc:<id>`（在屏真 tap+真走；离屏回退 handler）。

**造物（guided-creation 多轮）**：对点点 `say "点点，帮我造一个火箭"` → `wait --key in_creation --truthy` → 循环：`state` 看 `creation_options` 拿选项 label，**有卡就 `do press:btn:<卡path>` 真 tap 那张卡**（4 张卡是真 Button，`actions` 里以 `press` 出现、label==选项 label；图标卡也挂了 tooltip=label，故按 label 选卡；category=recipient 时选「自己」那张），**无卡（开放问句）就 `say` 肯定应答**；press 是同步输入、卡触发的推进是服务端异步，故 press 后 `wait --key creation_question --changed` 等问句翻页；`creation_question` ∈ {施法中…, 拼上啦…, 拼好啦！} 是过渡字幕不是新问句。直到 `bag_size` 增长或 `naming_item` 置位。⚠️**起名窗口只有 ~12s**：生成完（banner「变出来啦！」）后 `naming_item` 一置位就得马上 `wait --key naming_item --truthy` 接住，别在中间插 `state`/`observe` 把窗口耗掉。**整条造物起名链已有现成 flow `naming_e2e`——优先 `run-flow naming_e2e args={"name":"小火箭"}`，别手搓。**
**起名**：`naming_item` 非空后 `say "<名字>"` → 进确认模式（`vc_confirming`）→ `do confirm:confirm_accept`。

**手机 / 场景切换 / 走位**：手机 `do phone:open`，屏内元素 `access` 枚举（viewport=PhoneScreen）后 `do press:btn:<path>`；跨场景 `do enter_portal:<scene@x,y>` 后 `wait --key transitioning --falsy`；走到 POI `do walk:poi:<id>`。**任意点盲走 / 按住跟随 / 滑动翻页这些手势 CLI 没有**——需要就写 `run-script` 用完整 Harness（`h.tap()/h.long_press()/h.swipe()`）。

**整链回归（不要手搓重写）**：优先跑现成 flow（`list-flows` 看有哪些）；注册外的老脚本经 `run-script`：造物起名 `naming_e2e.py`、语音三链 `voice_regression.py`、相册拍摄 `menu_photo_shoot.py`。

**可重复 monkey 脚本（摸索出交互→写下来跑回归）**：写一个暴露 `def run(h): ...` 的 `.py`（真 Python、带条件/循环/
断言，用 `h.access()/h.actions()/h.do()/h.wait_until()/h.wait_world()/h.wait_scene()/h.wait_delta()` 等原语），
用 `python3 test/e2e/pilot_cli.py run-script <你的脚本.py> [--port 8578] [--trace DIR]` 跑（完整 Harness，legacy/device 手势可用）。
范式见 `test/e2e/pilot_example.py`（进世界→找点点→造物→起名，全程 wait 原语等落定，不卡 sleep）。

## 4. 轨迹与报告

长任务/巡检一律带 `--trace <dir>`：每条命令+应答追加 `trace.jsonl`、截图落同目录，事后可回放审计。
**回放回归**：`python3 test/e2e/trace_replay.py --trace DIR/trace.jsonl [--port 8578]` 把录制的命令重发一遍、
逐条比对 `ok`（命令忠实，退出码=不匹配数）——"上次这么点一遍是通的，这次还通吗"。
QA 巡检（自主玩+异常报告）用 `python3 test/e2e/qa_patrol.py --minutes N`（见 P7）。

## 5. 已知坑

- 世界就绪判据是 **ws_open + npc_count≥8 + vc_ready** 三条齐：本地种子村民(4)立即出现但 ws 没连=离线，别被骗。
- 真机上真麦和合成 PCM 会打架，偶发「我没听清」→ 等 banner 稳再重说（`naming_e2e._say_until` 已封装）。
- headless 无 viewport 纹理：`shot` 报 no viewport image 属预期，要图就带窗跑。
- 跑完真机记得 `adb forward --remove tcp:8577`，占口会害 headless 回测 test_harness_wire 挂。
