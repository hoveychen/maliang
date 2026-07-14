# 端侧语音 e2e 注入 harness（debug-gated）

> 状态：设计草案。目标：在**真机**上自动驱动语音交互流程（起名/对话/复用），做可重跑的端到端回归——真渲染、真后端、真 TTS，只把**声学前端**（麦→VAD→真 ASR）换成可编排的注入。

## 1. 要解决的问题

这是个**语音优先**的沙盒游戏：起名、跟村民对话、造物意图全靠「孩子说话 → 端侧 ASR → 文本」。所以：

- **headless 回测**已用 `vc._asr = FakeAsr` + 合成 PCM（`_feed`）确定性地覆盖了语音**逻辑**（VoiceCapture/VAD/confirm_mode）——但那跑在 editor headless，不是真机、没有真渲染/真后端。
- **真机**上语音流程**无法用 adb 驱动**：adb `input` 只有 touch/key/text，**没有注入麦克风音频的命令**；且 Godot 导出是单块 GL Surface，没有 Android View 层级/无障碍树，`uiautomator` 点不到元素。
- 于是真机回归只能人肉：每次改动都要人对着平板说话验一遍，慢且不可重跑。

**病灶**：真机上「代码逻辑对不对」和「手感顺不顺」被迫混在一次人工验里。手感是主观的、只能人验；但**逻辑**本可以自动化——缺的只是一条「替代真人说话」的注入通道。

## 2. 核心机制

注入分**两层**（缺一不可，见 §3.1）——照搬 headless 那套，搬到真机：

1. **`ScriptedAsr`**：GDScript 对象，鸭子类型对齐 `MaliangAsr` 单例（`isReady()`/`startSession()`/`stopSession()`/`feedPcm()` + `final_result`/`asr_ready` 信号）。不识别音频，`stopSession()` 时吐出预排的下一句文本。
2. **脚本麦驱动 VAD**：没有真麦音频，VAD 不会断句。注入一段合成 PCM（响一段→静音）喂 `_vc._feed()`，触发 `utterance_begin`→`utterance_commit`，与 `ScriptedAsr` 的文本对上。

**控制通道 = debug-gated 本地 TCP 命令口**（老板拍板走 B）：debug 构建开一个 localhost `TCPServer`，`adb forward tcp:PORT tcp:PORT` 后，测试客户端发 JSON 命令逐句驱动。仅 `OS.is_debug_build()` 开（同 `[vad]` logcat / `user://perf_sweep` 门控），release 一行不跑——绝不流到孩子手里。

### 命令集（JSON over TCP，一行一条）

| 命令 | 作用 |
|---|---|
| `{"op":"inject"}` | 运行时把端侧 ASR 换成 `ScriptedAsr`（真机注入入口，见 §3.4）；流程第一步 |
| `{"op":"say","text":"爬爬梯"}` | 排下一句 ASR 文本 + 喂合成 PCM 驱动 VAD 断句（=真人说一句） |
| `{"op":"tap","x":..,"y":..}` | 盲坐标触屏（进背包/点按钮这类纯触屏） |
| `{"op":"state"}` | 回一份状态快照（`_naming_item`/`selected`/banner 文本/bag 大小/vc 各态）供断言 |
| `{"op":"screencap"}` | 触发一帧截图落盘（`user://harness_cap.png`，`run-as` 取回人工/像素比对） |
| `{"op":"accept"/"replay"/"retry"}` | 确认模式三键（说完先回放、采纳/重听/重说） |

## 3. 关键设计问题

### 3.1 为什么必须注两层，不能只注 ASR

天真做法：只把转写直接灌进 `_on_capture_local_final(text)`。→ 跳过了 VAD 断句、confirm_mode 回放确认、`_voice_should_capture` 门禁——而这些恰恰是最容易出 bug 的地方（自听套娃、闭麦时序、确认条）。只注 ASR 测不到它们。

解法：注**脚本麦 + ScriptedAsr**，让 utterance 走完整条真实链路（`_feed`→VAD→session→`final_result`→confirm）。`say` 命令 = 喂 PCM + 排文本，一条命令复现「真人说一句」的全过程。

### 3.4 真机注入不推标志文件——改由 TCP `inject` handshake

