# M2 语音闭环 — 设计与计划

> ⚙️ **已过时（历史规划快照，保留作演进记录）**：本文档写于选型讯飞时期。讯飞 ASR/TTS **已全部退役**，
> 当前架构：ASR 走 `local`（sherpa-onnx Zipformer，服务端 + Android/macOS 端侧化）、TTS 走 MiniMax
> （失败回落本地 Kokoro）、客户端优先 edge-tts 直连。讲飞相关的适配器与 secret 已删除/解绑。
> 现行设计见 [`macos-asr-feasibility.md`](macos-asr-feasibility.md)。下文的讲飞细节仅供历史参考。

> 目标：让小朋友能**对着角色说话**，角色用语音+动作回应。把交互模式从"点击"升级到"语音"。
> 前置：M0 渲染 ✅、M1 后端骨架 ✅、真实造角色闭环 ✅。

## 1. 端到端流程

```
点角色 → 进入交互模式（相机聚焦）
  → 点「聆听」(角色头顶耳朵图标) → 客户端录音
  → 点「发送」 → 上传音频(WS) → 思考中气泡
  → 后端：讯飞 ASR(音频→中文文字)
        → LLM 意图路由(闲聊 / 预设能力指令)
            · 闲聊 → 带个性+memory 生成回应 → 文字审核 → 讯飞 TTS → character_response
            · 指令 → 解析为 behavior_script(move_to/deliver_message/create_character) → 下发
  → 客户端：播放 TTS 音频 + 执行行为脚本 + 图标化情绪气泡
  → 后端：更新该角色 memory / chat_history（持久化）
```

设计要点：
- **tap-to-listen，不是 push-to-talk**（点一下开始听、说完点发送），避免按住挡住角色（Boss 决策）。
- ASR 转写交给 LLM 抽意图，对幼儿乱七八糟的转写**容错最高**（Boss 决策）。
- 全程**图标化**，不出现需要阅读的文字；提示靠语音播报。

## 2. 协议扩展（WS）

- `C→S` `voice_input` `{ world_id, character_id, audio: <base64/二进制>, format }`
- `S→C` `asr_partial?` `{ request_id, text }`（可选，MVP 可不做流式）
- `S→C` `character_response` `{ character_id, transcript, reply_text, tts_url, behavior_script?, emotion_icon }`
- 复用现有 `gen_progress` 给造角色指令（小神仙）。

## 3. 第三方：讯飞 iFlytek

- **ASR**：讯飞语音听写（中文，含儿童声学模型）。WebSocket 流式 API，HMAC-SHA256 鉴权（app_id / api_key / api_secret）。
- **TTS**：讯飞在线语音合成，多音色（给不同角色不同 voice_id）。
- 音频格式：讯飞要 16kHz / 16bit / 单声道 PCM 或 wav；客户端 `AudioStreamMicrophone` 采集后重采样上送。
- **意图路由 LLM 复用 OpenRouter（Kimi k2.6）**，不另接。

## 4. 适配器契约扩展

在 `ServiceAdapters` 增加（沿用工厂 real/mock 模式）：
- `ASRAdapter { transcribe(audio: ImageBlob-like bytes, format): Promise<string> }`
- `TTSAdapter { synthesize(text: string, voiceId: string): Promise<{bytes,mime}> }`
- mock：ASR 回固定文字、TTS 回静音占位，保证无 key 也能跑闭环 + 测试。

## 5. 意图路由

LLM 输入：转写文字 + 角色能力清单 + 角色个性。输出 JSON：
```jsonc
{ "kind": "chat" | "command",
  "reply_text": "闲聊时的中文回应（带个性）",
  "behavior_script": { "commands": [...], "loop": false },  // command 时
  "emotion": "happy|think|wave|..." }
```
- `command` 的目标（去哪/给谁带话/造什么）要能从转写解析出目标 tile 或 character_id；解析不出时降级为 chat 追问。
- 闲聊回应过**文字审核**再 TTS。

## 6. 客户端（Godot）

- `AudioStreamMicrophone` 录音；Android `RECORD_AUDIO` 权限 + 首启监护人同意（合规）。
- 交互模式 UI 完整化：聆听按钮(耳朵)、发送按钮、思考中气泡、播放 TTS、情绪图标气泡。
- 移植 worldlet `BehaviorExecutor`（GDScript）：执行 `move_to`/`deliver_message`，移动走 `WorldGrid.wrap_pos`。
- 录音原始音频**不持久化**（合规）。

## 7. P-task 拆解

- **P1** 讯飞 ASR 适配器（音频→中文）+ secrets 接入 + mock
- **P2** 讯飞 TTS 适配器（文字→音频，多音色）+ mock
- **P3** 意图路由（LLM：闲聊/指令→behavior_script）+ 单测
- **P4** `voice_input` WS 编排（ASR→意图→审核→TTS→character_response）+ memory/chat_history 更新 + e2e mock 测试
- **P5** 客户端录音 + 交互模式 UI 完整化（聆听/发送/思考中/播放/情绪气泡）+ RECORD_AUDIO 权限
- **P6** 客户端 `BehaviorExecutor` 移植（move_to/deliver_message）+ 端到端真机/桌面验证

**验收：** 桌面跑通「点角色→说一句（或注入音频）→角色语音回应/执行去某地」；mock 适配器下 `pnpm test` 全绿；真实讯飞下出真实中文语音。

## 8. 执行前的前置依赖（阻塞）

- **讯飞密钥**：需要 Boss 提供 `app_id` / `api_key` / `api_secret`（进 `.env`/muvee secrets，不入仓）。无密钥可先用 mock 把闭环+客户端 UI 全部搭通，密钥到位再接真实（同 M1 real-adapters 套路）。

## 9. 未决问题

- 讯飞 ASR 用一次性整段（tap-to-send，简单）还是流式（边说边出字）——MVP 倾向整段。
- 客户端音频重采样到 16k 的实现（Godot 侧）。
- `deliver_message`/`move_to` 的目标如何从口语解析为世界坐标/角色（需要把世界里现有角色清单喂给意图 LLM）。
