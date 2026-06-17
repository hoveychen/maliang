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
