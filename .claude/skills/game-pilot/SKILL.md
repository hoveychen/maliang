---
name: game-pilot
description: 用 AI 当玩家驱动马良小世界——替代真人完成点击/说话/拖动/手机操作,感知游戏状态并闭环执行任务。Use when 老板要求"替我玩一遍/跑一遍造物(起名/对话/引路/背包/贴纸)流程"、"驱动游戏到X状态"、"游戏里帮我看看/截个图"、"自动化验收某条游戏链路",或任何需要程序化操控 maliang 客户端(桌面或真机)的任务。
---

# game-pilot：AI 驱动马良小世界

控制通道 = 游戏内 debug TCP 命令口（`scripts/debug_cmd_server.gd`，仅 debug 构建）。**两个客户端接同一个口、能力完全一样**（同一套 access/actions/do 协议）——按场景挑：

- **★ MCP 原生工具（推荐，agent 交互驱动首选）**：已注册为 `maliang-pilot`（local scope，在你 `~/.claude.json` 里、**不进 repo**）。直接 tool call `observe/access/actions/state/do/say/wait_until/screenshot`，不用拼 Bash、不用自己解析 stdout JSON。**若这些工具不在你的工具集里**（本会话早于注册启动，或换了机器/checkout），先按下方「MCP 注册」注册、开新会话再用。
- **Python CLI（脚本化 / 回归 / 盲坐标兜底）**：`python3 test/e2e/pilot_cli.py [--port P] [--trace DIR] <子命令>`，回 JSON。用于写可重复脚本（`pilot_runner.py`）、trace 回放、盲坐标/手机 SubViewport，以及 MCP 没注册时。

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

旧命令（`tap`/`click`/`talk-npc`/`phone`/`pick`…）仍在、仍可用（尤其盲坐标/手机 SubViewport），但**新脚本优先走
`actions`→`do`**：它把"看到→走过去→点中"走全，能暴露旧后门跳过的盲区（命中测试、遮挡、遮罩吞点击）。

**MCP 注册**（`server/tools/harness-mcp`，零依赖 Node ≥23 原生跑 `.ts`，8 工具桥到同一个 debug TCP 口）：本仓
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
8 工具与 CLI 子命令一一对应：`observe`=state+actions 一次读全、`access`/`actions`/`state`/`do`/`say`/`wait_until`
同名、`screenshot`=`shot`。细节见该目录 README。

## 1. 循环纪律（感知→决策→动作→核对）

1. **每步动作后都要核对落地**：读 `state` 里对应字段（发了 `scene` 就等 `scene_id` 变、开了手机就看 `phone_open`），不要发完就当成功。
2. **能语义就不要盲坐标**：优先 `actions`→`do <id>`（见上「推荐主路径」）。旧法：`click --text/--path`（⚠️ 旧 `click` 对按钮直发 `pressed` 信号会**绕过命中测试**，遮罩盖住也能"点动"——真孩子却点不动；要验真可点性用 `do press:btn:…`，它发真触屏、会被遮罩正确吞掉）、`talk-fairy`/`talk-npc`（进对话）、`phone open/app/close`、`pick <optionId>`（造物点卡）。盲 `tap` 打不中会被当点地面把玩家支使走。
3. **SubViewport（手机屏）内元素盲坐标永远到不了**：`ui` 回包里 `viewport != "root"` 的元素只能 `click --path` 或 `phone` 命令。
4. **说话有门禁**：`say` 回 `fed:false/gate_closed` = 对方在说话或没开麦。先 `wait-banner`（TTS 放完）再重说；反复 say 会堆积 ASR 队列。看 `state.fsm_state`/`mic_open` 判断当下能不能说。
5. **`say` 之前必须先 `inject`**（换 ScriptedAsr），且必须**进世界后**才 inject（menu/标题页会报 no active VoiceCapture）。onboarding 页也有 VC，可以 inject。
6. 连测被 45min 冷却门拦住 → `reset-budget`。
7. **等状态、别卡时长（action-based）**：动作触发的动画/异步用**状态谓词**等它落定，不要 `sleep <固定秒数>` 硬赌——`wait-world`/`wait-speaking`（等对方说完，真 `speaking` 位，**替代 `wait-banner` 的墙钟猜**——慢 TTS 假阳/暂停假阴）/`wait --key <字段> --truthy|--falsy`（如 `--key phone_settling --falsy`、`--key transitioning --falsy`）、或本身就阻塞到落定的命令（`phone`、`do`）。卡 sleep 的脚本会在动画参数一改就整批 flake。
8. **落定失败先看 `settle_reason`**：`do` 异步动作超时回包带 `settled:false` + `settle_reason{predicate,note,读数,waited_sec}`——说清「为什么没落定」（没走到/没进对话/场景没变/造物没推进），照它排查别瞎猜。`click --text` 多命中会报 `ambiguous`（strict），改 `--path` 或 `do press:btn:<path>` 消歧。