P1 的注入开关靠 `user://asr_harness` 文件标志，headless 里好用（测试自己写）。但**真机上行不通**：Android 的 `user://` 是 app 私有目录，`adb push` 推不进（非 root）。所以真机注入改由控制通道自己触发：debug 构建**常开** TCP 命令口，测试客户端连上后先发 `{"op":"inject"}`，服务端调 `VoiceCapture.use_scripted_asr()` 在运行时把 `_asr`（真单例/null）换成 `ScriptedAsr`。仍 `OS.is_debug_build()` 门控，release 一行不跑。文件标志保留给 headless 便利，两条路并存、互不影响。

### 3.2 门禁怎么办——harness 不绕过 `_voice_should_capture`

`say` 只是把 PCM 喂进 `_vc`；到底录不录，仍由真实的 `_voice_should_capture`（对话态/`_naming_item`/端侧就绪）决定。这是**特性不是缺陷**：门禁本身就是被测对象。所以 e2e 脚本得先把宿主驱到「该开麦」的状态（如先造物→等 `item_created`→`_naming_item` 置位），再 `say`。

### 3.3 边界（诚实划界）

- ✅ 真机真渲染真后端真 TTS 地自动回归**下游逻辑**：起名落库/确认模式/复用提示/对话往返。
- ❌ **声学前端**（真麦拾音、VAD 阈值在真实噪声下、真 ASR 识别准确率）——注入绕过了它，测不了；这部分只能人肉 + headless 的合成 PCM 近似。
- ❌ **替代不了人验手感**（起名仪式对 3 岁顺不顺、复用提示密度烦不烦）——主观，本 harness 不碰。

## 4. 实现

### 4.1 ScriptedAsr（`scripts/scripted_asr.gd`，或 test/ 下）
鸭子类型对齐 `MaliangAsr`：`isReady()`→true、`startSession()`、`stopSession()`（吐队首文本走 `final_result`）、`feedPcm()`（no-op）、`asr_ready` 开机即发。VoiceCapture 已支持预置 `_asr` 跳过单例（`if _asr == null`）——注入点现成。

### 4.2 注入开关（`scripts/voice_capture.gd` / `world.gd`）
debug 构建 + 文件/env 标志（如 `user://asr_harness` 或 `MALIANG_ASR_HARNESS`）时，`_setup_local_asr` 改注 `ScriptedAsr`。默认（无标志）行为一字不变——回归护栏。

### 4.3 TCP 命令服务器（`scripts/debug_cmd_server.gd`，仅 debug）
`world._ready` 里 `OS.is_debug_build()` 才 `add_child`。`TCPServer.listen(8577, "127.0.0.1")`，每帧 `poll`，收 JSON 行 → 路由（见 §2.1）。命令解析拆成**纯函数** `parse_command(line)`（与 IO 分离），headless 单测覆盖合法/非法全路径。`say` 只把 PCM 喂进 `_vc`，到底录不录仍由真实 `should_capture` 门禁决定（§3.2，门禁本身是被测对象）。

### 4.4 e2e 脚本（`test/e2e/naming_e2e.py`）
`adb forward tcp:8577` →（可选 `--launch` 起 App）→ 连命令口 → `inject` 换 ScriptedAsr → 发命令序列（`say` 造物意图 → 轮询 `state` 等 `_naming_item` 置位 → `say` 名字 →（确认模式）`accept` → 轮询 `state` 等 `_naming_item` 回空）→ 各步 `screencap`。服务端 `nameVoiceAsset` 落库另核（debug 物品页 / muveectl curl）。桌面 debug 可 `--host 127.0.0.1` 直连不走 adb。

TCP 线路本身（socket 收发 + inject handshake + state 往返 + 坏输入回错误）由 `test/test_harness_wire.gd` 在本机 headless 用真 `StreamPeerTCP` 客户端跑通——真机联调前先 de-risk 管线。

## 5. 验收

- **headless 单测**：ScriptedAsr 注入后走真实 `_on_local_final` 链路出脚本文本；命令解析（say/tap/state）纯函数可测；注入开关默认关时行为不变（回归护栏）。
- **真机 e2e**（老板域可选跑）：`adb forward` + naming 脚本 → 起名落库 `item_updated` 带 `nameVoiceAsset` 回来；`state` 快照可断言。
- **安全**：release 构建里 TCP server / ScriptedAsr 注入一行都不跑（`OS.is_debug_build()` 门控 + AsrGuard 不受影响）。
