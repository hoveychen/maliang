# maliang 后端 —— Node 原生 TS 执行（类型剥离），无需编译。
# muvee 构建上下文 = 仓库根；本 Dockerfile 路径 server/Dockerfile。
# Node 26：node:sqlite（持久化 P1）在 22.5 起为实验特性、早期需 --experimental-sqlite，
# 26 起稳定内置、无需标志（本地 dev 即 26.4）；CMD 用裸 `node` 不带标志，故基线锁 26。
# sherpa-onnx-node 为 N-API 预编译（ABI 跨 major 稳定），已实测在 26 加载正常。

# ── 阶段一：构建 /debug 管理台（React+Vite）。产物纯静态，运行时不需要 admin 依赖树 ──
FROM node:26-slim AS admin-build
RUN npm install -g corepack@latest && corepack enable
WORKDIR /admin
COPY server/admin/package.json server/admin/pnpm-lock.yaml server/admin/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY server/admin/ ./
RUN pnpm build

# ── 阶段二：运行时 ──
FROM node:26-slim

WORKDIR /app
# curl/bzip2/ca-certificates：容器启动时拉取本地语音模型（fetch-voice-models.sh）
# ffmpeg：idle 动画 mp4 抽帧成 sprite-sheet 图集（sprite_sheet.ts）
# webp：图集 PNG→WebP 编码（cwebp，体积 ~1/6.6，带 alpha）
RUN apt-get update && apt-get install -y --no-install-recommends curl bzip2 ca-certificates ffmpeg webp \
  && rm -rf /var/lib/apt/lists/*
# node:26-slim 起不再内置 corepack（Node 25+ 已从发行版剥离），需显式装一次再启用。
RUN npm install -g corepack@latest && corepack enable

# 先装依赖（利用缓存）。运行时只需 prod 依赖（fastify/pngjs/jpeg-js/sherpa-onnx-node）；
# typescript/@types 仅类型检查用，运行时 node 原生剥离类型，不需要。
COPY server/package.json server/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod

COPY server/ ./
# 管理台构建产物（server.ts 检测到 admin/dist 即在 /debug 托管 SPA）
COPY --from=admin-build /admin/dist ./admin/dist

# muvee：HTTP 必须在 8080；持久化只有 /workspace 存活 →
# 数据目录与语音模型（~1GB，启动时拉一次后复用）都指向 /workspace
ENV PORT=8080
ENV MALIANG_DATA_DIR=/workspace/data
ENV VOICE_MODELS_DIR=/workspace/models
# 构建时注入 git commit sha（GHA 传 --build-arg），/health 回显部署版本，便于验证 auto-deploy
ARG GIT_SHA=dev
ENV GIT_SHA=$GIT_SHA
EXPOSE 8080

# 模型缺失时先拉取（幂等，秒级跳过），再起服务
CMD ["sh", "-c", "./scripts/fetch-voice-models.sh \"$VOICE_MODELS_DIR\" && exec node src/index.ts"]
