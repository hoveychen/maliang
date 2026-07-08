# maliang 后端 —— Node 原生 TS 执行（类型剥离），无需编译。
# muvee 构建上下文 = 仓库根；本 Dockerfile 路径 server/Dockerfile。
FROM node:23-slim

WORKDIR /app
# curl/bzip2/ca-certificates：容器启动时拉取本地语音模型（fetch-voice-models.sh）
# ffmpeg：idle 动画 mp4 抽帧成 sprite-sheet 图集（sprite_sheet.ts）
# webp：图集 PNG→WebP 编码（cwebp，体积 ~1/6.6，带 alpha）
RUN apt-get update && apt-get install -y --no-install-recommends curl bzip2 ca-certificates ffmpeg webp \
  && rm -rf /var/lib/apt/lists/*
RUN corepack enable

# 先装依赖（利用缓存）。运行时只需 prod 依赖（fastify/pngjs/jpeg-js/sherpa-onnx-node）；
# typescript/@types 仅类型检查用，运行时 node 原生剥离类型，不需要。
COPY server/package.json server/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod

COPY server/ ./

# muvee：HTTP 必须在 8080；持久化只有 /workspace 存活 →
# 数据目录与语音模型（~1GB，启动时拉一次后复用）都指向 /workspace
ENV PORT=8080
ENV MALIANG_DATA_DIR=/workspace/data
ENV VOICE_MODELS_DIR=/workspace/models
EXPOSE 8080

# 模型缺失时先拉取（幂等，秒级跳过），再起服务
CMD ["sh", "-c", "./scripts/fetch-voice-models.sh \"$VOICE_MODELS_DIR\" && exec node src/index.ts"]
