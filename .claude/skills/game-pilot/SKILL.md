---
name: game-pilot
description: 用 AI 当玩家驱动马良小世界——替代真人完成点击/说话/拖动/手机操作,感知游戏状态并闭环执行任务。Use when 老板要求"替我玩一遍/跑一遍造物(起名/对话/引路/背包/贴纸)流程"、"驱动游戏到X状态"、"游戏里帮我看看/截个图"、"自动化验收某条游戏链路",或任何需要程序化操控 maliang 客户端(桌面或真机)的任务。
---

# game-pilot：AI 驱动马良小世界

控制通道 = 游戏内 debug TCP 命令口（`scripts/debug_cmd_server.gd`，仅 debug 构建）。
每步一条 Bash 命令：`python3 test/e2e/pilot_cli.py [--port P] [--trace DIR] <子命令>`，回 JSON。

## 0. 接入（先起实例，再连口）

| 目标 | 做法 | 端口 |
|---|---|---|
| 桌面带窗（能截图，演示/目视首选） | `MALIANG_HARNESS_PORT=8578 /Applications/Godot.app/Contents/MacOS/Godot --path <repo> &`（Bash run_in_background） | 8578 |
| 桌面 headless（只驱逻辑，截图会报 no viewport image） | 同上加 `--headless` | 8578 |
| Android 真机 | 主 checkout 导 debug APK 装机（scripts/export-apk.sh），`adb forward tcp:8577 tcp:8577` | 8577 |
| 离线模式（不打生产） | 起实例时加 `MALIANG_API_BASE=http://127.0.0.1:1`——但**离线进不了在线世界**：只有 4 个本地种子村民、ws 不通、造物/对话发不出去。要完整玩法必须在线（默认连 PROD） | — |

⚠️ 8577 常被 adb/iproxy 转发占走，桌面实例一律 8578；8579 是 headless 回测专用，别占。

## 1. 循环纪律（感知→决策→动作→核对）

1. **每步动作后都要核对落地**：读 `state` 里对应字段（发了 `scene` 就等 `scene_id` 变、开了手机就看 `phone_open`），不要发完就当成功。
2. **能语义就不要盲坐标**：`click --text/--path`（按钮直发 pressed）、`talk-fairy`/`talk-npc`（进对话）、`phone open/app/close`、`pick <optionId>`（造物点卡）。盲 `tap` 打不中会被当点地面把玩家支使走。
3. **SubViewport（手机屏）内元素盲坐标永远到不了**：`ui` 回包里 `viewport != "root"` 的元素只能 `click --path` 或 `phone` 命令。
4. **说话有门禁**：`say` 回 `fed:false/gate_closed` = 对方在说话或没开麦。先 `wait-banner`（TTS 放完）再重说；反复 say 会堆积 ASR 队列。看 `state.fsm_state`/`mic_open` 判断当下能不能说。
5. **`say` 之前必须先 `inject`**（换 ScriptedAsr），且必须**进世界后**才 inject（menu/标题页会报 no active VoiceCapture）。onboarding 页也有 VC，可以 inject。
6. 连测被 45min 冷却门拦住 → `reset-budget`。
7. **等状态、别卡时长（action-based）**：动作触发的动画/异步用**状态谓词**等它落定，不要 `sleep <固定秒数>` 硬赌——`wait-world`/`wait-banner`/`wait --key <字段> --truthy|--falsy`（如 `--key phone_settling --falsy`、`--key transitioning --falsy`）、或本身就阻塞到落定的命令（`phone`）。卡 sleep 的脚本会在动画参数一改就整批 flake（血泪：`phone open`+`phone app` 背靠背瞬发把搬移动画掐断，手机停半路时左时右——根子就是没等落定）。

## 2. 感知

