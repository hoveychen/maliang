# edge-tts 客户端首选 TTS 设计

## 目标

TTS 合成从服务端（MiniMax/Kokoro）迁到**客户端直连微软 edge-tts 云端接口**（平板 → wss://speech.platform.bing.com），服务端默认退化为纯文本输入输出；仅当客户端到微软的链路不通时，才降级回服务端合成。

动机（2026-07-09 实测数据）：
- 本机完整合成链路 10/10 成功，首包中位 212ms，整句（6.5s 音频）中位 300ms 出完，RTF≈0.05；
- 免费；音色 zh-CN-Xiaoyi/Yunxia 卡通系适合儿童场景；
- 省掉服务端 TTS 算力与 MiniMax 费用，同时砍掉服务端→客户端的音频流量（PCM16 base64 是大头）。

风险（接受并设计兜底）：非官方接口，Sec-MS-GEC 校验历史上多次导致社区库失效——所以**服务端 TTS 全链保留**为降级路径，坏了自动回退，不影响可用性。

## 现状（改动前）

四个出声面 + 一个离线面：

| 出声面 | 服务端路径 | 客户端播放 |
|---|---|---|
| 对话回复/招呼/onboarding | `respondToTranscript`/`voice_greeting` → 流式 TTS：`character_response`(ttsStreaming+ttsMime) + `tts_chunk`(PCM16 base64) + `tts_end` | `_start_tts_stream` AudioStreamGenerator 边收边播 |
| 造角色引导 | `creation_prompt` 整段合成存 asset，payload 带 `ttsAsset` | `_play_tts(asset)` HTTP 拉整段 |
| 得奖表扬 | `praise_tts` 整段合成，payload 只有 `ttsAsset`（无文本） | `_on_praise_tts` |
| 仙子预制台词 | 构建期生成 `assets/voice/fairy/lines.json`+音频，运行期零网络 | `fairy_voice.gd` 本地播放 |

麦克风 gating / 音量 ducking 都挂在 `_tts_player.playing` 上。

## 协议改动（向后兼容）

**能力协商**：客户端 WS 连接 URL 带 `?clientTts=1`。服务端在 upgrade 时读取，存到连接会话。老客户端不带 → 行为完全不变。

**clientTts=1 时服务端行为**：
- 对话/招呼/onboarding：跳过 TTS 合成，`character_response` 直接发（`ttsStreaming` 缺省/false、`ttsAsset` 空），**新增 `voiceId` 字段**（客户端映射音色用）。
- `creation_prompt`：跳过合成，`ttsAsset` 留空（payload 已有问题文本与选项 label）；补 `voiceId`（仙子）。
- 表扬：`praise_tts` 跳过合成，**新增 `text` + `voiceId` 字段**（原 payload 只有音频没文本）。
- **新增 `tts_request` 消息**（客户端→服务端）：`{type:"tts_request", text, voiceId}` → 服务端走现有流式 TTS 通道回 `character_response`(仅 ttsStreaming/ttsMime，无文本重复)/`tts_chunk`/`tts_end`。这是客户端 edge 合成失败时的逐句降级口。

仙子预制台词不动：离线保底，必须零网络。

## 客户端 edge_tts.gd（协议移植，来源 edge-tts 7.x Python 源码）

- **连接**：`wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&ConnectionId=<uuid无横线>&Sec-MS-GEC=<token>&Sec-MS-GEC-Version=1-143.0.3650.75`
  - 握手头（Godot `WebSocketPeer.handshake_headers`）：Edge UA、`Origin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold`、`Pragma/Cache-Control: no-cache`、`Cookie: muid=<随机hex32大写>;`
- **Sec-MS-GEC**：`SHA256( str(round_down_5min(unixtime+11644473600) * 1e7) + TrustedClientToken )` 大写 hex。`HashingContext` 实现。
- **时钟纠偏**：平板时钟不准是常态。探活 HTTP（voices/list）响应的 `Date` 头 → 计算 skew 存下，token 生成带上。探活与纠偏合一。
- **发**：两个文本帧——`speech.config`（outputFormat=`audio-24khz-48kbitrate-mono-mp3`）、SSML（`<speak><voice name><prosody>` 包 XML 转义文本）。
- **收**：二进制帧 = 前 2 字节大端 header 长度 + 头块 + mp3 数据（`Path:audio`）；文本帧 `Path:turn.end` 结束。
- **播放**：攒整段 mp3 → `AudioStreamMP3` → 复用 `_tts_player`（gating/ducking 免改）。整句 300ms 内出完，不做 mp3 分块流播（复杂度不值）。

## 音色映射（客户端表）

| 现 voiceId（MiniMax/Kokoro） | edge 音色 |
|---|---|
| 仙子（fairy.voiceId） | zh-CN-XiaoyiNeural（活泼女声，老板试听样本之一） |
| 男性向角色 | zh-CN-YunxiaNeural（小孩音）/ zh-CN-YunxiNeural |
| 女性向角色 | zh-CN-XiaoxiaoNeural / zh-CN-XiaoyiNeural |
| 未知 voiceId | 按 id 稳定哈希落到上述池 |

具体映射表在实现里维护，验收时老板可调。

## 降级状态机（客户端）

- `edge_ok` 会话级状态：启动探活（HTTP voices/list，同时取 Date 纠偏）→ 置位；失败带退避重探。
- 每句：`edge_ok` 且合成成功 → 本地播；合成失败（握手失败/超时 3s 无首包/中途断）→ 本句立即发 `tts_request` 走服务端，并将 `edge_ok=false` 进退避。
- 全程不阻塞：文本气泡/行为脚本照常先行（character_response 已先到）。

## 不变的东西

- ASR 仍是端侧讯飞 AAR + 服务端流式讯飞（与 TTS 无关）。
- 服务端 TTS 适配器（MiniMax/Kokoro/mock）全保留——降级路径 + 老客户端。
- 仙子预制台词 lines.json 机制不变；仅用 edge Xiaoyi **重生成一遍音频**使仙子全程音色统一（P4）。
- TTS 资产存储：clientTts 会话不再落 TTS asset（历史回放少了音频，接受）。
