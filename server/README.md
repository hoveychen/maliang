# maliang-server

maliang 后端代理（Node/TS + Fastify）。M1 骨架：造角色编排闭环以 **mock 适配器**跑通，真实第三方（Claude / OpenRouter / 讯飞 / 审核）通过实现 `ServiceAdapters` 契约接入，不改编排逻辑。

## 运行

```bash
pnpm install
pnpm start        # node 原生跑 TS（类型剥离），起 :8080
pnpm dev          # --watch
pnpm build        # tsc --noEmit 类型检查
pnpm test         # node --test，端到端验证造角色闭环
```

> 注意：用 Node 原生 TS 执行，源码只用「可剥离」语法——**不要用 enum / namespace / 构造函数参数属性 / 装饰器**（`tsc` 能过但 node 运行时会报 ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX）。import 一律带 `.ts` 扩展名。

## 结构

- `src/types.ts` — 角色/协议核心类型（WS/REST 字段以此为准）。
- `src/adapters/types.ts` — `ServiceAdapters` 契约（LLM/生图/抠图/审核）。
- `src/adapters/mock.ts` — mock 实现，不调外部服务。
- `src/orchestrator.ts` — 造角色管线：spec→moderate_text→image→cutout→moderate_image→persist。
- `src/persistence.ts` — 内存世界/资源存储（后续换 muvee dataset / DB）。
- `src/server.ts` — Fastify：`POST /worlds`、`GET /worlds/:id`、`GET /assets/:hash`、`GET /ws`。

## 接真实第三方（M1→真实 / M2）

实现 `ServiceAdapters` 各接口（如 `ClaudeLLMAdapter`、`OpenRouterImageAdapter`、`ChromaKeyCutoutAdapter`、`讯飞`），在 `buildServer({ adapters })` 注入即可。密钥走 `.env` / muvee secrets，**绝不提交进仓库**。

## 语音（ASR/TTS）

默认走**本地推理**（sherpa-onnx，进程内，无外部服务/密钥）：

- TTS：Kokoro v1.1-zh（103 个中文音色，24kHz，默认 `zf_001` 温暖女声）
- ASR：流式 Zipformer 中文（int8，真流式，`openStream` 边说边识别，finish 尾巴 ~10ms）

首次运行先拉模型（~1GB，gitignore 不入库）：

```bash
scripts/fetch-voice-models.sh          # 落到 server/models/
```

TTS 另可走 **MiniMax 云端**（`speech-2.6-turbo`，实测整句 1.0-1.9s、约 ¥0.013/条，音质高于本地 Kokoro）：设 `MINIMAX_API_KEY` 即自动启用（auto 路由优先 minimax），网络故障自动回落本地 Kokoro（若模型在场）。

环境变量：

- `VOICE_ASR_PROVIDER` / `VOICE_TTS_PROVIDER` — 分别路由（未设则用 `VOICE_PROVIDER`，再未设为 `auto`）。取值 `auto`/`local`/`xfyun`/`mock`，TTS 另有 `minimax`。auto 落点：ASR = local→xfyun→mock；TTS = minimax→local→xfyun→mock。
- `MINIMAX_API_KEY` / `MINIMAX_TTS_MODEL` — MiniMax 语音（默认 `speech-2.6-turbo`，音质冲高换 `speech-2.6-hd` 约 1.75 倍价）。
- `VOICE_MODELS_DIR` — 本地模型目录，默认 `models`（相对 server 运行目录）。
- `VOICE_TTS_VOICE` — 默认音色，按 provider 解释：Kokoro 音色名（`zf_001`/`zm_009`/sid 数字，未设默认 `zf_001`）或 MiniMax voice_id（`lovely_girl` 萌萌女童/`cute_boy`/`female-tianmei`，未设默认 `lovely_girl`）。角色 voiceId 命中这些值时按角色定音色。

冒烟/延迟实测：`node tools/voice_smoke.mjs`（合成样音存 `/tmp/maliang_tts_smoke.wav`）。