- `observe`：`state` + `ui --texts` + 截图三合一（headless 时截图字段是 shot_error，正常）。
- `state` 关键字段：`fsm_state`（EXPLORE/LISTENING/RECORDING/THINKING/SPEAKING/CREATION/COOLDOWN）、`mic_open`、`player_tile`、`npcs`（名字+tile）、`bag_items`、`wallet`、`active_task`、`in_creation`+`creation_options`、`naming_item`、`phone_open/phone_app`、`placing/place_legal`、`play_blocked`、`banner_text`（对方正在说的话）、`ws_open`。
- `ui --texts`：可点元素（kind=button/tap_area）+ 可读文本（kind=text），带屏幕矩形——点根视口元素可 tap 矩形中心，更稳是 `click --path`。
- `shot --out /tmp/x.jpg`：带窗实例直接回传 JPEG（真机也走 TCP 回传，不依赖 adb pull）。

## 3. 标准流程配方

**进世界（menu → world）**：`ui` 找 kind=button（menu 只有一个全屏进入钮）→ `click --path <其path>` → `wait-world`（ws_open+npc≥8+vc_ready，冷缓存最多 120s）。⚠️ 桌面实例通常没端侧 ASR，`vc_ready` 只在 `inject` 之后才真——桌面用 `wait-world --no-vc`，然后 `inject` 回包 `ready:true` 即等效。没有玩家档案时会先进 onboarding（`state.scene_id` 为空且 UI 是绘本页即是）。

**对话**：`talk-fairy`（或 `talk-npc`）→ 等对方招呼放完（`wait-banner`）→ `inject`（一次即可）→ `say "..."` 确认 `fed:true` → 轮询 `banner_text` 看回复。

**造物（guided-creation 多轮）**：对点点 `say "点点，帮我造一个火箭"` → `wait --key in_creation --truthy` → 循环：`state` 看 `creation_options` **有卡就 `pick <id>`**（category=recipient 时选 self），**无卡（开放问句）就 `say` 肯定应答**；`creation_question` ∈ {施法中…, 拼上啦…, 拼好啦！} 是过渡字幕不是新问句。直到 `bag_size` 增长或 `naming_item` 置位。
**起名**：`naming_item` 非空后 `say "<名字>"` → 进确认模式（`vc_confirming`）→ `accept`。

**手机**：`phone open` → `phone app items|stickers|flowers|settings` → 屏内元素用 `ui` 枚举（viewport=PhoneScreen）+ `click --path`；翻页用 `swipe`。收起 `phone close`。`phone` 命令是 **action-based** 的：发起后会**阻塞到手机开/关/翻页动画真正落定**（回包带 `settled:true`）才返回，所以 `phone app` 后**直接 `shot` 即可，不用 `sleep`**——命令没返回=动画还没停。别再 `phone open` 完立刻 `phone app`+`sleep` 硬等：那样只是碰运气，且早期版本会把搬移动画掐断导致手机停在半路（时左时右）。

**移动**：点地走路 `tap <地面坐标>`；按住跟随 `long-press --ms 1500`；跨场景 `scene forest` 后等 `transitioning=false`；找机位 `teleport --near` / `teleport 30 40`。

**整链回归（不要手搓重写）**：造物起名全流程 `naming_e2e.py`、语音三链 `voice_regression.py`、相册拍摄 `menu_photo_shoot.py`。

## 4. 轨迹与报告

长任务/巡检一律带 `--trace <dir>`：每条命令+应答追加 `trace.jsonl`、截图落同目录，事后可回放审计。QA 巡检（自主玩+异常报告）用 `python3 test/e2e/qa_patrol.py --minutes N`（见 P7）。

## 5. 已知坑

- 世界就绪判据是 **ws_open + npc_count≥8 + vc_ready** 三条齐：本地种子村民(4)立即出现但 ws 没连=离线，别被骗。
- 真机上真麦和合成 PCM 会打架，偶发「我没听清」→ 等 banner 稳再重说（`naming_e2e._say_until` 已封装）。
- headless 无 viewport 纹理：`shot` 报 no viewport image 属预期，要图就带窗跑。
- 跑完真机记得 `adb forward --remove tcp:8577`，占口会害 headless 回测 test_harness_wire 挂。
