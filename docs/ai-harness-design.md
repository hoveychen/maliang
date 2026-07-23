# AI 驱动游戏 harness 框架（ai-harness）

目标：**完全由 AI 替代玩家完成所有输入**（点击、说话、拖动、手机操作），含感知与动作两面。
在 voice-e2e harness（docs/voice-e2e-harness-design.md）的 debug TCP 命令口之上系统化扩建。

## 分层

```
AI 会话（Claude + game-pilot skill）─┐            ← 决策层：自然语言任务 → 感知→决策→动作循环
flow：命令式 flows/*.py + 声明式 steps ┤            ← 复用层：确定性整链回归（run-flow / save-as-flow）
        pilot_cli.py（一发式命令）    │
        harness.py（Python SDK）─────┘            ← 驱动层：连接/动作封装/等待谓词/轨迹录制
                 │  TCP 127.0.0.1:8577(真机)/8578(桌面)/8579(headless 回测)，一行 JSON 往返
scripts/debug_cmd_server.gd（游戏内，autoload，仅 debug 构建）   ← 执行层
```

## 游戏内命令面（debug_cmd_server.gd）

**感知**（AI 读世界的三个口）：
- `state` — 结构化全量快照：`fsm_state`/`mic_open`（InteractionFsm 权威交互态，判「现在能不能说/动」
  的唯一依据，别猜零散标志位）、`player_pos/tile`、`npcs` 明细（名字+tile）、`wallet`/`bag_items`/
  `active_task`、`phone_open/phone_app`、`placing` 明细、`play_blocked/stage_active/refine/remix`、
  造物引导态（`in_creation`+`creation_options`）、起名/引路/复用/招呼、vc 各态。
- `ui` — 可点/可读元素枚举：可见 BaseButton（button）、gui_input 有连接或脚本重写 `_gui_input`
  的自绘点击区（tap_area）、`texts:true` 时附带 Label（text）。每项带屏幕矩形与 **viewport 标记**：
  `root` 可盲坐标 tap，SubViewport 名（手机屏）坐标不通、必须语义点击。menu/onboarding 靠它免费覆盖。
- `screencap wire:true` — 截图降采样 JPEG base64 **走 TCP 回包**（真机 `user://` adb 拉不出来，
  这是唯一取图路）；缺省仍落盘兼容旧用法。

**动作**：
- 真输入事件：`tap`；跨帧手势 `drag/swipe/long_press/pinch`——发起即回按下，逐帧插值
  ScreenDrag，到时抬起**才回包**；在飞期间不取新命令行（一问一答顺序语义）。事件出口
  `event_sink` 可注入：headless 单测换收集器确定性断言序列，真机走 `Input.parse_input_event`。
- 语义动作（盲坐标不可靠时的正路，`talk_fairy` 先例）：`click_ui`（path/text 找控件；Button 直发
  pressed、根视口点击区真 tap 矩形中心、SubViewport 点击区喂本地 `_gui_input`）、`phone`
  （open/close/app，走 world.harness_phone → `_open_phone/_open_app` 真路径）、
  既有 `pick/pickup/teleport/scene/accept/replay/retry`。
- 语音：既有 `inject`（换 ScriptedAsr）+ `say`（排文本+合成 PCM 走真 VAD，门禁是被测对象不绕过）。

## 驱动 SDK（test/e2e/harness.py）

全 op 封装 + 三件加固：手势读超时按手势时长放宽；`wait_state/wait_banner_stable` 轮询容忍单次
瞬断（换场景黑幕期对端可能不应答——此前每个脚本自己包 try 的教训收进 SDK）；`start_trace(dir)`
每条命令+应答落 `trace.jsonl`（截图 b64 只记长度）+ 截图落同目录，供回放审计与 QA 报告。
`observe()` = state + ui + 截图三合一（截图 best-effort：headless 无 viewport 纹理属预期）。

## AI 决策层

- **game-pilot skill**（`.claude/skills/game-pilot/SKILL.md`）：Claude 会话即 agent。每步一条
  `pilot_cli.py` Bash 命令（observe/动作/等待谓词），skill 固化循环纪律（动作后核状态落地、
  能语义不盲点、说话看门禁、进世界判据 ws+npc≥8）与标准配方（进世界/对话/造物多轮/起名/手机）。

## 验收实录（2026-07-15，桌面 headless 实例 × PROD）

- 全自动整链：语义点击进世界 → talk_fairy → say 造物意图 → 两轮引导点卡（给谁做/什么颜色）
  → 造物落背包 → 起名「冲天号」→ 确认模式 accept 收尾，全程零人手。
- QA 巡检 2 分钟：49 步（对话/手机三 app/手势/传送/切场景），异常 0，轨迹 128 行。

## 已知边界

- 截图需带窗实例（headless 无 viewport 纹理）；真机截图走 wire 回包已通线（tap 先例背书投递）。
- 桌面无端侧 ASR 时 `vc_ready` 只在 `inject` 后为真：`wait-world --no-vc` + inject 回包 ready 等效。
- worktree 跑桌面实例需软链 `addons/maliang_asr_native/bin`（gitignored 产物，主 checkout 有）。
- 8577 常被 adb/iproxy 占走：桌面 8578、headless 回测 8579（`MALIANG_HARNESS_PORT`）。
- release 构建整条链一行不跑（`OS.is_debug_build()` 双门禁），绝不流到孩子手里。
