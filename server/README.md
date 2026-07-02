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

环境变量：

- `VOICE_PROVIDER` — `auto`（默认：有本地模型用 local → 有讯飞 key 用 xfyun → mock）/ `local` / `xfyun` / `mock`。讯飞回切：`VOICE_PROVIDER=xfyun`。
- `VOICE_MODELS_DIR` — 模型目录，默认 `models`（相对 server 运行目录）。
- `VOICE_TTS_VOICE` — 默认音色（Kokoro 音色名如 `zf_001`/`zm_009`，或 sid 数字）。角色 voiceId 也可直接填这些值按角色定音色。

冒烟/延迟实测：`node tools/voice_smoke.mjs`（合成样音存 `/tmp/maliang_tts_smoke.wav`）。