## 2. 感知

- `observe`：`state` + `ui --texts` + 截图三合一（headless 时截图字段是 shot_error，正常）。
- `state` 关键字段：`fsm_state`（EXPLORE/LISTENING/RECORDING/THINKING/SPEAKING/CREATION/COOLDOWN）、`mic_open`、`player_tile`、`npcs`（名字+tile）、`bag_items`、`wallet`、`active_task`、`in_creation`+`creation_options`、`naming_item`、`phone_open/phone_app`、`placing/place_legal`、`play_blocked`、`banner_text`（对方正在说的话）、`ws_open`。
- `ui --texts`：可点元素（kind=button/tap_area）+ 可读文本（kind=text），带屏幕矩形——点根视口元素可 tap 矩形中心，更稳是 `click --path`。
- `shot --out /tmp/x.jpg`：带窗实例直接回传 JPEG（真机也走 TCP 回传，不依赖 adb pull）。

## 3. 标准流程配方

**进世界（menu → world）**：`ui` 找 kind=button（menu 只有一个全屏进入钮）→ `click --path <其path>` → `wait-world`（ws_open+npc≥8+vc_ready，冷缓存最多 120s）。⚠️ 桌面实例通常没端侧 ASR，`vc_ready` 只在 `inject` 之后才真——桌面用 `wait-world --no-vc`，然后 `inject` 回包 `ready:true` 即等效。没有玩家档案时会先进 onboarding（`state.scene_id` 为空且 UI 是绘本页即是）。

**对话**：找点点说话用 `do talk:player`（点自己=`_tap_pick`→点点，**可靠**；⚠️`do talk:fairy` 直点仙子精灵会打不中——精灵太小/悬浮/跟玩家重叠，现已自动改点玩家矩形）→ 等对方招呼放完（`wait-speaking`，真播放位）→ `inject`（一次即可）→ `say "..."` 确认 `fed:true` → 轮询 `banner_text` 看回复。找村民用 `do talk:npc:<id>`（在屏真 tap+真走；离屏回退 handler）。

**造物（guided-creation 多轮）**：对点点 `say "点点，帮我造一个火箭"` → `wait --key in_creation --truthy` → 循环：`state` 看 `creation_options` 拿选项 label，**有卡就 `do press:btn:<卡path>` 真 tap 那张卡**（4 张卡是真 Button，`actions` 里以 `press` 出现、label==选项 label；图标卡也挂了 tooltip=label，故按 label 选卡；category=recipient 时选「自己」那张。**不再用 pick_option 后门**），**无卡（开放问句）就 `say` 肯定应答**；press 是同步输入、卡触发的推进是服务端异步，故 press 后 `wait --key creation_question`（`wait_delta`）等问句翻页；`creation_question` ∈ {施法中…, 拼上啦…, 拼好啦！} 是过渡字幕不是新问句。直到 `bag_size` 增长或 `naming_item` 置位。⚠️**起名窗口只有 ~12s**：生成完（banner「变出来啦！」）后 `naming_item` 一置位就得马上 `wait --key naming_item --truthy` 接住，别在中间插 `state`/`observe` 把窗口耗掉（dogfood 实测漏接过）——`pilot_example.py` 已按此写。
**起名**：`naming_item` 非空后 `say "<名字>"` → 进确认模式（`vc_confirming`）→ `accept`。

**手机**：`phone open` → `phone app items|stickers|flowers|settings` → 屏内元素用 `ui` 枚举（viewport=PhoneScreen）+ `click --path`；翻页用 `swipe`。收起 `phone close`。`phone` 命令是 **action-based** 的：发起后会**阻塞到手机开/关/翻页动画真正落定**（回包带 `settled:true`）才返回，所以 `phone app` 后**直接 `shot` 即可，不用 `sleep`**——命令没返回=动画还没停。别再 `phone open` 完立刻 `phone app`+`sleep` 硬等：那样只是碰运气，且早期版本会把搬移动画掐断导致手机停在半路（时左时右）。

**移动**：点地走路 `tap <地面坐标>`；按住跟随 `long-press --ms 1500`；跨场景 `scene forest` 后等 `transitioning=false`；找机位 `teleport --near` / `teleport 30 40`。

**整链回归（不要手搓重写）**：造物起名全流程 `naming_e2e.py`、语音三链 `voice_regression.py`、相册拍摄 `menu_photo_shoot.py`。

**可重复 monkey 脚本（摸索出交互→写下来跑回归）**：写一个暴露 `def run(h): ...` 的 `.py`（真 Python、带条件/循环/
断言，用 `h.access()/h.actions()/h.do()/h.wait_until()/h.wait_world()/h.wait_scene()/h.wait_delta()` 等原语），
用 runner 统一跑：`python3 test/e2e/pilot_runner.py --script <你的脚本.py> [--port 8578] [--trace DIR]`。
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
